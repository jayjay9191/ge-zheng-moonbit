///|
#derive(FromJson)
pub(all) struct Chip {
  scene : String
  date : String
  epsg : Int32
  x : Int32
  y : Int32
  width : Int32
  height : Int32
  cell : Int32
  red : Array[Int32]
  nir : Array[Int32]
  qa : Array[Int32]
  saturation : Array[Int32]
}

///|
pub extend Chip with @json.FromJson::{from_json}

///|
/// Decode one chip and reject ambiguous JSON objects with duplicate band keys.
pub fn parse_chip(raw : String) -> Chip raise {
  @json.from_json(@json.parse(raw, reject_duplicate_keys=true))
}

///|
#derive(ToJson)
pub(all) struct Quality {
  fill : Int32
  cloud : Int32
  shadow : Int32
  snow : Int32
  saturated : Int32
  unusable_signal : Int32
}

///|
#derive(ToJson)
pub(all) struct Audit {
  qa_screened : Bool
  first_scene : String
  second_scene : String
  first_date : String
  second_date : String
  epsg : Int32
  x : Int32
  y : Int32
  cell : Int32
  width : Int32
  height : Int32
  overlap : Int32
  valid : Int32
  excluded : Int32
  valid_fraction : Double
  threshold : Double
  gain : Int32
  loss : Int32
  stable : Int32
  both_nonwater_valid : Int32
  both_nonwater_gain : Int32
  both_nonwater_loss : Int32
  before_only_water : Int32
  after_only_water : Int32
  both_water : Int32
  gain_m2 : Int64
  loss_m2 : Int64
  mean_delta : Double
  max_abs_delta : Double
  first_qa : Quality
  second_qa : Quality
  before_reason : Array[Int32] // 0 valid; 1 fill; 2 cloud; 3 shadow; 4 snow; 5 saturation; 6 reflectance
  after_reason : Array[Int32]
  water_code : Array[Int32] // -1 excluded; bit 0 before, bit 1 after
  classes : Array[Int32] // -2 excluded, -1 loss, 0 stable, 1 gain
  delta : Array[Double?]
  ndvi_before : Array[Double?]
  ndvi_after : Array[Double?]
}

///|
pub extend Quality with @json.ToJson::{to_json}

///|
pub extend Audit with @json.ToJson::{to_json}

///|
#derive(Debug)
pub suberror AuditError {
  Invalid(String)
}

///|
fn validate(c : Chip) -> Unit raise AuditError {
  let zone = c.epsg % 100
  if (c.epsg / 100 != 326 && c.epsg / 100 != 327) ||
    zone < 1 ||
    zone > 60 ||
    c.cell != 30 ||
    c.x < 0 ||
    c.x > 1000000 ||
    c.y < 0 ||
    c.y > 10000000 ||
    c.width <= 0 ||
    c.height <= 0 ||
    c.width > 2048 ||
    c.height > 2048 {
    raise Invalid(
      "expected a north-up 30 m WGS84 UTM chip, at most 2048 by 2048",
    )
  }
  let size = c.width * c.height
  for band in [c.red, c.nir, c.qa, c.saturation] {
    if band.length() != size || band.iter().any(v => v < 0 || v > 65535) {
      raise Invalid(
        "bands must match grid dimensions and contain UInt16 values",
      )
    }
  }
}

///|
/// Landsat 8/9 Collection 2: QA_PIXEL bits 0–5, QA_RADSAT bits 3, 4, 11.
fn pixel(c : Chip, index : Int32, screen_qa : Bool) -> (Int32, Double) {
  let qa = if screen_qa { c.qa[index] } else { 0 }
  let red = c.red[index]
  let nir = c.nir[index]
  if (qa & 1) != 0 || red == 0 || nir == 0 {
    return (1, 0.0)
  }
  if (qa & 14) != 0 {
    return (2, 0.0)
  }
  if (qa & 16) != 0 {
    return (3, 0.0)
  }
  if (qa & 32) != 0 {
    return (4, 0.0)
  }
  if screen_qa && (c.saturation[index] & 2072) != 0 {
    return (5, 0.0)
  }
  let r = red.to_double() * 0.0000275 - 0.2
  let n = nir.to_double() * 0.0000275 - 0.2
  if red > 43636 || nir > 43636 || r < 0.0 || n < 0.0 || n + r <= 0.00000001 {
    return (6, 0.0)
  }
  (0, (n - r) / (n + r))
}

///|
fn quality(counts : Array[Int32]) -> Quality {
  {
    fill: counts[1],
    cloud: counts[2],
    shadow: counts[3],
    snow: counts[4],
    saturated: counts[5],
    unusable_signal: counts[6],
  }
}

///|
fn water_state(a : Chip, ia : Int32, b : Chip, ib : Int32) -> Int32 {
  ((a.qa[ia] & 128) >> 7) + ((b.qa[ib] & 128) >> 6)
}

///|
fn classify_change(delta : Double, threshold : Double) -> Int32 {
  if delta >= threshold {
    1
  } else if delta <= -threshold {
    -1
  } else {
    0
  }
}

///|
pub fn validate_threshold(threshold : Double) -> Unit raise AuditError {
  if !(threshold > 0.0 && threshold <= 2.0) {
    raise Invalid("NDVI threshold must be between 0 (exclusive) and 2")
  }
}

///|
priv struct CommonWindow {
  dx : Int32
  dy : Int32
  col0 : Int32
  row0 : Int32
  col1 : Int32
  row1 : Int32
}

///|
fn common_window(a : Chip, b : Chip) -> CommonWindow raise AuditError {
  validate(a)
  validate(b)
  if a.epsg != b.epsg {
    raise Invalid("CRS mismatch; refusing to compare")
  }
  let east = b.x - a.x
  let south = a.y - b.y
  if east % 30 != 0 || south % 30 != 0 {
    raise Invalid(
      "misaligned pixel grids: east \{east} m, south \{south} m; expected whole 30 m pixels",
    )
  }
  let dx = east / 30
  let dy = south / 30
  let col0 = if dx > 0 { dx } else { 0 }
  let row0 = if dy > 0 { dy } else { 0 }
  let col1 = if a.width < dx + b.width { a.width } else { dx + b.width }
  let row1 = if a.height < dy + b.height { a.height } else { dy + b.height }
  if col1 <= col0 || row1 <= row0 {
    raise Invalid("chips do not overlap")
  }
  { dx, dy, col0, row0, col1, row1, }
}

///|
fn validate_coverage(minimum : Double) -> Unit raise AuditError {
  if !(minimum >= 0.0 && minimum <= 1.0) {
    raise Invalid("minimum coverage must be in [0, 1]")
  }
}

///|
fn shared_coverage(
  valid : Int32,
  overlap : Int32,
  minimum : Double,
) -> Double raise AuditError {
  if valid == 0 {
    raise Invalid("no pixels are valid in both dates")
  }
  let coverage = valid.to_double() / overlap.to_double()
  if coverage < minimum {
    raise Invalid(
      "shared valid coverage \{valid}/\{overlap} is below minimum fraction \{minimum}",
    )
  }
  coverage
}

///|
pub fn compare(
  a : Chip,
  b : Chip,
  threshold : Double,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  pixel_grids~ : Bool = true,
) -> Audit raise AuditError {
  validate_threshold(threshold)
  validate_coverage(min_coverage)
  let { dx, dy, col0, row0, col1, row1, } = common_window(a, b)
  let qa_a = Array::make(7, 0)
  let qa_b = Array::make(7, 0)
  let water_counts = Array::make(4, 0)
  let water_code = []
  let before_reason = []
  let after_reason = []
  let mut both_nonwater_gain = 0
  let mut both_nonwater_loss = 0
  let mut gain = 0
  let mut loss = 0
  let mut stable = 0
  let mut sum = 0.0
  let mut max_abs_delta = 0.0
  let classes = []
  let delta = []
  let ndvi_before = []
  let ndvi_after = []
  for row in row0..<row1 {
    for col in col0..<col1 {
      let ia = row * a.width + col
      let ib = (row - dy) * b.width + col - dx
      let (reason_a, before) = pixel(a, ia, screen_qa)
      let (reason_b, after) = pixel(b, ib, screen_qa)
      if pixel_grids {
        ndvi_before.push(if reason_a == 0 { Some(before) } else { None })
        ndvi_after.push(if reason_b == 0 { Some(after) } else { None })
        before_reason.push(reason_a)
        after_reason.push(reason_b)
      }
      qa_a[reason_a] += 1
      qa_b[reason_b] += 1
      if reason_a != 0 || reason_b != 0 {
        if pixel_grids {
          water_code.push(-1)
        }
        if pixel_grids {
          classes.push(-2)
        }
        if pixel_grids {
          delta.push(None)
        }
      } else {
        let water = water_state(a, ia, b, ib)
        if pixel_grids {
          water_code.push(water)
        }
        water_counts[water] += 1
        let d = after - before
        if pixel_grids {
          delta.push(Some(d))
        }
        sum += d
        let magnitude = if d < 0.0 { -d } else { d }
        if magnitude > max_abs_delta {
          max_abs_delta = magnitude
        }
        let class = classify_change(d, threshold)
        if class == 1 {
          gain += 1
          if water == 0 {
            both_nonwater_gain += 1
          }
          if pixel_grids {
            classes.push(1)
          }
        } else if class == -1 {
          loss += 1
          if water == 0 {
            both_nonwater_loss += 1
          }
          if pixel_grids {
            classes.push(-1)
          }
        } else {
          stable += 1
          if pixel_grids {
            classes.push(0)
          }
        }
      }
    }
  }
  let width = col1 - col0
  let height = row1 - row0
  let overlap = width * height
  let valid = gain + loss + stable
  let coverage = shared_coverage(valid, overlap, min_coverage)
  {
    qa_screened: screen_qa,
    first_scene: a.scene,
    second_scene: b.scene,
    first_date: a.date,
    second_date: b.date,
    epsg: a.epsg,
    x: a.x + col0 * 30,
    y: a.y - row0 * 30,
    cell: 30,
    width,
    height,
    overlap,
    valid,
    excluded: overlap - valid,
    valid_fraction: coverage,
    threshold,
    gain,
    loss,
    stable,
    both_nonwater_valid: water_counts[0],
    both_nonwater_gain,
    both_nonwater_loss,
    before_only_water: water_counts[1],
    after_only_water: water_counts[2],
    both_water: water_counts[3],
    before_reason,
    after_reason,
    water_code,
    gain_m2: gain.to_int64() * 900L,
    loss_m2: loss.to_int64() * 900L,
    mean_delta: sum / valid.to_double(),
    max_abs_delta,
    first_qa: quality(qa_a),
    second_qa: quality(qa_b),
    classes,
    delta,
    ndvi_before,
    ndvi_after,
  }
}

///|
#derive(ToJson)
pub(all) struct PixelEvidence {
  x_center : Int32
  y_center : Int32
  red_before : Int32
  nir_before : Int32
  red_after : Int32
  nir_after : Int32
  qa_before : Int32
  qa_after : Int32
  saturation_before : Int32
  saturation_after : Int32
  reason_before : Int32
  reason_after : Int32
  class_code : Int32
  delta : Double?
}

///|
pub extend PixelEvidence with @json.ToJson::{to_json}

///|
/// row and column are one-based indexes within the common window.
pub fn inspect_pixel(
  a : Chip,
  b : Chip,
  result : Audit,
  row : Int32,
  column : Int32,
) -> PixelEvidence raise AuditError {
  let window = common_window(a, b)
  let { col0, row0, col1, row1, .. } = window
  validate_threshold(result.threshold)
  let width = col1 - col0
  let height = row1 - row0
  let size = width * height
  if result.first_scene != a.scene ||
    result.second_scene != b.scene ||
    result.first_date != a.date ||
    result.second_date != b.date ||
    result.epsg != a.epsg ||
    result.cell != 30 ||
    result.x != a.x + col0 * 30 ||
    result.y != a.y - row0 * 30 ||
    result.width != width ||
    result.height != height ||
    result.overlap != size {
    raise Invalid("pixel evidence sources or common window do not match")
  }
  if [
      result.before_reason.length(),
      result.after_reason.length(),
      result.delta.length(),
      result.classes.length(),
      result.ndvi_before.length(),
      result.ndvi_after.length(),
      result.water_code.length(),
    ].any(n => n != size) {
    raise Invalid("pixel evidence requires complete result grids")
  }
  let (evidence, before_ndvi, after_ndvi, water) = source_pixel(
    a,
    b,
    window,
    result.threshold,
    row,
    column,
    result.qa_screened,
  )
  let i = (row - 1) * width + column - 1
  if result.ndvi_before[i] != before_ndvi ||
    result.ndvi_after[i] != after_ndvi ||
    result.water_code[i] != water ||
    result.before_reason[i] != evidence.reason_before ||
    result.after_reason[i] != evidence.reason_after ||
    result.delta[i] != evidence.delta ||
    result.classes[i] != evidence.class_code {
    raise Invalid(
      "pixel evidence disagrees with source QA or NDVI classification",
    )
  }
  evidence
}

///|
/// Read one cell from the input rasters without allocating result grids.
pub fn inspect_sources(
  a : Chip,
  b : Chip,
  threshold : Double,
  row : Int32,
  column : Int32,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
) -> PixelEvidence raise AuditError {
  validate_threshold(threshold)
  validate_coverage(min_coverage)
  let window = common_window(a, b)
  let (evidence, _, _, _) = source_pixel(
    a, b, window, threshold, row, column, screen_qa,
  )
  if min_coverage > 0.0 || evidence.delta is None {
    let counts = count_thresholds(a, b, window, [threshold], screen_qa)[0].counts
    ignore(
      shared_coverage(
        counts.valid,
        counts.valid + counts.excluded,
        min_coverage,
      ),
    )
  }
  evidence
}

///|
fn source_pixel(
  a : Chip,
  b : Chip,
  window : CommonWindow,
  threshold : Double,
  row : Int32,
  column : Int32,
  screen_qa : Bool,
) -> (PixelEvidence, Double?, Double?, Int32) raise AuditError {
  let { dx, dy, col0, row0, col1, row1, } = window
  if row < 1 || row > row1 - row0 || column < 1 || column > col1 - col0 {
    raise Invalid("pixel is outside the common grid")
  }
  let grid_row = row0 + row - 1
  let grid_col = col0 + column - 1
  let ia = grid_row * a.width + grid_col
  let ib = (grid_row - dy) * b.width + grid_col - dx
  let (reason_a, before) = pixel(a, ia, screen_qa)
  let (reason_b, after) = pixel(b, ib, screen_qa)
  let expected_delta = if reason_a == 0 && reason_b == 0 {
    Some(after - before)
  } else {
    None
  }
  let expected_class = match expected_delta {
    Some(d) => classify_change(d, threshold)
    None => -2
  }
  let before_ndvi = if reason_a == 0 { Some(before) } else { None }
  let after_ndvi = if reason_b == 0 { Some(after) } else { None }
  let water = if expected_delta is Some(_) {
    water_state(a, ia, b, ib)
  } else {
    -1
  }

  let evidence = {
    x_center: a.x + grid_col * 30 + 15,
    y_center: a.y - grid_row * 30 - 15,
    red_before: a.red[ia],
    nir_before: a.nir[ia],
    red_after: b.red[ib],
    nir_after: b.nir[ib],
    qa_before: a.qa[ia],
    qa_after: b.qa[ib],
    saturation_before: a.saturation[ia],
    saturation_after: b.saturation[ib],
    reason_before: reason_a,
    reason_after: reason_b,
    class_code: expected_class,
    delta: expected_delta,
  }
  (evidence, before_ndvi, after_ndvi, water)
}

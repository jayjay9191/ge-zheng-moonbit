///|
#derive(ToJson)
pub(all) struct ShiftScenario {
  dc : Int32
  dr : Int32
  gain : Int32
  loss : Int32
  stable : Int32
  different_from_base : Int32
}

///|
#derive(ToJson)
pub(all) struct AlignmentStress {
  first_scene : String
  second_scene : String
  epsg : Int32
  x : Int32
  y : Int32
  width : Int32
  height : Int32
  cell : Int32
  threshold : Double
  qa_screened : Bool
  valid : Int32
  valid_fraction : Double
  unstable : Int32
  min_change_m2 : Int64
  max_change_m2 : Int64
  scenarios : Array[ShiftScenario]
  stability : Array[Int32]
}

///|
#derive(ToJson)
pub(all) struct AlignmentChangeBounds {
  certain_change_m2 : Int64
  possible_change_m2 : Int64
  opposite_direction : Int32
}

///|
/// Sample the second chip at the aligned location and its four immediate
/// neighbours. All scenarios share the same footprint and valid population.
/// The stability raster uses -2 for masked cells, -1/0/1 for unanimous
/// classifications and 2 for cells whose classification depends on the offset.
pub fn alignment_stress(
  before : Chip,
  after : Chip,
  threshold : Double,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
) -> AlignmentStress raise AuditError {
  let (stress, _) = alignment_stress_with_bounds(
    before,
    after,
    threshold,
    screen_qa~,
    min_coverage~,
  )
  stress
}

///|
/// Intersect and union the per-pixel change sets across the tested offsets.
/// Optionally include the four diagonal neighbours in the same valid footprint.
/// The lower and upper bounds allow each pixel to take a different offset.
/// Opposite-direction pixels meet both the gain and the loss criterion.
pub fn alignment_stress_with_bounds(
  before : Chip,
  after : Chip,
  threshold : Double,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  include_diagonals~ : Bool = false,
) -> (AlignmentStress, AlignmentChangeBounds) raise AuditError {
  validate_threshold(threshold)
  validate_coverage(min_coverage)
  let window = alignment_window(before, after)
  let { col0, row0, col1, row1, .. } = window
  let width = col1 - col0
  let height = row1 - row0
  let offsets = alignment_offsets(include_diagonals)
  let gain = Array::make(offsets.length(), 0)
  let loss = Array::make(offsets.length(), 0)
  let differences = Array::make(offsets.length(), 0)
  let classes = Array::make(offsets.length(), 0)
  let stability = Array::make(width * height, -2)
  let mut unstable = 0
  let mut certain = 0
  let mut possible = 0
  let mut opposite = 0
  let valid = scan_alignment(before, after, window, offsets, screen_qa, (
    index,
    deltas,
  ) => {
    for i in 0..<offsets.length() {
      classes[i] = classify_change(deltas[i], threshold)
    }
    let mut lowest = 1
    let mut highest = -1
    let mut any_stable = false
    let mut agrees = true
    for i in 0..<offsets.length() {
      lowest = lowest.min(classes[i])
      highest = highest.max(classes[i])
      any_stable = any_stable || classes[i] == 0
      if classes[i] == 1 {
        gain[i] += 1
      } else if classes[i] == -1 {
        loss[i] += 1
      }
      if classes[i] != classes[0] {
        differences[i] += 1
        agrees = false
      }
    }
    if !any_stable {
      certain += 1
    }
    if lowest < 0 || highest > 0 {
      possible += 1
    }
    if lowest < 0 && highest > 0 {
      opposite += 1
    }
    stability[index] = if agrees {
      classes[0]
    } else {
      unstable += 1
      2
    }
  })
  let valid_fraction = shared_coverage(valid, width * height, min_coverage)
  let mut min_change = valid
  let mut max_change = 0
  let scenarios : Array[ShiftScenario] = []
  for i in 0..<offsets.length() {
    let (dc, dr) = offsets[i]
    let changed = gain[i] + loss[i]
    min_change = min_change.min(changed)
    max_change = max_change.max(changed)
    scenarios.push({
      dc,
      dr,
      gain: gain[i],
      loss: loss[i],
      stable: valid - changed,
      different_from_base: differences[i],
    })
  }
  let stress = {
    first_scene: before.scene,
    second_scene: after.scene,
    epsg: before.epsg,
    x: before.x + col0 * before.cell,
    y: before.y - row0 * before.cell,
    width,
    height,
    cell: before.cell,
    threshold,
    qa_screened: screen_qa,
    valid,
    valid_fraction,
    unstable,
    min_change_m2: min_change.to_int64() * 900L,
    max_change_m2: max_change.to_int64() * 900L,
    scenarios,
    stability,
  }
  let bounds = {
    certain_change_m2: certain.to_int64() * 900L,
    possible_change_m2: possible.to_int64() * 900L,
    opposite_direction: opposite,
  }
  (stress, bounds)
}

///|
fn alignment_window(
  before : Chip,
  after : Chip,
) -> CommonWindow raise AuditError {
  let window = common_window(before, after)
  let col0 = window.col0.max(window.dx + 1)
  let row0 = window.row0.max(window.dy + 1)
  let col1 = window.col1.min(window.dx + after.width - 1)
  let row1 = window.row1.min(window.dy + after.height - 1)
  if col1 <= col0 || row1 <= row0 {
    raise Invalid("no common footprint for the one-pixel offsets")
  }
  { ..window, col0, row0, col1, row1, }
}

///|
fn alignment_offsets(include_diagonals : Bool) -> Array[(Int32, Int32)] {
  let offsets = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]
  if include_diagonals {
    offsets.push((1, 1))
    offsets.push((1, -1))
    offsets.push((-1, 1))
    offsets.push((-1, -1))
  }
  offsets
}

///|
// Reuse the temporary delta array between visits. A visit must consume it immediately.
fn scan_alignment(
  before : Chip,
  after : Chip,
  window : CommonWindow,
  offsets : Array[(Int32, Int32)],
  screen_qa : Bool,
  visit : (Int32, Array[Double]) -> Unit,
) -> Int32 {
  let { dx, dy, col0, row0, col1, row1, } = window
  let width = col1 - col0
  let deltas = Array::make(offsets.length(), 0.0)
  // Cache the second image's NDVI and QA for the three live scan rows.
  // The one-pixel halo is already proven to fit by alignment_window.
  let after_columns = width + 2
  let scan_start_col = col0 - dx - 1
  let after_rows = Array::makei(3, _ => Array::make(after_columns, (0, 0.0)))
  let load_after_row = (image_row, slot) => {
    let row_start = image_row * after.width + scan_start_col
    for col in 0..<after_columns {
      after_rows[slot][col] = pixel(after, row_start + col, screen_qa)
    }
  }
  load_after_row(row0 - dy - 1, 0)
  load_after_row(row0 - dy, 1)
  let mut valid = 0
  for row in row0..<row1 {
    let scan_row = row - row0
    load_after_row(row - dy + 1, (scan_row + 2) % 3)
    for col in col0..<col1 {
      let (reason, baseline) = pixel(
        before,
        row * before.width + col,
        screen_qa,
      )
      if reason != 0 {
        continue
      }
      let mut available = true
      for i in 0..<offsets.length() {
        let (dc, dr) = offsets[i]
        let (reason, observed) = after_rows[(scan_row + dr + 1) % 3][col -
          col0 +
          dc +
          1]
        if reason != 0 {
          available = false
          break
        }
        deltas[i] = observed - baseline
      }
      if available {
        valid += 1
        visit((row - row0) * width + col - col0, deltas)
      }
    }
  }
  valid
}

///|
#derive(ToJson)
pub(all) struct AlignmentThresholdRow {
  threshold : Double
  bounds : AlignmentChangeBounds
}

///|
#derive(ToJson)
pub(all) struct AlignmentThresholdSweep {
  first_scene : String
  second_scene : String
  epsg : Int32
  x : Int32
  y : Int32
  width : Int32
  height : Int32
  cell : Int32
  offsets : Int32
  qa_screened : Bool
  valid : Int32
  valid_fraction : Double
  rows : Array[AlignmentThresholdRow]
}

///|
/// In one footprint scan, compute the certain, possible and opposing changes
/// for all requested thresholds. The rows retain the caller's order and repeats.
pub fn alignment_threshold_sweep(
  before : Chip,
  after : Chip,
  thresholds : Array[Double],
  include_diagonals~ : Bool = false,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
) -> AlignmentThresholdSweep raise AuditError {
  let size = thresholds.length()
  if size == 0 {
    raise Invalid("alignment sweep requires at least one threshold")
  }
  for threshold in thresholds {
    validate_threshold(threshold)
  }
  validate_coverage(min_coverage)
  let window = alignment_window(before, after)
  let offsets = alignment_offsets(include_diagonals)
  let ordered = Array::makei(size, i => i)
  ordered.sort_by((a, b) => thresholds[a].compare(thresholds[b]))
  let certain = Array::make(size + 1, 0)
  let possible = Array::make(size + 1, 0)
  let opposite = Array::make(size + 1, 0)
  let valid = scan_alignment(before, after, window, offsets, screen_qa, (
    _,
    deltas,
  ) => {
    let mut minimum_magnitude = deltas[0].abs()
    let mut strongest_gain = 0.0
    let mut strongest_loss = 0.0
    for delta in deltas {
      minimum_magnitude = minimum_magnitude.min(delta.abs())
      strongest_gain = strongest_gain.max(delta)
      strongest_loss = strongest_loss.max(-delta)
    }
    certain[thresholds_met(thresholds, ordered, minimum_magnitude)] += 1
    possible[thresholds_met(
      thresholds,
      ordered,
      strongest_gain.max(strongest_loss),
    )] += 1
    opposite[thresholds_met(
      thresholds,
      ordered,
      strongest_gain.min(strongest_loss),
    )] += 1
  })
  let width = window.col1 - window.col0
  let height = window.row1 - window.row0
  let valid_fraction = shared_coverage(valid, width * height, min_coverage)
  let lower = accumulate_threshold_bins(ordered, certain)
  let upper = accumulate_threshold_bins(ordered, possible)
  let reversals = accumulate_threshold_bins(ordered, opposite)
  {
    first_scene: before.scene,
    second_scene: after.scene,
    epsg: before.epsg,
    x: before.x + window.col0 * before.cell,
    y: before.y - window.row0 * before.cell,
    width,
    height,
    cell: before.cell,
    offsets: offsets.length(),
    qa_screened: screen_qa,
    valid,
    valid_fraction,
    rows: Array::makei(size, i => {
      threshold: thresholds[i],
      bounds: {
        certain_change_m2: lower[i].to_int64() * 900L,
        possible_change_m2: upper[i].to_int64() * 900L,
        opposite_direction: reversals[i],
      },
    }),
  }
}

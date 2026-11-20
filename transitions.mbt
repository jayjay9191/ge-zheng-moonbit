///|
#derive(ToJson)
pub(all) struct NdviTransitions {
  cut_points : Array[Double]
  counts : Array[Array[Int32]]
  valid : Int32
  excluded : Int32
  water_excluded : Int32
}

///|
pub extend NdviTransitions with @json.ToJson::{to_json}

///|
fn ndvi_band(value : Double, cuts : Array[Double]) -> Int32 {
  let mut index = 0
  while index < cuts.length() && value >= cuts[index] {
    index += 1
  }
  index
}

///|
fn validate_ndvi_cut_points(
  cut_points : Array[Double],
) -> Unit raise AuditError {
  if cut_points.is_empty() || cut_points.length() > 16 {
    raise Invalid("NDVI transitions require 1 to 16 cut points")
  }
  let mut previous = -1.0
  for cut in cut_points {
    if !(cut > previous && cut < 1.0) {
      raise Invalid("NDVI cut points must strictly increase between -1 and 1")
    }
    previous = cut
  }
}

///|
/// Count before-band (row) to after-band (column) transitions on common valid pixels.
/// Cut points are strictly increasing in (-1, 1); equality enters the higher band.
pub fn ndvi_transitions(
  before : Chip,
  after : Chip,
  cut_points : Array[Double],
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviTransitions raise AuditError {
  validate_ndvi_cut_points(cut_points)
  validate_coverage(min_coverage)
  let { dx, dy, row0, row1, col0, col1, } = common_window(before, after)
  let bands = cut_points.length() + 1
  let counts = Array::makei(bands, _ => Array::make(bands, 0))
  let mut valid = 0
  let mut water_excluded = 0
  for row in row0..<row1 {
    for col in col0..<col1 {
      let ia = row * before.width + col
      let ib = (row - dy) * after.width + col - dx
      let (reason_a, a) = pixel(before, ia, screen_qa)
      let (reason_b, b) = pixel(after, ib, screen_qa)
      if reason_a != 0 || reason_b != 0 {
        continue
      }
      if land_only && water_state(before, ia, after, ib) != 0 {
        water_excluded += 1
        continue
      }
      counts[ndvi_band(a, cut_points)][ndvi_band(b, cut_points)] += 1
      valid += 1
    }
  }
  let overlap = (row1 - row0) * (col1 - col0)
  ignore(shared_coverage(valid, overlap, min_coverage))
  {
    cut_points: cut_points.copy(),
    counts,
    valid,
    excluded: overlap - valid,
    water_excluded,
  }
}

///|
#derive(ToJson)
pub(all) struct NdviTransitionSummary {
  before_counts : Array[Int32]
  after_counts : Array[Int32]
  lower : Int32
  same : Int32
  higher : Int32
}

///|
pub extend NdviTransitionSummary with @json.ToJson::{to_json}

///|
/// Count movements between NDVI bands, over the same common valid pixels.
pub fn summarize_ndvi_transitions(
  matrix : NdviTransitions,
) -> NdviTransitionSummary raise AuditError {
  validate_ndvi_cut_points(matrix.cut_points)
  let bands = matrix.cut_points.length() + 1
  if matrix.counts.length() != bands ||
    matrix.valid < 1 ||
    matrix.valid > 2048 * 2048 ||
    matrix.excluded < 0 ||
    matrix.excluded > 2048 * 2048 - matrix.valid ||
    matrix.water_excluded < 0 ||
    matrix.water_excluded > matrix.excluded {
    raise Invalid("NDVI transition dimensions or totals are invalid")
  }
  let before_counts = Array::make(bands, 0)
  let after_counts = Array::make(bands, 0)
  let mut total = 0
  let mut lower = 0
  let mut same = 0
  let mut higher = 0
  for row in 0..<bands {
    let cells = matrix.counts[row]
    if cells.length() != bands {
      raise Invalid("NDVI transition matrix must be square")
    }
    for column in 0..<bands {
      let count = cells[column]
      if count < 0 || count > matrix.valid - total {
        raise Invalid(
          "NDVI transition count disagrees with the valid pixel total",
        )
      }
      total += count
      before_counts[row] += count
      after_counts[column] += count
      if column < row {
        lower += count
      } else if column == row {
        same += count
      } else {
        higher += count
      }
    }
  }
  if total != matrix.valid {
    raise Invalid("NDVI transition count disagrees with the valid pixel total")
  }
  { before_counts, after_counts, lower, same, higher, }
}

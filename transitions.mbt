///|
#derive(ToJson)
pub(all) struct NdviTransitions {
  cut_points : Array[Double]
  counts : Array[Array[Int32]]
  valid : Int32
  excluded : Int32
  water_excluded : Int32
  qa_screened : Bool
  land_only : Bool
  valid_fraction : Double
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
  let valid_fraction = shared_coverage(valid, overlap, min_coverage)
  {
    cut_points: cut_points.copy(),
    counts,
    valid,
    excluded: overlap - valid,
    water_excluded,
    qa_screened: screen_qa,
    land_only,
    valid_fraction,
  }
}

///|
#derive(ToJson)
pub(all) struct NdviBandChange {
  retained : Int32
  gained : Int32
  lost : Int32
  net : Int32
  exchange : Int32
}

///|
pub extend NdviBandChange with @json.ToJson::{to_json}

///|
#derive(ToJson)
pub(all) struct NdviCutCrossing {
  threshold : Double
  up : Int32
  down : Int32
  net : Int32
}

///|
pub extend NdviCutCrossing with @json.ToJson::{to_json}

///|
#derive(ToJson)
pub(all) struct NdviTransitionSummary {
  before_counts : Array[Int32]
  after_counts : Array[Int32]
  lower : Int32
  same : Int32
  higher : Int32
  quantity_disagreement : Int32
  allocation_disagreement : Int32
  bands : Array[NdviBandChange]
  cut_crossings : Array[NdviCutCrossing]
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
  // Each off-diagonal cell contributes to the contiguous cuts between the bands.
  let up_delta = Array::make(bands, 0)
  let down_delta = Array::make(bands, 0)
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
        down_delta[column] += count
        down_delta[row] -= count
      } else if column == row {
        same += count
      } else {
        higher += count
        up_delta[row] += count
        up_delta[column] -= count
      }
    }
  }
  if total != matrix.valid {
    raise Invalid("NDVI transition count disagrees with the valid pixel total")
  }
  let details = Array::makei(bands, i => {
    let retained = matrix.counts[i][i]
    let gained = after_counts[i] - retained
    let lost = before_counts[i] - retained
    let exchange = if gained < lost { gained } else { lost }
    { retained, gained, lost, net: gained - lost, exchange, }
  })
  let cut_crossings : Array[NdviCutCrossing] = []
  let mut up = 0
  let mut down = 0
  for i, threshold in matrix.cut_points {
    up += up_delta[i]
    down += down_delta[i]
    cut_crossings.push({ threshold, up, down, net: up - down, })
  }
  // Half the L1 distance of equal-total marginals equals the sum of positive offsets.
  let quantity_disagreement = details.fold(init=0, (sum, band) => {
    sum + (if band.net > 0 { band.net } else { 0 })
  })
  {
    before_counts,
    after_counts,
    lower,
    same,
    higher,
    quantity_disagreement,
    allocation_disagreement: lower + higher - quantity_disagreement,
    bands: details,
    cut_crossings,
  }
}

///|
#derive(ToJson)
pub(all) struct NdviCountBounds {
  guaranteed : Int32
  observed : Int32
  possible : Int32
}

///|
#derive(ToJson)
pub(all) struct NdviThresholdBounds {
  threshold : Double
  margin : Double
  up : NdviCountBounds
  down : NdviCountBounds
  valid : Int32
  excluded : Int32
  water_excluded : Int32
  qa_screened : Bool
  land_only : Bool
  valid_fraction : Double
}

///|
pub extend NdviThresholdBounds with @json.ToJson::{to_json}

///|
/// Count guaranteed, observed, and possible crossings under independent bounded
/// perturbations of each measured NDVI. Equality belongs to the upper side.
pub fn ndvi_threshold_bounds(
  before : Chip,
  after : Chip,
  threshold : Double,
  margin : Double,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviThresholdBounds raise AuditError {
  let lower = threshold - margin
  let upper = threshold + margin
  if !(margin >= 0.0 && lower > -1.0 && upper < 1.0) {
    raise Invalid(
      "NDVI margin must be nonnegative, with both endpoints inside (-1, 1)",
    )
  }
  let cuts = if margin == 0.0 { [threshold] } else { [lower, threshold, upper] }
  let matrix = ndvi_transitions(
    before,
    after,
    cuts,
    screen_qa~,
    min_coverage~,
    land_only~,
  )
  let nominal = cuts.length() / 2
  let last_band = cuts.length()
  let mut observed_up = 0
  let mut observed_down = 0
  let mut possible_up = 0
  let mut possible_down = 0
  for i in 0..<matrix.counts.length() {
    for j in 0..<matrix.counts.length() {
      let count = matrix.counts[i][j]
      if i <= nominal && j > nominal {
        observed_up += count
      } else if i > nominal && j <= nominal {
        observed_down += count
      }
      if i < last_band && j > 0 {
        possible_up += count
      }
      if j < last_band && i > 0 {
        possible_down += count
      }
    }
  }
  {
    threshold,
    margin,
    up: {
      guaranteed: matrix.counts[0][last_band],
      observed: observed_up,
      possible: possible_up,
    },
    down: {
      guaranteed: matrix.counts[last_band][0],
      observed: observed_down,
      possible: possible_down,
    },
    valid: matrix.valid,
    excluded: matrix.excluded,
    water_excluded: matrix.water_excluded,
    qa_screened: matrix.qa_screened,
    land_only: matrix.land_only,
    valid_fraction: matrix.valid_fraction,
  }
}

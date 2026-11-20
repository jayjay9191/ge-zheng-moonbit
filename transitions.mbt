///|
#derive(ToJson)
pub(all) struct NdviTransitions {
  cut_points : Array[Double]
  counts : Array[Array[Int32]]
  valid : Int32
  excluded : Int32
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
/// Count before-band (row) to after-band (column) transitions on common valid pixels.
/// Cut points are strictly increasing in (-1, 1); equality enters the higher band.
pub fn ndvi_transitions(
  before : Chip,
  after : Chip,
  cut_points : Array[Double],
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
) -> NdviTransitions raise AuditError {
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
  validate_coverage(min_coverage)
  let { dx, dy, row0, row1, col0, col1, } = common_window(before, after)
  let bands = cut_points.length() + 1
  let counts = Array::makei(bands, _ => Array::make(bands, 0))
  let mut valid = 0
  for row in row0..<row1 {
    for col in col0..<col1 {
      let (reason_a, a) = pixel(before, row * before.width + col, screen_qa)
      let (reason_b, b) = pixel(
        after,
        (row - dy) * after.width + col - dx,
        screen_qa,
      )
      if reason_a == 0 && reason_b == 0 {
        counts[ndvi_band(a, cut_points)][ndvi_band(b, cut_points)] += 1
        valid += 1
      }
    }
  }
  let overlap = (row1 - row0) * (col1 - col0)
  ignore(shared_coverage(valid, overlap, min_coverage))
  { cut_points: cut_points.copy(), counts, valid, excluded: overlap - valid, }
}

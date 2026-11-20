///|
#derive(ToJson)
pub(all) struct ChangeCounts {
  gain : Int32
  loss : Int32
  stable : Int32
  valid : Int32
  excluded : Int32
}

///|
fn change_counts(audit : Audit) -> ChangeCounts {
  {
    gain: audit.gain,
    loss: audit.loss,
    stable: audit.stable,
    valid: audit.valid,
    excluded: audit.excluded,
  }
}

///|
#derive(ToJson)
pub(all) struct ThresholdCounts {
  threshold : Double
  counts : ChangeCounts
}

///|
#derive(ToJson)
pub(all) struct Sensitivity {
  rows : Array[ThresholdCounts]
  gain_relative_range : Double
  loss_relative_range : Double
  sensitive : Bool
  conclusion : String
}

///|
/// Relative range is (maximum - minimum) / maximum. All-zero counts give zero.
fn relative_range(values : Array[Int32]) -> Double {
  let mut lowest = values[0]
  let mut highest = values[0]
  for value in values {
    lowest = if value < lowest { value } else { lowest }
    highest = if value > highest { value } else { highest }
  }
  if highest == 0 {
    0.0
  } else {
    (highest - lowest).to_double() / highest.to_double()
  }
}

///|
/// Compare the same source pair at every threshold under the same QA policy.
pub fn sensitivity(
  before : Chip,
  after : Chip,
  thresholds : Array[Double],
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
) -> Sensitivity raise AuditError {
  if thresholds.is_empty() {
    raise Invalid("threshold sweep requires at least one threshold")
  }
  for threshold in thresholds {
    validate_threshold(threshold)
  }
  validate_coverage(min_coverage)
  let { dx, dy, col0, row0, col1, row1, } = common_window(before, after)
  let gains = Array::make(thresholds.length(), 0)
  let losses = Array::make(thresholds.length(), 0)
  let mut valid = 0
  for row in row0..<row1 {
    for col in col0..<col1 {
      let (reason_a, a) = pixel(before, row * before.width + col, screen_qa)
      let (reason_b, b) = pixel(
        after,
        (row - dy) * after.width + col - dx,
        screen_qa,
      )
      if reason_a != 0 || reason_b != 0 {
        continue
      }
      valid += 1
      let delta = b - a
      for i in 0..<thresholds.length() {
        match classify_change(delta, thresholds[i]) {
          1 => gains[i] += 1
          -1 => losses[i] += 1
          _ => ()
        }
      }
    }
  }
  let overlap = (row1 - row0) * (col1 - col0)
  ignore(shared_coverage(valid, overlap, min_coverage))
  let rows = Array::makei(thresholds.length(), i => {
    let gain = gains[i]
    let loss = losses[i]
    {
      threshold: thresholds[i],
      counts: {
        gain,
        loss,
        stable: valid - gain - loss,
        valid,
        excluded: overlap - valid,
      },
    }
  })
  let gain_relative_range = relative_range(rows.map(row => row.counts.gain))
  let loss_relative_range = relative_range(rows.map(row => row.counts.loss))
  let sensitive = gain_relative_range > 0.5 || loss_relative_range > 0.5
  {
    rows,
    gain_relative_range,
    loss_relative_range,
    sensitive,
    conclusion: if sensitive {
      "阈值敏感，须报告各档结果"
    } else {
      "在本次阈值集合内稳健"
    },
  }
}

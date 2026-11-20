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
  let rows : Array[ThresholdCounts] = []
  for threshold in thresholds {
    let result = compare(
      before,
      after,
      threshold,
      screen_qa~,
      min_coverage~,
      pixel_grids=false,
    )
    rows.push({ threshold, counts: change_counts(result), })
  }
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

///|
#derive(ToJson)
pub(all) struct QualityImpact {
  threshold : Double
  screened : ChangeCounts
  unscreened : ChangeCounts
  qa_added_exclusions : Int32
  gain_removed : Int32
  loss_removed : Int32
  changed_before : Int32
  changed_after : Int32
  changed_removed : Int32
  conclusion : String
}

///|
/// Hold sources and threshold fixed. Direct mode still rejects unusable signals.
pub fn qa_impact(
  before : Chip,
  after : Chip,
  threshold : Double,
  min_coverage~ : Double = 0.0,
) -> QualityImpact raise AuditError {
  validate_threshold(threshold)
  validate_coverage(min_coverage)
  let window = common_window(before, after)
  let thresholds = [threshold]
  let unscreened = count_thresholds(before, after, window, thresholds, false)[0].counts
  let overlap = unscreened.valid + unscreened.excluded
  ignore(shared_coverage(unscreened.valid, overlap, min_coverage))
  let screened = count_thresholds(before, after, window, thresholds, true)[0].counts
  if screened.valid != 0 || min_coverage > 0.0 {
    ignore(shared_coverage(screened.valid, overlap, min_coverage))
  }
  let changed_before = unscreened.gain + unscreened.loss
  let changed_after = screened.gain + screened.loss
  let qa_added_exclusions = screened.excluded - unscreened.excluded
  {
    threshold,
    screened,
    unscreened,
    qa_added_exclusions,
    gain_removed: unscreened.gain - screened.gain,
    loss_removed: unscreened.loss - screened.loss,
    changed_before,
    changed_after,
    changed_removed: changed_before - changed_after,
    conclusion: if screened.valid == 0 {
      "QA筛选后没有共同有效像元。筛选前达阈值 \{changed_before} 像元，不能据此推断实际变化。"
    } else {
      "QA新增排除\{qa_added_exclusions}像元，达阈值像元\{changed_before} → \{changed_after}；变化属于质检影响，须结合现场与源影像解释。"
    },
  }
}

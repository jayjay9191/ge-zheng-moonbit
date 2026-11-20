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
  let screened = change_counts(
    compare(before, after, threshold, min_coverage~, pixel_grids=false),
  )
  let unscreened = change_counts(
    compare(
      before,
      after,
      threshold,
      screen_qa=false,
      min_coverage~,
      pixel_grids=false,
    ),
  )
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
    conclusion: "QA新增排除\{qa_added_exclusions}像元，达阈值像元\{changed_before} → \{changed_after}；变化属于质检影响，须结合现场与源影像解释。",
  }
}

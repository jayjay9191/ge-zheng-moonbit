///|
test "review sample reproduces land-only NDVI movement" {
  let first : @lib.Chip = {
    scene: "review-first",
    date: "2024-09-09",
    epsg: 32650,
    x: 300000,
    y: 3500000,
    width: 3,
    height: 1,
    cell: 30,
    red: [20000, 20000, 20000],
    nir: [20000, 20000, 20000],
    qa: [0, 0, 8],
    saturation: [0, 0, 0],
  }
  let second = {
    ..first,
    scene: "review-second",
    date: "2024-09-25",
    nir: [10000, 25000, 25000],
    qa: [0, 128, 0],
  }
  let result = @lib.ndvi_transitions(first, second, [0.0], land_only=true)
  let summary = @lib.summarize_ndvi_transitions(result)
  assert_eq(result.counts, [[0, 0], [1, 0]])
  assert_eq((result.valid, result.excluded, result.water_excluded), (1, 2, 1))
  assert_eq((summary.lower, summary.same, summary.higher), (1, 0, 0))
  assert_eq(summary.bands.map(band => band.net), [1, -1])
  assert_eq(summary.bands.map(band => band.exchange), [0, 0])
  assert_true(result.land_only && result.qa_screened)
  assert_eq(result.valid_fraction, 1.0 / 3.0)
}

///|
test "review sample rejects a forged transition total" {
  let purported : @lib.NdviTransitions = {
    cut_points: [0.0],
    counts: [[1, 0], [0, 2]],
    valid: 2,
    excluded: 0,
    water_excluded: 0,
    qa_screened: true,
    land_only: false,
    valid_fraction: 1.0,
  }
  let result = Ok(@lib.summarize_ndvi_transitions(purported)) catch {
    err => Err(err)
  }
  assert_true(result is Err(_))
}

///|
test "review counts crossings at each cut, including a two-band jump" {
  let matrix : @lib.NdviTransitions = {
    cut_points: [0.2, 0.5],
    counts: [[1, 0, 4], [2, 0, 0], [3, 0, 0]],
    valid: 10,
    excluded: 0,
    water_excluded: 0,
    qa_screened: true,
    land_only: false,
    valid_fraction: 1.0,
  }
  let result = @lib.summarize_ndvi_transitions(matrix)
  assert_eq(
    result.cut_crossings.map(cut => (cut.threshold, cut.up, cut.down, cut.net)),
    [(0.2, 4, 5, -1), (0.5, 4, 3, 1)],
  )
  assert_eq(result.higher + result.lower, 9)
}

///|
fn review_threshold_pair() -> (@lib.Chip, @lib.Chip) {
  let before : @lib.Chip = {
    scene: "review-bounds-before",
    date: "2024-09-09",
    epsg: 32650,
    x: 300000,
    y: 3500000,
    width: 4,
    height: 1,
    cell: 30,
    red: [20000, 20000, 20000, 20000],
    nir: [16000, 19999, 20001, 24000],
    qa: [0, 0, 0, 0],
    saturation: [0, 0, 0, 0],
  }
  let after = {
    ..before,
    scene: "review-bounds-after",
    date: "2024-09-25",
    nir: [24000, 24000, 19999, 16000],
  }
  (before, after)
}

///|
test "review bounds threshold crossings under observation tolerance" {
  let (before, after) = review_threshold_pair()
  let bounds = @lib.ndvi_threshold_bounds(before, after, 0.0, 0.01)
  assert_eq(
    (bounds.up.guaranteed, bounds.up.observed, bounds.up.possible),
    (1, 2, 3),
  )
  assert_eq(
    (bounds.down.guaranteed, bounds.down.observed, bounds.down.possible),
    (1, 2, 2),
  )
  let fixed = @lib.ndvi_threshold_bounds(before, after, 0.0, 0.0)
  assert_eq(
    (fixed.up.guaranteed, fixed.up.observed, fixed.up.possible),
    (2, 2, 2),
  )
  let invalid = Ok(@lib.ndvi_threshold_bounds(before, after, 0.99, 0.02)) catch {
    err => Err(err)
  }
  assert_true(invalid is Err(_))
}

///|
test "review signed change takes its exact extrema even when both directions are possible" {
  let (before, after) = review_threshold_pair()
  let bounds = @lib.ndvi_threshold_bounds(before, after, 0.0, 0.01)
  assert_eq(
    (bounds.net.minimum, bounds.net.observed, bounds.net.maximum),
    (-1, 0, 2),
  )
  let reverse = @lib.ndvi_threshold_bounds(after, before, 0.0, 0.01)
  assert_eq(
    (reverse.net.minimum, reverse.net.observed, reverse.net.maximum),
    (-2, 0, 1),
  )
}

///|
test "review locates the first tested tolerance that can erase the direction" {
  let (before, base) = review_threshold_pair()
  let after = { ..base, nir: [24000, 24000, 19999, 24000], }
  let sweep = @lib.ndvi_margin_sweep(before, after, 0.0, [0.0, 0.01])
  assert_eq(
    sweep.rows.map(row => (row.net.minimum, row.net.observed, row.net.maximum)),
    [(1, 1, 1), (0, 1, 3)],
  )
  assert_eq(sweep.first_inconclusive_margin, Some(0.01))
  let invalid = Ok(@lib.ndvi_margin_sweep(before, after, 0.0, [0.01, 0.01])) catch {
    err => Err(err)
  }
  assert_true(invalid is Err(_))
}

///|
test "review critical tolerance distinguishes a strict endpoint from an inclusive one" {
  let (base, next) = review_threshold_pair()
  let before = {
    ..base,
    width: 1,
    red: [20000],
    nir: [20000],
    qa: [0],
    saturation: [0],
  }
  let after = {
    ..next,
    width: 1,
    red: [20000],
    nir: [16000],
    qa: [0],
    saturation: [0],
  }
  let strict = @lib.ndvi_critical_margin(before, after, 0.0)
  assert_eq(
    (
      strict.observed_net,
      strict.margin_infimum,
      strict.zero_possible_at_infimum,
    ),
    (-1, 0.0, false),
  )
  let high = { ..before, nir: [26000], }
  let near = { ..after, nir: [19999], }
  let inclusive = @lib.ndvi_critical_margin(high, near, 0.0)
  assert_eq(inclusive.observed_net, -1)
  assert_true(
    inclusive.margin_infimum > 0.0 && inclusive.margin_infimum < 0.001,
  )
  assert_true(inclusive.zero_possible_at_infimum)
  // Swapped red and NIR produce exactly opposite NDVI and a tied pair of flip distances.
  let mirror = { ..near, red: [26000], nir: [20000], }
  let tied = @lib.ndvi_critical_margin(high, mirror, 0.0)
  assert_true(tied.zero_possible_at_infimum)
  assert_true(tied.margin_infimum > inclusive.margin_infimum)
  let reversed = @lib.ndvi_critical_margin(near, high, 0.0)
  assert_eq(
    (
      reversed.observed_net,
      reversed.margin_infimum,
      reversed.zero_possible_at_infimum,
    ),
    (1, inclusive.margin_infimum, true),
  )
}

///|
test "review neutralization counts paired pixels rather than date observations" {
  let (a, b) = review_threshold_pair()
  let before = {
    ..a,
    width: 2,
    red: [20000, 20000],
    nir: [20001, 24000],
    qa: [0, 0],
    saturation: [0, 0],
  }
  let after = {
    ..b,
    width: 2,
    red: [20000, 20000],
    nir: [19999, 16000],
    qa: [0, 0],
    saturation: [0, 0],
  }
  let result = @lib.ndvi_threshold_bounds(before, after, 0.0, 0.01)
  assert_eq(result.net.observed, -2)
  assert_eq(result.neutralization.double_step_pairs, 1)
  assert_eq(result.neutralization.minimum_changed_pairs, Some(1))
  let fixed = @lib.ndvi_threshold_bounds(before, after, 0.0, 0.0)
  assert_true(fixed.neutralization.minimum_changed_pairs is None)
  let reverse = @lib.ndvi_threshold_bounds(after, before, 0.0, 0.01)
  assert_eq(reverse.neutralization.minimum_changed_pairs, Some(1))
}

///|
test "review sparse witness names one paired cell and both date flips" {
  let (a, b) = review_threshold_pair()
  let before = {
    ..a,
    width: 2,
    red: [20000, 20000],
    nir: [24000, 20001],
    qa: [0, 0],
    saturation: [0, 0],
  }
  let after = {
    ..b,
    width: 2,
    red: [20000, 20000],
    nir: [16000, 19999],
    qa: [0, 0],
    saturation: [0, 0],
  }
  guard @lib.ndvi_neutralization_witness(before, after, 0.0, 0.01)
    is Some(witness) else {
    abort("expected a constructive witness")
  }
  assert_eq(witness.length(), 1)
  assert_eq((witness[0].row, witness[0].column), (0, 1))
  assert_true(witness[0].flip is BothDates)
  let clipped = Ok(
    @lib.ndvi_neutralization_witness(before, after, 0.0, 0.01, limit=0),
  ) catch {
    err => Err(err)
  }
  assert_true(clipped is Err(_))
  assert_true(@lib.ndvi_neutralization_witness(before, after, 0.0, 0.0) is None)
}

///|
test "review rejects a repeated cell, forbidden flip and wrong coverage in an external witness" {
  let (a, b) = review_threshold_pair()
  let before = {
    ..a,
    width: 2,
    red: [20000, 20000],
    nir: [24000, 20001],
    qa: [0, 0],
    saturation: [0, 0],
  }
  let after = {
    ..b,
    width: 2,
    red: [20000, 20000],
    nir: [16000, 19999],
    qa: [0, 0],
    saturation: [0, 0],
  }
  let both : @lib.NdviPairWitness = { row: 0, column: 1, flip: BothDates, }
  let accepted = @lib.verify_ndvi_witness(before, after, 0.0, 0.01, [both])
  guard accepted is Ok(audit) else { abort("expected valid minimal witness") }
  assert_eq(
    (audit.observed_net, audit.final_net, audit.changed_pairs),
    (-2, 0, 1),
  )
  assert_true(
    @lib.verify_ndvi_witness(before, after, 0.0, 0.01, [both, both])
    is Err(RepeatedCell(0, 1)),
  )
  assert_true(
    @lib.verify_ndvi_witness(before, after, 0.0, 0.01, [{ ..both, column: 0, }])
    is Err(OutsideTolerance(0, 0)),
  )
  assert_true(
    @lib.verify_ndvi_witness(before, after, 0.0, 0.01, [{ ..both, column: 2, }])
    is Err(OutsideCoverage(0, 2)),
  )
  assert_true(
    @lib.verify_ndvi_witness(before, after, 0.0, 0.01, [
      { ..both, flip: AfterDate, },
    ])
    is Err(NonNeutral(-1)),
  )
  let balance_before = { ..before, nir: [20001, 19999], }
  let balance_after = { ..after, nir: [19999, 20001], }
  let unnecessary = [both, { ..both, column: 0, }]
  assert_true(
    @lib.verify_ndvi_witness(
      balance_before, balance_after, 0.0, 0.01, unnecessary,
    )
    is Err(NonMinimal(0)),
  )
}

///|
test "review scarce pairs increase the neutralization margin" {
  let (a, b) = review_threshold_pair()
  let before = {
    ..a,
    width: 3,
    red: [20000, 20000, 20000],
    nir: [20001, 20100, 16000],
    qa: [0, 0, 0],
    saturation: [0, 0, 0],
  }
  let after = {
    ..b,
    width: 3,
    red: [20000, 20000, 20000],
    nir: [16000, 19800, 19999],
    qa: [0, 0, 0],
    saturation: [0, 0, 0],
  }
  let zero = @lib.ndvi_budget_margin(before, after, 0.0, 0)
  assert_eq(zero.observed_net, -2)
  assert_true(zero.critical is None)
  let one = @lib.ndvi_budget_margin(before, after, 0.0, 1).critical.unwrap()
  let two = @lib.ndvi_budget_margin(before, after, 0.0, 2).critical.unwrap()
  assert_true(one.margin > two.margin && two.margin > 0.0)
  assert_true(one.attained && two.attained)
  assert_eq(
    two.margin,
    @lib.ndvi_critical_margin(before, after, 0.0).margin_infimum,
  )
}

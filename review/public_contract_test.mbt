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

///|
test "review batched budgets preserve order, duplicates and strict endpoints" {
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
  let rows = @lib.ndvi_budget_margins(before, after, 0.0, [2, 0, 1, 2])
  assert_eq(rows.map(row => row.pair_budget), [2, 0, 1, 2])
  assert_eq(rows.map(row => row.observed_net), [-1, -1, -1, -1])
  assert_true(rows[1].critical is None)
  for index in [0, 2, 3] {
    let critical = rows[index].critical.unwrap()
    assert_eq((critical.margin, critical.attained), (0.0, false))
  }
  let balanced = @lib.ndvi_budget_margins(before, before, 0.0, [0, 10])
  assert_true(balanced.all(row => row.critical.unwrap().attained))
}

///|
test "review equal calibration events can jump across zero without reaching it" {
  let (base, next) = review_threshold_pair()
  let before = {
    ..base,
    width: 3,
    red: [20000, 20000, 20000],
    nir: [24000, 24000, 16000],
    qa: [0, 0, 0],
    saturation: [0, 0, 0],
  }
  let after = {
    ..next,
    width: 3,
    red: [20000, 20000, 20000],
    nir: [24000, 20000, 20000],
    qa: [0, 0, 0],
    saturation: [0, 0, 0],
  }
  let envelope = @lib.ndvi_calibration_bounds(before, after, 0.0, 0.001)
  assert_eq(
    (envelope.minimum, envelope.observed_net, envelope.maximum),
    (-1, 1, 1),
  )
  assert_true(envelope.first_zero_offset is None)
  let nominal = @lib.ndvi_calibration_bounds(before, after, 0.0, 0.0)
  assert_eq((nominal.minimum, nominal.maximum), (1, 1))
  let high = { ..before, red: [8000, 8000, 16000], nir: [24000, 24000, 16000], }
  let equal = { ..after, red: [8000, 8000, 16000], nir: [24000, 9000, 28000], }
  let ratio = @lib.ndvi_calibration_bounds(high, equal, 11.0 / 27.0, 0.001)
  assert_eq((ratio.minimum, ratio.maximum), (-1, 1))
  assert_true(ratio.first_zero_offset is None)
}

///|
test "alignment stress keeps one valid population across all five offsets" {
  let before : @lib.Chip = {
    scene: "stress-before",
    date: "2024-09-09",
    epsg: 32650,
    x: 300000,
    y: 3500000,
    width: 4,
    height: 4,
    cell: 30,
    red: Array::make(16, 20000),
    nir: Array::make(16, 20000),
    qa: Array::make(16, 0),
    saturation: Array::make(16, 0),
  }
  let nir = before.nir.copy()
  nir[5] = 35000
  let after = { ..before, scene: "stress-after", date: "2024-09-25", nir, }
  let audit = @lib.alignment_stress(before, after, 0.15)
  assert_eq(
    (audit.width, audit.height, audit.valid, audit.unstable),
    (2, 2, 4, 3),
  )
  assert_eq(audit.stability, [2, 2, 2, 0])
  assert_eq((audit.min_change_m2, audit.max_change_m2), (0L, 900L))
  let qa = after.qa.copy()
  qa[5] = 8
  let masked = @lib.alignment_stress(before, { ..after, qa, }, 0.15)
  assert_eq(masked.stability, [-2, -2, -2, 0])
  assert_eq((masked.valid, masked.valid_fraction), (1, 0.25))
  let shifted = @lib.alignment_stress(
    before,
    { ..after, x: after.x + 30, },
    0.15,
  )
  assert_eq(
    (shifted.x, shifted.y, shifted.width, shifted.height),
    (300060, 3499970, 2, 2),
  )
}

///|
test "pixelwise change bounds distinguish certain magnitude from uncertain sign" {
  let chip : @lib.Chip = {
    scene: "before",
    date: "2024-09-09",
    epsg: 32650,
    x: 300000,
    y: 3500000,
    width: 5,
    height: 3,
    cell: 30,
    red: Array::make(15, 20000),
    nir: Array::make(15, 20000),
    qa: Array::make(15, 0),
    saturation: Array::make(15, 0),
  }
  let nir = Array::make(15, 35000)
  nir[5] = 8000
  nir[9] = 20000
  let after = { ..chip, scene: "after", date: "2024-09-25", nir, }
  let (stress, bounds) = @lib.alignment_stress_with_bounds(chip, after, 0.15)
  assert_eq(stress.stability, [2, 1, 2])
  assert_eq(
    (bounds.certain_change_m2, bounds.possible_change_m2),
    (1800L, 2700L),
  )
  assert_eq(bounds.opposite_direction, 1)
  let qa = after.qa.copy()
  qa[5] = 8
  let (_, masked) = @lib.alignment_stress_with_bounds(
    chip,
    { ..after, qa, },
    0.15,
  )
  assert_eq(
    (masked.certain_change_m2, masked.possible_change_m2),
    (900L, 1800L),
  )
  assert_eq(masked.opposite_direction, 0)
}

///|
test "square sampling detects diagonal-only change and excludes corner clouds" {
  let before : @lib.Chip = {
    scene: "before",
    date: "2024-09-09",
    epsg: 32650,
    x: 300000,
    y: 3500000,
    width: 3,
    height: 3,
    cell: 30,
    red: Array::make(9, 20000),
    nir: Array::make(9, 20000),
    qa: Array::make(9, 0),
    saturation: Array::make(9, 0),
  }
  let nir = before.nir.copy()
  nir[0] = 35000
  nir[8] = 8000
  let after = { ..before, scene: "after", date: "2024-09-25", nir, }
  let (cross, _) = @lib.alignment_stress_with_bounds(before, after, 0.15)
  let (square, bounds) = @lib.alignment_stress_with_bounds(
    before,
    after,
    0.15,
    include_diagonals=true,
  )
  assert_eq(cross.stability, [0])
  assert_eq(square.stability, [2])
  assert_eq(square.scenarios.length(), 9)
  assert_eq((bounds.possible_change_m2, bounds.opposite_direction), (900L, 1))
  let qa = after.qa.copy()
  qa[0] = 8
  let cloudy = { ..after, qa, }
  assert_eq(@lib.alignment_stress(before, cloudy, 0.15).valid, 1)
  assert_true(
    try {
      ignore(
        @lib.alignment_stress_with_bounds(
          before,
          cloudy,
          0.15,
          include_diagonals=true,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "alignment threshold sweep preserves repeated cutoffs and matches individual bounds" {
  let before : @lib.Chip = {
    scene: "sweep-before",
    date: "2024-09-09",
    epsg: 32650,
    x: 300000,
    y: 3500000,
    width: 3,
    height: 3,
    cell: 30,
    red: Array::make(9, 20000),
    nir: Array::make(9, 20000),
    qa: Array::make(9, 0),
    saturation: Array::make(9, 0),
  }
  let after = {
    ..before,
    scene: "sweep-after",
    date: "2024-09-25",
    nir: [35000, 20000, 20000, 20000, 20000, 20000, 20000, 20000, 8000],
  }
  let thresholds = [2.0, 0.15, 0.15, 0.01]
  let sweep = @lib.alignment_threshold_sweep(
    before,
    after,
    thresholds,
    include_diagonals=true,
  )
  assert_eq(sweep.rows.map(row => row.threshold), thresholds)
  assert_eq((sweep.valid, sweep.offsets), (1, 9))
  for row in sweep.rows {
    let (_, expected) = @lib.alignment_stress_with_bounds(
      before,
      after,
      row.threshold,
      include_diagonals=true,
    )
    assert_eq(Json(row.bounds), Json(expected))
  }
  assert_eq(sweep.rows[0].bounds.possible_change_m2, 0L)
  assert_eq(sweep.rows[1].bounds.opposite_direction, 1)
  assert_eq(sweep.rows[1].bounds.certain_change_m2, 0L)
}

///|
test "decimal NDVI changes at the inclusive cutoff survive scaled reflectance" {
  // These digital numbers give exactly 11/100 and 33/100 after scaling.
  let first : @lib.Chip = {
    scene: "cutoff-before",
    date: "2024-09-09",
    epsg: 32650,
    x: 300000,
    y: 3500000,
    width: 3,
    height: 3,
    cell: 30,
    red: Array::make(9, 12014),
    nir: Array::make(9, 13186),
    qa: Array::make(9, 0),
    saturation: Array::make(9, 0),
  }
  let second = {
    ..first,
    scene: "cutoff-after",
    date: "2024-09-25",
    red: Array::make(9, 12048),
    nir: Array::make(9, 16752),
  }
  let cut = 0.22
  let next_cut = 0.22000000000000003
  for (a, b, code) in [(first, second, 1), (second, first, -1)] {
    let result = @lib.compare(a, b, cut)
    assert_eq(result.classes, Array::make(9, code))
    assert_true(
      result.delta[0] is Some(actual) && actual == code.to_double() * cut,
    )
    assert_eq(@lib.inspect_sources(a, b, cut, 2, 2).class_code, code)
    assert_eq(@lib.inspect_pixel(a, b, result, 2, 2).class_code, code)
    assert_eq(@lib.compare(a, b, next_cut).stable, 9)
    let sweep = @lib.sensitivity(a, b, [next_cut, cut])
    assert_eq(sweep.rows[0].counts.stable, 9)
    assert_eq(sweep.rows[1].counts.gain + sweep.rows[1].counts.loss, 9)
    let (stress, _) = @lib.alignment_stress_with_bounds(
      a,
      b,
      cut,
      include_diagonals=true,
    )
    assert_eq(stress.stability, [code])
    let alignment = @lib.alignment_threshold_sweep(
      a,
      b,
      [cut, next_cut],
      include_diagonals=true,
    )
    assert_eq(alignment.rows[0].bounds.certain_change_m2, 900L)
    assert_eq(alignment.rows[1].bounds.possible_change_m2, 0L)
  }
  let transitions = @lib.ndvi_transitions(first, second, [0.11, 0.33])
  assert_eq(transitions.counts, [[0, 0, 0], [0, 0, 9], [0, 0, 0]])
}

///|
test "reported critical margins agree with bounds and witness replay at adjacent Doubles" {
  let (a, b) = review_threshold_pair()
  // With DN sum 17000, each step of 270 in band difference is NDVI 0.11.
  let chip = (base : @lib.Chip, step : Int32) => {
    ..base,
    width: 1,
    red: [8500 - 135 * step],
    nir: [8500 + 135 * step],
    qa: [0],
    saturation: [0],
  }
  for
    (before_step, after_step, threshold, critical, attained, margins, feasible) in [
      (
        -1,
        8,
        0.33,
        0.44,
        true,
        [0.43999999999999995, 0.44, 0.44000000000000006],
        [false, true, true],
      ),
      (
        -6,
        1,
        -0.22,
        0.33,
        false,
        [0.32999999999999996, 0.33, 0.33000000000000007],
        [false, false, true],
      ),
      (1, 3, 0.33, 0.0, false, [0.0, 1.0e-18], [false, true]),
    ] {
    let first = chip(a, before_step)
    let second = chip(b, after_step)
    for (before, after) in [(first, second), (second, first)] {
      let boundary = @lib.ndvi_critical_margin(before, after, threshold)
      assert_eq(
        (boundary.margin_infimum, boundary.zero_possible_at_infimum),
        (critical, attained),
      )
      let budget = @lib.ndvi_budget_margin(before, after, threshold, 1).critical.unwrap()
      assert_eq((budget.margin, budget.attained), (critical, attained))
      let sweep = @lib.ndvi_margin_sweep(before, after, threshold, margins)
      for i, margin in margins {
        let actual = @lib.ndvi_threshold_bounds(
          before, after, threshold, margin,
        )
        assert_eq(Json(actual.net), Json(sweep.rows[i].net))
        assert_eq(
          actual.neutralization.minimum_changed_pairs is Some(1),
          feasible[i],
        )
        let witness = @lib.ndvi_neutralization_witness(
          before, after, threshold, margin,
        )
        assert_eq(witness is Some(_), feasible[i])
        if witness is Some(cells) {
          assert_true(
            @lib.verify_ndvi_witness(before, after, threshold, margin, cells)
            is Ok(_),
          )
        }
      }
    }
  }
}

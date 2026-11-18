///|
fn test_chip(
  x : Int32,
  y : Int32,
  red : Array[Int32],
  qa : Array[Int32],
) -> Chip {
  {
    scene: "fixture",
    date: "2024-04-18",
    epsg: 32650,
    x,
    y,
    width: red.length(),
    height: 1,
    cell: 30,
    red,
    nir: Array::make(red.length(), 18000),
    qa,
    saturation: Array::make(red.length(), 0),
  }
}

///|
test "same chip, cloud exclusion and half-cell shift" {
  let a = test_chip(300000, 3500000, [10000, 10000], [0, 8])
  let result = compare(a, a, 0.15)
  assert_eq(result.valid, 1)
  assert_eq(result.gain + result.loss, 0)
  assert_eq(result.first_qa.cloud, 1)
  let shifted = { ..a, x: a.x + 15, }
  let denied = Ok(compare(a, shifted, 0.15)) catch { e => Err(e) }
  assert_true(denied is Err(_))
}

///|
test "whole-cell offsets compare the overlapping pixels by location" {
  let first = test_chip(300000, 3500000, [10000, 12000, 14000], [0, 0, 0])
  let second = test_chip(300030, 3500000, [12000, 14000, 16000], [0, 0, 0])
  let result = compare(first, second, 0.15)
  assert_eq(result.overlap, 2)
  assert_eq(result.valid, 2)
  assert_eq(result.gain + result.loss, 0)
}

///|
test "QA masks cloud, shadow, snow, saturation and unusable reflectance" {
  let chip = test_chip(
    300000,
    3500000,
    [10000, 10000, 0, 10000, 10000, 10000, 65000],
    [0, 8, 0, 16, 32, 0, 0],
  )
  let chip = { ..chip, saturation: [0, 0, 0, 0, 0, 8, 0], }
  let result = compare(chip, chip, 0.15)
  let q = result.first_qa
  assert_eq(result.valid, 1)
  assert_eq(result.excluded, 6)
  assert_eq(
    [q.fill, q.cloud, q.shadow, q.snow, q.saturated, q.unusable_signal],
    [1, 1, 1, 1, 1, 1],
  )
  let other = { ..chip, epsg: 32651, }
  assert_true((Ok(compare(chip, other, 0.15)) catch { e => Err(e) }) is Err(_))
}

///|
test "direct comparison isolates QA exclusion on the same grid" {
  let a = test_chip(300000, 3500000, [14000, 14000], [0, 0])
  let b = { ..a, red: [14000, 10000], qa: [0, 8], }
  let screened = compare(a, b, 0.15)
  let direct = compare(a, b, 0.15, screen_qa=false)
  assert_eq(screened.classes, [0, -2])
  assert_eq(direct.classes, [0, 1])
  assert_true(screened.qa_screened)
  assert_false(direct.qa_screened)
}

///|
test "QA findings identify which date caused each exclusion" {
  let before = test_chip(300000, 3500000, [10000, 10000, 10000], [0, 8, 0])
  let after = { ..before, qa: [0, 0, 16], }
  let result = compare(before, after, 0.15)
  assert_eq(result.before_reason, [0, 2, 0])
  assert_eq(result.after_reason, [0, 0, 3])
  assert_eq(result.classes, [0, -2, -2])
}

///|
test "coverage threshold is inclusive and blocks unsupported area conclusions" {
  let a = test_chip(300000, 3500000, [10000, 10000], [0, 8])
  assert_eq(compare(a, a, 0.15, min_coverage=0.5).valid, 1)
  let denied = Ok(compare(a, a, 0.15, min_coverage=0.6)) catch { e => Err(e) }
  assert_true(denied is Err(Invalid(message)) && message.contains("1/2"))
}

///|
test "pixel evidence traces both source values across an integer offset" {
  let a = test_chip(300000, 3500000, [10000, 12000, 14000], [0, 0, 0])
  let b = test_chip(300030, 3500000, [13000, 14000, 16000], [8, 0, 0])
  let result = compare(a, b, 0.15)
  let evidence = inspect_pixel(a, b, result, 1, 1)
  assert_eq(evidence.x_center, 300045)
  assert_eq(evidence.red_before, 12000)
  assert_eq(evidence.red_after, 13000)
  assert_eq(evidence.qa_after, 8)
  assert_eq(evidence.reason_after, 2)
  assert_true(evidence.delta is None)
  assert_true(
    (Ok(inspect_pixel(a, b, result, 1, 3)) catch { e => Err(e) }) is Err(_),
  )
}

///|
test "summary avoids retaining grids without changing the coverage or totals" {
  let a = test_chip(300000, 3500000, [10000, 10000], [0, 8])
  let full = compare(a, a, 0.15)
  let light = compare(a, a, 0.15, pixel_grids=false)
  assert_eq(light.valid, full.valid)
  assert_eq(light.stable, full.stable)
  assert_eq(light.first_qa.cloud, full.first_qa.cloud)
  assert_true(
    light.delta.is_empty() &&
    light.classes.is_empty() &&
    light.before_reason.is_empty(),
  )
}

///|
test "invalid band sizes and unsigned samples fail before comparison" {
  let base = test_chip(300000, 3500000, [11000, 14000], [0, 0])
  for
    bad in [
      { ..base, nir: [18000], },
      { ..base, qa: [0, -1], },
      { ..base, saturation: [0, 65536], },
    ] {
    let result = Ok(compare(base, bad, 0.15)) catch { e => Err(e) }
    assert_true(result is Err(Invalid(reason)) && reason.contains("UInt16"))
  }
}

///|
test "disjoint inputs and zero joint valid coverage are rejected" {
  let base = test_chip(300000, 3500000, [11000, 14000], [0, 0])
  let outside = { ..base, x: base.x + 60, }
  let cloudy = { ..base, qa: [8, 8], }
  let disjoint = Ok(compare(base, outside, 0.15)) catch { e => Err(e) }
  let no_valid = Ok(compare(base, cloudy, 0.15)) catch { e => Err(e) }
  assert_true(
    disjoint is Err(Invalid(reason)) && reason.contains("do not overlap"),
  )
  assert_true(
    no_valid is Err(Invalid(reason)) && reason.contains("no pixels are valid"),
  )
}

///|
test "water flags preserve four transitions and excluded pixels stay unknown" {
  let a = test_chip(300000, 3500000, [14000, 14000, 10000, 10000, 14000], [
    0, 128, 0, 128, 8,
  ])
  let b = {
    ..a,
    red: [10000, 14000, 14000, 10000, 10000],
    qa: [0, 0, 128, 128, 0],
  }
  let audit = compare(a, b, 0.15)
  assert_eq(audit.water_code, [0, 1, 2, 3, -1])
  assert_eq(audit.classes, [1, 0, -1, 0, -2])
  assert_eq(
    [
      audit.both_nonwater_valid,
      audit.before_only_water,
      audit.after_only_water,
      audit.both_water,
    ],
    [1, 1, 1, 1],
  )
  assert_eq([audit.gain_m2, audit.loss_m2], [900L, 900L])
  assert_eq([audit.both_nonwater_gain, audit.both_nonwater_loss], [1, 0])
}

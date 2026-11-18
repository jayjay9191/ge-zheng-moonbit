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

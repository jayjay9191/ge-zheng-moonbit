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
}

///|
test "review sample rejects a forged transition total" {
  let purported : @lib.NdviTransitions = {
    cut_points: [0.0],
    counts: [[1, 0], [0, 2]],
    valid: 2,
    excluded: 0,
    water_excluded: 0,
  }
  let result = Ok(@lib.summarize_ndvi_transitions(purported)) catch {
    err => Err(err)
  }
  assert_true(result is Err(_))
}

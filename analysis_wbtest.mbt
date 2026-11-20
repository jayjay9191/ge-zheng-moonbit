///|
extern "js" fn analysis_fixture(path : String) -> String =
  #|(path) => process.getBuiltinModule("fs").readFileSync(path, "utf8")

///|
fn analysis_pair(feidong : Bool) -> (Chip, Chip) raise {
  let dir = if feidong { "data/feidong/" } else { "data/" }
  (
    parse_chip(analysis_fixture(dir + "scene-1.json")),
    parse_chip(analysis_fixture(dir + "scene-2.json")),
  )
}

///|
test "Chaohu threshold sweep reproduces three measured classifications" {
  let (a, b) = analysis_pair(false)
  let report = sensitivity(a, b, [0.10, 0.15, 0.20])
  for i in 0..<3 {
    assert_eq(report.rows[i].counts.gain, [11446, 10703, 10013][i])
    assert_eq(report.rows[i].counts.loss, [285, 94, 52][i])
    assert_eq(report.rows[i].counts.valid, 14224)
    assert_eq(report.rows[i].counts.excluded, 2160)
    assert_eq(
      report.rows[i].counts.stable,
      14224 - report.rows[i].counts.gain - report.rows[i].counts.loss,
    )
  }
}

///|
test "Feidong threshold sweep identifies loss sensitivity" {
  let (a, b) = analysis_pair(true)
  let report = sensitivity(a, b, [0.10, 0.15, 0.20])
  for i in 0..<3 {
    assert_eq(report.rows[i].counts.gain, [155, 86, 49][i])
    assert_eq(report.rows[i].counts.loss, [1495, 577, 290][i])
    assert_eq(report.rows[i].counts.valid, 11257)
    assert_eq(report.rows[i].counts.excluded, 5127)
  }
  assert_true(report.loss_relative_range > 0.80)
  assert_true(report.sensitive)
}

///|
test "one threshold and unchanged pixels have zero relative range" {
  let a = test_chip(300000, 3500000, [10000, 12000], [0, 0])
  let report = sensitivity(a, a, [0.15])
  assert_eq(report.gain_relative_range, 0.0)
  assert_eq(report.loss_relative_range, 0.0)
  assert_false(report.sensitive)
}

///|
test "empty thresholds are rejected" {
  let a = test_chip(300000, 3500000, [10000], [0])
  assert_true(
    (Ok(sensitivity(a, a, [])) catch { e => Err(e) }) is Err(Invalid(_)),
  )
}

///|
test "invalid thresholds including non-finite inputs are rejected" {
  let a = test_chip(300000, 3500000, [10000], [0])
  for value in [0.0, -0.1, 2.01, 0.0 / 0.0, 1.0 / 0.0] {
    assert_true(
      (Ok(sensitivity(a, a, [0.1, value])) catch { e => Err(e) })
      is Err(Invalid(_)),
    )
  }
  assert_eq(sensitivity(a, a, [2.0]).rows[0].counts.stable, 1)
}

///|
test "sweep preserves coverage policy and direct QA mode" {
  let a = test_chip(300000, 3500000, [10000, 10000], [0, 8])
  assert_true(
    (Ok(sensitivity(a, a, [0.15], min_coverage=0.6)) catch { e => Err(e) })
    is Err(_),
  )
  assert_eq(sensitivity(a, a, [0.15], screen_qa=false).rows[0].counts.valid, 2)
}

///|
test "Chaohu QA impact reproduces both sides of the measured pair" {
  let (a, b) = analysis_pair(false)
  let report = qa_impact(a, b, 0.15)
  assert_eq(
    [report.screened.gain, report.screened.loss, report.screened.excluded],
    [10703, 94, 2160],
  )
  assert_eq(
    [report.unscreened.gain, report.unscreened.loss, report.unscreened.excluded],
    [10981, 258, 0],
  )
  assert_eq(report.qa_added_exclusions, 2160)
  assert_eq([report.gain_removed, report.loss_removed], [278, 164])
}

///|
test "Feidong QA impact computes 3031 to 663 instead of hardcoding it" {
  let (a, b) = analysis_pair(true)
  let report = qa_impact(a, b, 0.15)
  assert_eq(
    [report.screened.gain, report.screened.loss, report.screened.excluded],
    [86, 577, 5127],
  )
  assert_eq(
    [report.unscreened.gain, report.unscreened.loss, report.unscreened.excluded],
    [2058, 973, 7],
  )
  assert_eq([report.changed_before, report.changed_after], [3031, 663])
  assert_eq(report.qa_added_exclusions, 5120)
  assert_eq(report.changed_removed, 2368)
}

///|
test "QA impact distinguishes reflectance exclusions from QA exclusions" {
  let a = test_chip(300000, 3500000, [10000, 65000], [0, 0])
  let report = qa_impact(a, a, 0.15)
  assert_eq(report.unscreened.excluded, 1)
  assert_eq(report.qa_added_exclusions, 0)
  assert_eq(report.changed_removed, 0)
}

///|
test "QA impact validates thresholds and shared coverage" {
  let a = test_chip(300000, 3500000, [10000, 10000], [0, 8])
  assert_true((Ok(qa_impact(a, a, 0.0)) catch { e => Err(e) }) is Err(_))
  for minimum in [-0.1, 1.1] {
    assert_true(
      (Ok(qa_impact(a, a, 0.15, min_coverage=minimum)) catch { e => Err(e) })
      is Err(Invalid(_)),
    )
  }
  assert_true(
    (Ok(qa_impact(a, a, 0.15, min_coverage=0.6)) catch { e => Err(e) })
    is Err(_),
  )
}

///|
test "2x2 tiles sum to the complete real window for both sites" {
  for feidong in [false, true] {
    let (a, b) = analysis_pair(feidong)
    let whole = compare(a, b, 0.15)
    let blocks = tile_counts(whole)
    assert_eq(blocks.length(), 4)
    assert_eq(blocks.fold(init=0, (n, t) => n + t.counts.gain), whole.gain)
    assert_eq(blocks.fold(init=0, (n, t) => n + t.counts.loss), whole.loss)
    assert_eq(blocks.fold(init=0, (n, t) => n + t.counts.stable), whole.stable)
    assert_eq(blocks.fold(init=0, (n, t) => n + t.counts.valid), whole.valid)
    assert_eq(
      blocks.fold(init=0, (n, t) => n + t.counts.excluded),
      whole.excluded,
    )
  }
}

///|
test "1x1 tiles equal the complete window" {
  let a = test_chip(300000, 3500000, [10000, 10000], [0, 8])
  let report = compare(a, a, 0.15)
  let blocks = tile_counts(report, rows=1, columns=1)
  assert_eq(blocks.length(), 1)
  assert_eq([blocks[0].counts.valid, blocks[0].counts.excluded], [1, 1])
}

///|
test "uneven tile boundaries cover all pixels exactly once" {
  let a = {
    ..test_chip(300000, 3500000, Array::make(15, 10000), Array::make(15, 0)),
    width: 5,
    height: 3,
  }
  let blocks = tile_counts(compare(a, a, 0.15), rows=2, columns=2)
  assert_eq(blocks.map(t => t.counts.stable), [2, 3, 4, 6])
  assert_eq([blocks[3].row_start, blocks[3].column_start], [1, 2])
}

///|
test "tile dimensions outside the common window are rejected" {
  let a = test_chip(300000, 3500000, [10000, 10000], [0, 0])
  let report = compare(a, a, 0.15)
  for (rows, columns) in [(0, 1), (1, 0), (-1, 1), (2, 1), (1, 3)] {
    assert_true(
      (Ok(tile_counts(report, rows~, columns~)) catch { e => Err(e) })
      is Err(Invalid(_)),
    )
  }
}

///|
test "tiles reject summary-only results and unsupported class values" {
  let a = test_chip(300000, 3500000, [10000], [0])
  assert_true(
    (Ok(tile_counts(compare(a, a, 0.15, pixel_grids=false), rows=1, columns=1)) catch {
      e => Err(e)
    })
    is Err(_),
  )
  let invalid = { ..compare(a, a, 0.15), classes: [7], }
  assert_true(
    (Ok(tile_counts(invalid, rows=1, columns=1)) catch { e => Err(e) })
    is Err(_),
  )
}

///|
test "tile audit rejects oversized public dimensions before wrapped multiplication" {
  let a = test_chip(300000, 3500000, [10000], [0])
  let invalid = {
    ..compare(a, a, 0.15),
    width: 65536,
    height: 65536,
    classes: [],
  }
  assert_true(
    (Ok(tile_counts(invalid, rows=65536, columns=65536)) catch { e => Err(e) })
    is Err(Invalid(_)),
  )
}

///|
test "pixel evidence rejects mixed sources truncated grids and altered classifications" {
  let a = test_chip(300000, 3500000, [10000], [0])
  let result = compare(a, a, 0.15)
  assert_true(
    (Ok(inspect_pixel({ ..a, cell: 0, }, a, result, 1, 1)) catch {
      e => Err(e)
    })
    is Err(Invalid(_)),
  )
  assert_true(
    (Ok(inspect_pixel({ ..a, scene: "unrelated", }, a, result, 1, 1)) catch {
      e => Err(e)
    })
    is Err(Invalid(_)),
  )
  assert_true(
    (Ok(inspect_pixel({ ..a, qa: [8], }, a, result, 1, 1)) catch {
      e => Err(e)
    })
    is Err(Invalid(_)),
  )
  for
    bad in [
      { ..result, before_reason: [], },
      { ..result, delta: [], },
      { ..result, classes: [1], },
      { ..result, x: result.x + 1, },
      { ..result, threshold: 0.0, },
    ] {
    assert_true(
      (Ok(inspect_pixel(a, a, bad, 1, 1)) catch { e => Err(e) })
      is Err(Invalid(_)),
    )
  }
  let changed = test_chip(300000, 3500000, [18000], [0])
  for (before, after, code) in [(a, changed, -1), (changed, a, 1)] {
    let valid = compare(before, after, 0.15)
    assert_eq(inspect_pixel(before, after, valid, 1, 1).class_code, code)
  }
}

///|
test "tile counts cannot silently contradict the whole-window totals" {
  let a = test_chip(300000, 3500000, [10000], [0])
  let result = compare(a, a, 0.15)
  for
    invalid in [
      { ..result, gain: 1, },
      { ..result, loss: 1, },
      { ..result, stable: 0, },
      { ..result, valid: 0, },
      { ..result, excluded: 1, },
      { ..result, overlap: 2, },
    ] {
    assert_true(
      (Ok(tile_counts(invalid, rows=1, columns=1)) catch { e => Err(e) })
      is Err(Invalid(_)),
    )
  }
  assert_eq(tile_counts(result, rows=1, columns=1)[0].counts.stable, 1)
  assert_eq(result.classes, [0])
}

///|
test "pixel evidence requires the complete common window" {
  let full = test_chip(300000, 3500000, [10000, 11000], [0, 0])
  let single = test_chip(300000, 3500000, [10000], [0])
  let cropped = compare(single, single, 0.15)
  let result = Ok(inspect_pixel(full, full, cropped, 1, 1)) catch {
    e => Err(e)
  }
  assert_true(result is Err(Invalid(_)))
}

///|
test "pixel evidence verifies both NDVI readings and water state" {
  let chip = test_chip(300000, 3500000, [10000], [128])
  let full = compare(chip, chip, 0.15)
  for
    changed in [
      { ..full, ndvi_before: [None], },
      { ..full, ndvi_after: [Some(0.0)], },
      { ..full, water_code: [0], },
    ] {
    let result = Ok(inspect_pixel(chip, chip, changed, 1, 1)) catch {
      e => Err(e)
    }
    assert_true(result is Err(Invalid(_)))
  }
}

///|
test "QA impact reports when screening removes every usable pixel" {
  let a = test_chip(300000, 3500000, [14000, 14000], [0, 0])
  let b = { ..a, red: [10000, 14000], qa: [8, 8], }
  let impact = qa_impact(a, b, 0.15)
  assert_eq([impact.screened.valid, impact.unscreened.valid], [0, 2])
  assert_eq(
    [impact.changed_before, impact.changed_after, impact.qa_added_exclusions],
    [1, 0, 2],
  )
  assert_true(
    (Ok(qa_impact(a, b, 0.15, min_coverage=0.01)) catch { e => Err(e) })
    is Err(Invalid(_)),
  )
  assert_true(
    (Ok(compare(a, b, 0.15)) catch { e => Err(e) }) is Err(Invalid(_)),
  )
  let bad = { ..b, red: [0, 0], }
  assert_true(
    (Ok(qa_impact(a, bad, 0.15)) catch { e => Err(e) }) is Err(Invalid(_)),
  )
}

///|
test "source inspection matches full grids with offsets and QA masking" {
  let a = test_chip(300000, 3500000, [14000, 14000, 14000], [0, 0, 0])
  let b = test_chip(300030, 3500000, [10000, 13000, 16000], [8, 0, 0])
  for screen_qa in [true, false] {
    let full = compare(a, b, 0.15, screen_qa~)
    for col in [1, 2] {
      let expected = inspect_pixel(a, b, full, 1, col)
      let evidence = inspect_sources(a, b, 0.15, 1, col, screen_qa~)
      assert_eq(Json(evidence).stringify(), Json(expected).stringify())
    }
  }
  let bad = Ok(inspect_sources(a, b, 0.15, 1, 3)) catch { e => Err(e) }
  assert_true(bad is Err(Invalid(_)))
  let uncovered = Ok(inspect_sources(a, b, 0.15, 1, 2, min_coverage=0.6)) catch {
    e => Err(e)
  }
  assert_true(uncovered is Err(Invalid(_)))
}

///|
test "change regions separate diagonal and opposite trends" {
  let chip = test_chip(300000, 3500000, [14000], [0])
  let base = compare(chip, chip, 0.15)
  let grid = {
    ..base,
    width: 3,
    height: 3,
    overlap: 9,
    valid: 8,
    gain: 3,
    loss: 3,
    stable: 2,
    excluded: 1,
    classes: [1, 0, -1, 0, 1, -1, -1, -2, 1],
  }
  let four = change_regions(grid)
  assert_eq(
    [four.gain.regions, four.gain.largest_pixels, four.gain.isolated_pixels],
    [3, 1, 3],
  )
  assert_eq([four.loss.regions, four.loss.largest_pixels], [2, 2])
  let eight = change_regions(grid, connectivity=8)
  assert_eq(
    [eight.gain.regions, eight.gain.pixels, eight.gain.largest_pixels],
    [1, 3, 3],
  )
  assert_eq(eight.gain.largest_area_m2, 2700L)
  assert_eq(eight.loss.regions, 2)
  let filtered = change_regions(grid, min_pixels=2)
  assert_eq(filtered.min_pixels, 2)
  assert_eq([filtered.gain.regions, filtered.gain.pixels], [0, 0])
  assert_eq([filtered.gain.discarded_regions, filtered.gain.discarded_pixels], [
    3, 3,
  ])
  assert_eq(
    [filtered.loss.regions, filtered.loss.pixels, filtered.loss.largest_pixels],
    [1, 2, 2],
  )
  assert_eq([filtered.loss.discarded_regions, filtered.loss.discarded_pixels], [
    1, 1,
  ])
  assert_true(
    (Ok(change_regions(grid, min_pixels=0)) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(change_regions(grid, connectivity=6)) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(change_regions({ ..grid, gain: 2, })) catch { e => Err(e) }) is Err(_),
  )
}

///|
test "land-only regions cannot use water pixels to connect land changes" {
  let a = test_chip(300000, 3500000, [14000, 14000, 14000], [0, 0, 0])
  let b = { ..a, red: [10000, 10000, 10000], qa: [0, 128, 0], }
  let grid = compare(a, b, 0.15)
  assert_eq(change_regions(grid).gain.regions, 1)
  let land = change_regions(grid, land_only=true)
  assert_true(land.land_only)
  assert_eq([land.gain.pixels, land.gain.regions, land.gain.largest_pixels], [
    2, 2, 1,
  ])
  assert_eq(land.gain.water_excluded_pixels, 1)
  let minimum = change_regions(grid, land_only=true, min_pixels=2)
  assert_eq(
    [
      minimum.gain.pixels,
      minimum.gain.discarded_pixels,
      minimum.gain.water_excluded_pixels,
    ],
    [0, 2, 1],
  )
  let corrupt = { ..grid, water_code: [0, 4, 0], }
  assert_true(
    (Ok(change_regions(corrupt, land_only=true)) catch { e => Err(e) })
    is Err(_),
  )
}

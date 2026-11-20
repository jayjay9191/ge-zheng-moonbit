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

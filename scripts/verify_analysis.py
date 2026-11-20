"""Check the real built CLI against both measured Landsat windows."""
from bisect import bisect_right
from collections import Counter
from fractions import Fraction
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

from replay import locations, reference as reference_pixel, verify
from source_manifest import load_pair

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "_build/js/release/build/cmd/main/main.js"


def run(folder, *flags, success=True, threshold="0.15"):
    return run_pair((f"{folder}/scene-1.json", f"{folder}/scene-2.json"),
                    *flags, success=success, threshold=threshold)


def run_pair(paths, *flags, success=True, threshold="0.15"):
    result = subprocess.run(
        ["node", str(PROGRAM), *paths, threshold, *flags],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    assert result.returncode == (0 if success else 2), (result.stdout + result.stderr)[:600]
    return json.loads(result.stdout) if success else result.stdout


def region_reference(classes, width, code, connectivity, minimum):
    remaining = {divmod(i, width) for i, value in enumerate(classes) if value == code}
    pixels = len(remaining)
    sizes = []
    offsets = [(r, c) for r in (-1, 0, 1) for c in (-1, 0, 1)
               if (r or c) and (connectivity == 8 or abs(r) + abs(c) == 1)]
    while remaining:
        queue = [remaining.pop()]
        for row, col in queue:
            for dr, dc in offsets:
                other = (row + dr, col + dc)
                if other in remaining:
                    remaining.remove(other)
                    queue.append(other)
        sizes.append(len(queue))
    retained = [n for n in sizes if n >= minimum]
    largest = max(retained, default=0)
    return dict(regions=len(retained), pixels=sum(retained), isolated_pixels=retained.count(1),
                largest_pixels=largest, largest_area_m2=largest * 900,
                discarded_regions=len(sizes)-len(retained), discarded_pixels=pixels-sum(retained))


def verify_shifted():
    # An asymmetric integer offset, with distinct QA and water observations.
    before = dict(scene="synthetic-A", date="2024-01-01", epsg=32650, x=300000, y=3500000,
                  width=4, height=3, cell=30, red=list(range(14000, 15200, 100)),
                  nir=[18000] * 12, qa=[0, 0, 0, 0, 0, 128, 128, 0, 0, 0, 0, 0],
                  saturation=[0] * 12)
    after = dict(before, scene="synthetic-B", date="2024-01-17", x=300030, y=3499970,
                 width=3, red=list(range(10000, 12700, 300)), nir=[18000] * 9,
                 qa=[8, 128, 128, 0, 16, 0, 0, 0, 0], saturation=[0] * 9)
    thresholds = (0.25, 0.1, 0.25, 0.4)
    encoded = ",".join(map(str, thresholds))
    with TemporaryDirectory(prefix="shifted-replay-", dir=ROOT / "_build") as folder:
        paths = [str(Path(folder) / f"{i}.json") for i in (1, 2)]
        for path, chip in zip(paths, (before, after)):
            Path(path).write_text(json.dumps(chip), encoding="utf-8")
        for pair, chips in ((paths, (before, after)), (paths[::-1], (after, before))):
            for flags in ((), ("--direct",)):
                sweep = run_pair(pair, *flags, "--sweep", encoded)
                assert [row["threshold"] for row in sweep["rows"]] == list(thresholds)
                for row in sweep["rows"]:
                    cutoff = row["threshold"]
                    result = run_pair(pair, *flags, threshold=str(cutoff))
                    verify(result, *chips, cutoff, screen_qa=not flags)
                    assert result["overlap"] == 6
                    assert row["counts"] == {key: result[key] for key in row["counts"]}
        full = run_pair(paths)
        edge = max(abs(d) for d in full["delta"] if d is not None)
        boundaries = (edge, edge / 2, edge, 2.0)
        for pair in (paths, paths[::-1]):
            sweep = run_pair(pair, "--sweep", ",".join(map(str, boundaries)))
            assert [entry["threshold"] for entry in sweep["rows"]] == list(boundaries)
            evidence = run_pair(pair)
            deltas = [d for d in evidence["delta"] if d is not None]
            for row in sweep["rows"]:
                cutoff = row["threshold"]
                assert row["counts"]["gain"] == sum(d >= cutoff for d in deltas)
                assert row["counts"]["loss"] == sum(d <= -cutoff for d in deltas)
        for flags in ((), ("--direct",)):
            full = run_pair(paths, *flags)
            for row, column in ((1, 1), (1, 2), (2, 3)):
                index = (row - 1) * full["width"] + column - 1
                evidence = run_pair(paths, *flags, "--inspect", str(row), str(column))
                assert evidence["x_center"] == full["x"] + column * 30 - 15
                assert evidence["y_center"] == full["y"] - row * 30 + 15
                assert evidence["class_code"] == full["classes"][index]
                assert evidence["delta"] == full["delta"][index]
                assert evidence["reason_before"] == full["before_reason"][index]
                assert evidence["reason_after"] == full["after_reason"][index]
        run_pair(paths, "--inspect", "1", "1", "--min-coverage", "0.9", success=False)
        print("PASS single-pixel source lookup matches full grids with and without QA")
        masked = dict(after, qa=[8] * len(after["qa"]))
        Path(paths[1]).write_text(json.dumps(masked), encoding="utf-8")
        impact = run_pair(paths, "--qa-impact", threshold="0.1")
        raw = run_pair(paths, "--direct", threshold="0.1")
        verify(raw, before, masked, 0.1, screen_qa=False)
        assert impact["screened"] == dict(gain=0, loss=0, stable=0, valid=0, excluded=6)
        assert impact["unscreened"] == {key: raw[key] for key in impact["unscreened"]}
        assert impact["qa_added_exclusions"] == raw["valid"]
        assert "没有共同有效像元" in impact["conclusion"]
        run_pair(paths, "--qa-impact", "--min-coverage", "0.01", success=False, threshold="0.1")
        run_pair(paths, "--summary", success=False, threshold="0.1")
        print("PASS QA impact reports fully masked windows; coverage floor and change classification still reject")
    print("PASS shifted 3x2 window, exact threshold equality, reverse direction and repeated cutoffs")


def main():
    sources = [path for path in ROOT.glob("*.mbt")
               if not path.name.endswith(("_test.mbt", "_wbtest.mbt", "_data.mbt"))
               and "generated" not in path.name]
    source_lines = {path.name: [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
                                if line.strip() and not line.lstrip().startswith("//")]
                    for path in sorted(sources)}
    counts = {name: sum(any(ch.isalnum() for ch in line) for line in lines)
              for name, lines in source_lines.items()}
    assert sum(counts.values()) >= 500, counts
    nonblank = sum(map(len, source_lines.values()))
    print(f"PASS library source gate: {nonblank} nonblank/noncomment lines; excludes CLI, tests and data")
    print(f"PASS stricter source gate: {sum(counts.values())} lines after also dropping punctuation-only lines; {counts}")
    subprocess.run(["moon", "build", "--release", "--target", "js"], cwd=ROOT, check=True)
    expected = {
        "data": ([11446, 10703, 10013], [285, 94, 52], 14224, 2160, 11239, 10797),
        "data/feidong": ([155, 86, 49], [1495, 577, 290], 11257, 5127, 3031, 663),
    }
    for args in (("--direct", "--direct"), ("--regions", "4", "--regions", "8"),
                 ("--min-coverage", "0.01", "--min-coverage", "0.02")):
        assert "duplicate argument:" in run("data/feidong", *args, success=False)
    compared = 0
    max_error = 0.0
    for folder, (gains, losses, valid, excluded, changed_before, changed_after) in expected.items():
        sweep = run(folder, "--sweep")
        paths, (before, after) = load_pair(ROOT, ROOT / folder / "sources.json")
        cuts = [Fraction("0.2"), Fraction("0.5")]
        first, second = locations(before), locations(after)
        for flags in ((), ("--direct",)):
            expected_transitions = [[0] * 3 for _ in range(3)]
            expected_land = [[0] * 3 for _ in range(3)]
            common = first.keys() & second.keys()
            for point in common:
                a, b = (reference_pixel(chip, index, screen_qa=not flags)
                        for chip, index in ((before, first[point]), (after, second[point])))
                if a is not None and b is not None:
                    row, column = bisect_right(cuts, a), bisect_right(cuts, b)
                    expected_transitions[row][column] += 1
                    if not (before["qa"][first[point]] & 128 or after["qa"][second[point]] & 128):
                        expected_land[row][column] += 1
            transitions = run_pair(paths, "0.2,0.5", *flags, threshold="--transitions")
            assert transitions["cut_points"] == [0.2, 0.5]
            assert transitions["qa_screened"] is (not flags)
            assert transitions["land_only"] is False
            assert transitions["sources"] == {
                "first_scene": before["scene"], "second_scene": after["scene"],
                "first_date": before["date"], "second_date": after["date"],
                "epsg": before["epsg"],
            }
            assert abs(transitions["valid_fraction"] - transitions["valid"] / len(common)) < 1e-15
            assert transitions["counts"] == expected_transitions
            summary = transitions["summary"]
            before_totals = [sum(row) for row in expected_transitions]
            after_totals = [sum(column) for column in zip(*expected_transitions)]
            quantity = sum(abs(a - b) for a, b in zip(before_totals, after_totals)) // 2
            off_diagonal = sum(expected_transitions[i][j] for i in range(3) for j in range(3) if i != j)
            assert summary == {
                "before_counts": before_totals,
                "after_counts": after_totals,
                "quantity_disagreement": quantity,
                "allocation_disagreement": off_diagonal - quantity,
                "lower": sum(expected_transitions[i][j] for i in range(3) for j in range(i)),
                "same": sum(expected_transitions[i][i] for i in range(3)),
                "higher": sum(expected_transitions[i][j] for i in range(3) for j in range(i + 1, 3)),
            }
            assert transitions["valid"] == sum(map(sum, expected_transitions))
            assert transitions["valid"] + transitions["excluded"] == len(common)
            land = run_pair(paths, "0.2,0.5", "--land-only", *flags, threshold="--transitions")
            assert land["counts"] == expected_land
            land_summary = land["summary"]
            land_quantity = sum(abs(sum(row) - sum(column))
                                for row, column in zip(expected_land, zip(*expected_land))) // 2
            assert land_summary["quantity_disagreement"] == land_quantity
            assert land_summary["allocation_disagreement"] == land["valid"] - land_summary["same"] - land_quantity
            assert land["land_only"] is True and land["qa_screened"] is (not flags)
            assert abs(land["valid_fraction"] - land["valid"] / len(common)) < 1e-15
            assert land["valid"] == sum(map(sum, expected_land))
            assert transitions["water_excluded"] == 0
            assert land["water_excluded"] == transitions["valid"] - land["valid"]
            assert land["excluded"] == transitions["excluded"] + land["water_excluded"]
            if not flags:
                print(f"PASS {folder} NDVI transitions: {expected_transitions}; summary: {summary}")
                print(f"PASS {folder} land transition matrix: {expected_land}; separately excluded water: {land['water_excluded']}")
        assert len(sweep["rows"]) == 3
        for i, cutoff in enumerate((0.1, 0.15, 0.2)):
            row = sweep["rows"][i]
            assert row["threshold"] == cutoff
            screened = run(folder, threshold=str(cutoff))
            direct = run(folder, "--direct", threshold=str(cutoff))
            max_error = max(max_error, verify(screened, before, after, cutoff),
                            verify(direct, before, after, cutoff, screen_qa=False))
            compared += 2 * screened["overlap"]
            assert row["counts"] == {key: screened[key] for key in row["counts"]}
            if cutoff == 0.15:
                classes = screened["classes"]
                water_codes = screened["water_code"]
            assert row["counts"] == dict(gain=gains[i], loss=losses[i], valid=valid,
                                          excluded=excluded, stable=valid-gains[i]-losses[i])
        assert run(folder, "--sweep", "0.2,0.1")["rows"][0]["threshold"] == 0.2
        impact = run(folder, "--qa-impact")
        assert (impact["changed_before"], impact["changed_after"]) == (changed_before, changed_after)
        whole = run(folder, "--summary")
        for shape in ("2x2", "1x1", "3x5"):
            tiles = run(folder, "--tiles", shape)
            rows, columns = map(int, shape.split("x"))
            width, height = before["width"], before["height"]
            assert len(tiles) == rows * columns
            for index, tile in enumerate(tiles):
                row, column = divmod(index, columns)
                top, bottom = row * height // rows, (row + 1) * height // rows
                left, right = column * width // columns, (column + 1) * width // columns
                assert [tile[key] for key in ("row", "column", "row_start", "column_start",
                                             "height", "width")] == [
                    row + 1, column + 1, top, left, bottom - top, right - left]
                labels = Counter(classes[y * width + x]
                                 for y in range(top, bottom) for x in range(left, right))
                assert tile["counts"] == dict(gain=labels[1], loss=labels[-1], stable=labels[0],
                                              excluded=labels[-2], valid=sum(labels.values()) - labels[-2])
            for field in ("gain", "loss", "stable", "valid", "excluded"):
                assert sum(tile["counts"][field] for tile in tiles) == whole[field]
        land_classes = [code if water == 0 else -2 for code, water in zip(classes, water_codes)]
        for connectivity in (4, 8):
            for minimum in (1, 4):
                minimum_flags = ("--min-region-pixels", str(minimum)) if minimum != 1 else ()
                for land in (False, True):
                    flags = minimum_flags + (("--land-only",) if land else ())
                    regions = run(folder, "--regions", str(connectivity), *flags)
                    assert regions["connectivity"] == connectivity and regions["min_pixels"] == minimum
                    assert regions["land_only"] is land
                    cells = land_classes if land else classes
                    for trend, code in (("gain", 1), ("loss", -1)):
                        actual = regions[trend]
                        actual["largest_area_m2"] = int(actual["largest_area_m2"])
                        reference = region_reference(cells, before["width"], code, connectivity, minimum)
                        reference["water_excluded_pixels"] = classes.count(code) - cells.count(code)
                        assert actual == reference
                    if connectivity == 4 and minimum == 1 and land:
                        print(f"PASS {folder} land-only: {regions['gain']['pixels']}/{regions['loss']['pixels']} "
                              f"gain/loss pixels, {regions['gain']['water_excluded_pixels']}/"
                              f"{regions['loss']['water_excluded_pixels']} water exclusions")
        print(f"PASS {folder}: sweep, QA impact {changed_before} -> {changed_after}, 3 tile shapes")
    print(f"PASS independent Fraction replay: {compared:,} pixel comparisons; max delta error {max_error:.3g}")
    verify_shifted()
    for flags in (("--sweep", "0"), ("--sweep", ""), ("--sweep", "2.01"),
                  ("--tiles", "0x2"), ("--tiles", "2"), ("--tiles",),
                  ("--tiles", "129x2"), ("--sweep", "--qa-impact"),
                  ("--qa-impact", "--direct"), ("--sweep", "--summary"),
                  ("--regions", "6"), ("--regions", "--tiles", "2x2"),
                  ("--min-region-pixels", "4"), ("--regions", "--min-region-pixels", "0"),
                  ("--regions", "--min-region-pixels"), ("--land-only",)):
        run("data", *flags, success=False)
    for threshold in ("0", "-0.1", "2.01"):
        run("data", "--sweep", threshold=threshold, success=False)
    print("PASS invalid thresholds, dimensions and conflicting CLI modes")


if __name__ == "__main__":
    main()

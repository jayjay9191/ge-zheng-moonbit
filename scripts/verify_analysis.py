"""Check the real built CLI against both measured Landsat windows."""
from bisect import bisect_left, bisect_right
from collections import Counter
from fractions import Fraction
from itertools import accumulate, product
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


def reference_neutralization(pairs, cut, margin):
    nominal = sum(int(b >= cut) - int(a >= cut) for a, b in pairs)
    if not nominal:
        return dict(single_step_pairs=0, double_step_pairs=0, minimum_changed_pairs=0)
    direction = 1 if nominal < 0 else -1
    capacities = []
    for a, b in pairs:
        start = int(b >= cut) - int(a >= cut)
        capacities.append(max(direction * (int(right >= cut) - int(left >= cut) - start)
                              for left, right in product((a - margin, a + margin), (b - margin, b + margin))))
    # Check the first prefix whose total capacity covers the deficit.
    minimum = next((count for count, reach in enumerate(accumulate(sorted(capacities, reverse=True)), 1)
                    if reach >= abs(nominal)), None)
    return dict(single_step_pairs=capacities.count(1), double_step_pairs=capacities.count(2),
                minimum_changed_pairs=minimum)


def reference_critical_margin(pairs, threshold):
    # Independent oracle: test reachable net at candidate radii using sorted marginals.
    before = sorted(a for a, _ in pairs)
    after = sorted(b for _, b in pairs)
    observed = bisect_left(before, threshold) - bisect_left(after, threshold)
    if observed == 0:
        return observed, Fraction(0), True
    radii = sorted({abs(value - threshold) for date in (before, after) for value in date})

    def can_reach_zero(radius, immediately_above):
        upper = threshold + radius
        lower = threshold - radius
        guaranteed = bisect_right if immediately_above else bisect_left
        if observed < 0:
            return guaranteed(before, upper) >= bisect_left(after, lower)
        return bisect_left(before, lower) <= guaranteed(after, upper)

    lo, hi = 0, len(radii) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if can_reach_zero(radii[mid], True):
            hi = mid
        else:
            lo = mid + 1
    radius = radii[lo]
    return observed, radius, can_reach_zero(radius, False)


def reference_budget_boundary(pairs, threshold, budget):
    observed = sum(int(b >= threshold) - int(a >= threshold) for a, b in pairs)
    if observed == 0:
        return Fraction(0), True
    if 2 * budget < abs(observed):
        return None
    radii = sorted({abs(value - threshold) for pair in pairs for value in pair})

    def reachable(radius, immediately_above):
        low, high = threshold - radius, threshold + radius

        def still_upper(value):
            return value > high if immediately_above else value >= high

        if observed < 0:
            gains = (int(b >= low) - int(still_upper(a)) - int(b >= threshold) + int(a >= threshold)
                     for a, b in pairs)
        else:
            gains = (int(b >= threshold) - int(a >= threshold) - int(still_upper(b)) + int(a >= low)
                     for a, b in pairs)
        return sum(sorted(gains, reverse=True)[:budget]) >= abs(observed)

    lo, hi = 0, len(radii)
    while lo < hi:
        mid = (lo + hi) // 2
        if reachable(radii[mid], True):
            hi = mid
        else:
            lo = mid + 1
    return None if lo == len(radii) else (radii[lo], reachable(radii[lo], False))


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
    assert "requires --transitions" in run("data/feidong", "--margin", "0.01", success=False)
    assert "requires --transitions" in run("data/feidong", "0.2,0.5", "--margin", "0.01",
                                          threshold="--transitions", success=False)
    assert "choose only one" in run("data/feidong", "0.5", "--margins", "0,0.01", "--margin", "0.01",
                                    threshold="--transitions", success=False)
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
            cut_counts = [[0, 0] for _ in cuts]
            bound_cut, margin = Fraction("0.5"), Fraction("0.01")
            bounds = [[0] * 3 for _ in range(2)]
            land_bounds = [[0] * 3 for _ in range(2)]
            signed = [0, 0, 0]
            land_signed = [0, 0, 0]
            paired = []
            land_pairs = []
            land_cut_counts = [[0, 0] for _ in cuts]
            common = first.keys() & second.keys()
            for point in common:
                a, b = (reference_pixel(chip, index, screen_qa=not flags)
                        for chip, index in ((before, first[point]), (after, second[point])))
                if a is not None and b is not None:
                    row, column = bisect_right(cuts, a), bisect_right(cuts, b)
                    expected_transitions[row][column] += 1
                    is_land = not (before["qa"][first[point]] & 128 or after["qa"][second[point]] & 128)
                    paired.append((a, b))
                    if is_land:
                        expected_land[row][column] += 1
                        land_pairs.append((a, b))
                    for i, cut in enumerate(cuts):
                        up, down = a < cut <= b, b < cut <= a
                        cut_counts[i][0] += up
                        cut_counts[i][1] += down
                        if is_land:
                            land_cut_counts[i][0] += up
                            land_cut_counts[i][1] += down
                    # Direct interval extrema from per-pixel rational NDVI, without banding.
                    for direction, (start, finish) in enumerate(((a, b), (b, a))):
                        checks = (start + margin < bound_cut <= finish - margin,
                                  start < bound_cut <= finish,
                                  start - margin < bound_cut <= finish + margin)
                        for i, crossed in enumerate(checks):
                            bounds[direction][i] += crossed
                            if is_land:
                                land_bounds[direction][i] += crossed
                    endpoints = [int(right >= bound_cut) - int(left >= bound_cut)
                                 for left in (a - margin, a + margin)
                                 for right in (b - margin, b + margin)]
                    net = (min(endpoints), int(b >= bound_cut) - int(a >= bound_cut), max(endpoints))
                    for i, count in enumerate(net):
                        signed[i] += count
                        if is_land:
                            land_signed[i] += count
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
                "bands": [
                    dict(retained=expected_transitions[i][i],
                         gained=after_totals[i] - expected_transitions[i][i],
                         lost=before_totals[i] - expected_transitions[i][i],
                         net=after_totals[i] - before_totals[i],
                         exchange=min(before_totals[i], after_totals[i]) - expected_transitions[i][i])
                    for i in range(3)],
                "cut_crossings": [
                    dict(threshold=float(cut), up=up, down=down, net=up - down)
                    for cut, (up, down) in zip(cuts, cut_counts)
                ],
                "lower": sum(expected_transitions[i][j] for i in range(3) for j in range(i)),
                "same": sum(expected_transitions[i][i] for i in range(3)),
                "higher": sum(expected_transitions[i][j] for i in range(3) for j in range(i + 1, 3)),
            }
            assert transitions["valid"] == sum(map(sum, expected_transitions))
            assert transitions["valid"] + transitions["excluded"] == len(common)
            land = run_pair(paths, "0.2,0.5", "--land-only", *flags, threshold="--transitions")
            assert land["counts"] == expected_land
            land_summary = land["summary"]
            assert land_summary["cut_crossings"] == [
                dict(threshold=float(cut), up=up, down=down, net=up - down)
                for cut, (up, down) in zip(cuts, land_cut_counts)
            ]
            land_quantity = sum(abs(sum(row) - sum(column))
                                for row, column in zip(expected_land, zip(*expected_land))) // 2
            assert land_summary["quantity_disagreement"] == land_quantity
            assert land_summary["allocation_disagreement"] == land["valid"] - land_summary["same"] - land_quantity
            for i, band in enumerate(land_summary["bands"]):
                assert band["retained"] == expected_land[i][i]
                assert band["gained"] == sum(expected_land[j][i] for j in range(3) if j != i)
                assert band["lost"] == sum(expected_land[i][j] for j in range(3) if j != i)
            assert sum(band["exchange"] for band in land_summary["bands"]) == land_summary["allocation_disagreement"]
            assert land["land_only"] is True and land["qa_screened"] is (not flags)
            assert abs(land["valid_fraction"] - land["valid"] / len(common)) < 1e-15
            assert land["valid"] == sum(map(sum, expected_land))
            assert transitions["water_excluded"] == 0
            assert land["water_excluded"] == transitions["valid"] - land["valid"]
            assert land["excluded"] == transitions["excluded"] + land["water_excluded"]
            for extra, expected, net, valid_total in (
                ((), bounds, signed, transitions["valid"]),
                (("--land-only",), land_bounds, land_signed, land["valid"]),
            ):
                measured = run_pair(paths, "0.5", "--margin", "0.01", *flags, *extra,
                                    threshold="--transitions")
                assert measured["valid"] == valid_total
                assert measured["land_only"] == bool(extra)
                for name, counts in zip(("up", "down"), expected):
                    assert measured[name] == dict(zip(("guaranteed", "observed", "possible"), counts))
                assert measured["net"] == dict(zip(("minimum", "observed", "maximum"), net))
                if not flags and not extra:
                    reverse_bounds = run_pair(paths[::-1], "0.5", "--margin", "0.01",
                                              threshold="--transitions")
                    assert (reverse_bounds["up"], reverse_bounds["down"]) == (measured["down"], measured["up"])
                    assert reverse_bounds["net"] == dict(zip(("minimum", "observed", "maximum"),
                                                             (-value for value in reversed(net))))
                    print(f"PASS {folder} threshold 0.5 +/- 0.01: up {bounds[0]}, down {bounds[1]}, net {net}")
            for extra, pairs in (((), paired), (("--land-only",), land_pairs)):
                for tolerance in ("0.01", "0.02"):
                    neutral = run_pair(paths, "0.5", "--margin", tolerance, *flags, *extra,
                                       threshold="--transitions")["neutralization"]
                    oracle = reference_neutralization(pairs, bound_cut, Fraction(tolerance))
                    assert neutral.get("minimum_changed_pairs") == oracle["minimum_changed_pairs"]
                    for key in ("single_step_pairs", "double_step_pairs"):
                        assert neutral[key] == oracle[key]
                    minimum = oracle["minimum_changed_pairs"]
                    if minimum is not None and minimum > 1024:
                        failure = run_pair(paths, "0.5", "--margin", tolerance, "--witness", *flags, *extra,
                                           threshold="--transitions", success=False)
                        assert "witness exceeds output limit" in failure
                        continue
                    witness = run_pair(paths, "0.5", "--margin", tolerance, "--witness", *flags, *extra,
                                       threshold="--transitions")["witness"]
                    if minimum is None:
                        assert witness is None
                    else:
                        assert len(witness) == minimum
                        seen = set()
                        replay_net = sum(int(b >= bound_cut) - int(a >= bound_cut) for a, b in pairs)
                        radius = Fraction(tolerance)
                        # Re-map each cell to both source arrays and replay the listed flips.
                        for change in witness:
                            key = (before["x"] + change["column"] * before["cell"],
                                   before["y"] - change["row"] * before["cell"])
                            assert key not in seen
                            seen.add(key)
                            ia, ib = first[key], second[key]
                            a = reference_pixel(before, ia, screen_qa=not flags)
                            b = reference_pixel(after, ib, screen_qa=not flags)
                            assert a is not None and b is not None
                            if extra:
                                assert (before["qa"][ia] | after["qa"][ib]) & 128 == 0
                            action = change["flip"]
                            assert action in ("BeforeDate", "AfterDate", "BothDates")
                            for value, sign, selected in (
                                (a, -1, action != "AfterDate"), (b, 1, action != "BeforeDate"),
                            ):
                                if selected:
                                    low, high = value - radius, value + radius
                                    assert low < bound_cut <= high
                                    replay_net += sign * (1 - 2 * int(value >= bound_cut))
                        assert replay_net == 0
                        if not flags and not extra and witness:
                            with TemporaryDirectory(prefix="witness-audit-") as folder_path:
                                proof = Path(folder_path) / "witness.json"
                                proof.write_text(json.dumps(witness), encoding="utf-8")
                                check = ("--margin", tolerance, "--verify-witness", str(proof))
                                verified = run_pair(paths, "0.5", *check, threshold="--transitions")
                                assert verified["valid"] is True
                                observed = sum(int(b >= bound_cut) - int(a >= bound_cut) for a, b in pairs)
                                assert verified["audit"] == dict(observed_net=observed, final_net=0, changed_pairs=minimum)
                                proof.write_text(json.dumps(witness + witness[:1]), encoding="utf-8")
                                rejected = run_pair(paths, "0.5", *check, threshold="--transitions")
                                assert rejected["valid"] is False and "RepeatedCell" in json.dumps(rejected["failure"])
                                print(f"PASS {len(witness)} pairs verified at {tolerance}; repeated coordinate rejected")
                    if not flags and not extra:
                        print(f"PASS {folder} neutralization at {tolerance}: {oracle}; witness replayed")
                text_margins = "0,0.01,0.02,0.05"
                tested = run_pair(paths, "0.5", "--margins", text_margins, *flags, *extra,
                                  threshold="--transitions")
                assert tested["valid"] == len(pairs)
                analytical = run_pair(paths, "0.5", "--critical-margin", *flags, *extra,
                                      threshold="--transitions")
                nominal, radius, attained = reference_critical_margin(pairs, bound_cut)
                assert analytical["valid"] == len(pairs)
                assert analytical["observed_net"] == nominal
                assert abs(analytical["margin_infimum"] - float(radius)) < 1e-13
                assert analytical["zero_possible_at_infimum"] is attained
                if not flags and not extra:
                    print(f"PASS {folder} critical margin: {float(radius):.10f}, inclusive: {attained}")
                    if folder == "data/feidong":
                        budgets = (161, 162, 276, 323)
                        by_budget = {}
                        for cap in budgets:
                            report = run_pair(paths, "0.5", "--pair-budget", str(cap), threshold="--transitions")
                            assert (report["observed_net"], report["pair_budget"]) == (nominal, cap)
                            expected = reference_budget_boundary(pairs, bound_cut, cap)
                            actual = report.get("critical")
                            by_budget[cap] = actual
                            if expected is None:
                                assert actual is None
                            else:
                                assert abs(actual["margin"] - float(expected[0])) < 1e-12
                                assert actual["attained"] == expected[1]
                            print(f"PASS pair budget {cap}: {actual}")
                            if cap == 162:
                                below, above = (run_pair(paths, "0.5", "--margin", str(actual["margin"] + offset),
                                                         threshold="--transitions")["neutralization"]["minimum_changed_pairs"]
                                                for offset in (-1e-9, 1e-9))
                                assert (below is None or below > cap) and above == cap
                        order = (323, 161, 276, 162, 162, 0, 323)
                        batch = run_pair(paths, "0.5", "--pair-budgets", ",".join(map(str, order)),
                                         threshold="--transitions")["budgets"]
                        assert [row["pair_budget"] for row in batch] == list(order)
                        assert [row["observed_net"] for row in batch] == [nominal] * len(order)
                        assert [row.get("critical") for row in batch] == [by_budget.get(cap) for cap in order]
                        for bad in ("", "-1,2", "0,1.5", "1,,2"):
                            run_pair(paths, "0.5", "--pair-budgets", bad, threshold="--transitions", success=False)
                        run_pair(paths, "0.5", "--pair-budget", "162", "--pair-budgets", "162,276",
                                 threshold="--transitions", success=False)
                        print("PASS one sweep preserves seven unordered and repeated budget queries")
                        run_pair(paths, "0.5", "--pair-budget", "-1", threshold="--transitions", success=False)
                        run_pair(paths, "0.3,0.5", "--pair-budget", "162", threshold="--transitions", success=False)
                        run_pair(paths, "0.5", "--pair-budget", "162", "--margin", "0.02", threshold="--transitions", success=False)
                expected = []
                for value in text_margins.split(","):
                    tolerance = Fraction(value)
                    net = [
                        sum(int(b - tolerance >= bound_cut) - int(a + tolerance >= bound_cut) for a, b in pairs),
                        sum(int(b >= bound_cut) - int(a >= bound_cut) for a, b in pairs),
                        sum(int(b + tolerance >= bound_cut) - int(a - tolerance >= bound_cut) for a, b in pairs),
                    ]
                    expected.append(dict(margin=float(value), net=dict(zip(("minimum", "observed", "maximum"), net))))
                assert tested["rows"] == expected
                first_uncertain = next((row["margin"] for row in expected
                                        if row["net"]["minimum"] <= 0 <= row["net"]["maximum"]), None)
                assert tested.get("first_inconclusive_margin") == first_uncertain
                if not flags and not extra:
                    print(f"PASS {folder} margin sweep: {expected}, first inconclusive: {first_uncertain}")
            if not flags:
                reverse = run_pair(paths[::-1], "0.2,0.5", threshold="--transitions")
                assert reverse["summary"]["cut_crossings"] == [
                    dict(threshold=float(cut), up=down, down=up, net=down - up)
                    for cut, (up, down) in zip(cuts, cut_counts)
                ]
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

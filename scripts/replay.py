
"""Offline regression and independent integer-ratio reference for the bundled chips."""
import json
from fractions import Fraction
from pathlib import Path
import subprocess
import sys
from time import perf_counter

from source_manifest import load_pair

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
OUT = ROOT / "results"


def run(first, second, cutoff, direct=False):
    start = perf_counter()
    result = subprocess.run(["node", str(ROOT / "gezheng.js"), str(first), str(second),
                             str(cutoff), *(["--direct"] if direct else [])], check=False, capture_output=True, encoding="utf-8")
    return result, round((perf_counter() - start) * 1000, 1)


def reference(chip, i, screen_qa=True):
    qa = chip["qa"][i]
    r, n = chip["red"][i], chip["nir"][i]
    flags = f"{qa:016b}"[::-1]
    sat = f"{chip['saturation'][i]:016b}"[::-1]
    if r == 0 or n == 0 or (screen_qa and ("1" in flags[:6] or any(sat[b] == "1" for b in (3, 4, 11)))):
        return None
    a, b = 11 * r - 80000, 11 * n - 80000
    if min(a, b) < 0 or a + b == 0 or max(r, n) > 43636:
        return None
    return Fraction(b - a, a + b)


def locations(chip):
    return {
        (chip["x"] + col * chip["cell"], chip["y"] - row * chip["cell"]):
            row * chip["width"] + col
        for row in range(chip["height"]) for col in range(chip["width"])
    }


def verify(result, a, b, threshold, screen_qa=True):
    assert result["qa_screened"] == screen_qa
    first, second = locations(a), locations(b)
    points = [point for point in first if point in second]
    count = len(points)
    xs, ys = zip(*points)
    assert (result["x"], result["y"]) == (min(xs), max(ys))
    assert (result["width"], result["height"]) == (len(set(xs)), len(set(ys)))
    cut = Fraction(str(threshold))
    counts = {-2: 0, -1: 0, 0: 0, 1: 0}
    max_error = 0.0
    water_counts = [0, 0, 0, 0]
    land_change = {-1: 0, 0: 0, 1: 0}
    for i, point in enumerate(points):
        ia, ib = first[point], second[point]
        x, y = reference(a, ia, screen_qa), reference(b, ib, screen_qa)
        for field, value in (("ndvi_before", x), ("ndvi_after", y)):
            actual = result[field][i]
            if value is None:
                assert actual is None, (field, i)
            else:
                assert abs(float(value) - actual) < 1e-12, (field, i)
        if x is None or y is None:
            label = -2
            assert result["water_code"][i] == -1
            assert result["delta"][i] is None, i
        else:
            d = y - x
            label = int(d >= cut) - int(d <= -cut)
            a_is_water = bool(a["qa"][ia] & 128)
            b_is_water = bool(b["qa"][ib] & 128)
            code = int(a_is_water) + 2 * int(b_is_water)
            assert code == result["water_code"][i]
            water_counts[code] += 1
            if code == 0:
                land_change[label] += 1
            err = abs(float(d) - result["delta"][i])
            assert err < 1e-12, (i, err)
            max_error = max(max_error, err)
        assert result["classes"][i] == label, i
        counts[label] += 1
    assert [result[k] for k in ("excluded", "loss", "stable", "gain")] == [
        counts[k] for k in (-2, -1, 0, 1)]
    assert result["overlap"] == count
    assert result["valid"] == count - counts[-2]
    assert int(result["gain_m2"]) == counts[1] * 900
    assert int(result["loss_m2"]) == counts[-1] * 900
    keys = ("both_nonwater_valid", "before_only_water", "after_only_water", "both_water")
    assert [result[k] for k in keys] == water_counts
    assert result["both_nonwater_gain"] == land_change[1]
    assert result["both_nonwater_loss"] == land_change[-1]
    return max_error


def main():
    OUT.mkdir(exist_ok=True)
    (first, second), (a, b) = load_pair(ROOT, DATA / "sources.json")
    shifted = OUT / "half-pixel-input.json"
    shifted.write_text(json.dumps({**a, "x": a["x"] + 15}, separators=(",", ":")), encoding="utf-8")
    results = {}
    for name, after, after_payload in (("same", first, a), ("half", shifted, None), ("change", second, b)):
        run_result, duration = run(first, after, 0.15)
        if name == "half":
            assert run_result.returncode != 0 and "east 15 m" in run_result.stdout, run_result
            results[name] = {"status": "blocked", "message": run_result.stdout.strip(),
                             "exit_code": run_result.returncode, "run_ms": duration}
            continue
        assert run_result.returncode == 0, run_result
        output = json.loads(run_result.stdout)
        error = verify(output, a, after_payload, 0.15)
        if name == "same":
            assert output["gain"] == output["loss"] == output["max_abs_delta"] == 0
        (OUT / f"{name}.json").write_text(run_result.stdout, encoding="utf-8")
        results[name] = {k: v for k, v in output.items() if k not in ("classes", "delta", "ndvi_before", "ndvi_after", "water_code", "before_reason", "after_reason")}
        results[name].update(status="ok", reference_max_error=error, run_ms=duration)
    sensitivity = {}
    for cutoff in (0.10, 0.20):
        trial, _ = run(first, second, cutoff)
        assert trial.returncode == 0, trial
        payload = json.loads(trial.stdout)
        verify(payload, a, b, cutoff)
        sensitivity[str(cutoff)] = {k: payload[k] for k in ("gain", "loss", "stable", "both_nonwater_gain", "both_nonwater_loss")}
    results["sensitivity"] = sensitivity
    (OUT / "summary.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()


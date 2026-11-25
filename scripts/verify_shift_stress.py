"""Independent offset classifier for five- and nine-position stress tests."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
from source_manifest import load_pair

ROOT = Path(__file__).resolve().parents[1]
OFFSETS = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]


def ndvi(chip, index, screen):
    red, nir = (chip[band][index] for band in ("red", "nir"))
    if not (7273 <= red <= 43636 and 7273 <= nir <= 43636):
        return None
    if screen and (chip["qa"][index] & 63 or chip["saturation"][index] & 2072):
        return None
    return Fraction(11 * (nir - red), 11 * (nir + red) - 160000)


def reference(a, b, cut, screen, offsets):
    # Derive candidate indices independently from absolute easting and northing.
    dx = (b["x"] - a["x"]) // a["cell"]
    dy = (a["y"] - b["y"]) // a["cell"]
    xs = range(max(0, dx + 1), min(a["width"], dx + b["width"] - 1))
    ys = range(max(0, dy + 1), min(a["height"], dy + b["height"] - 1))
    scans = [[] for _ in offsets]
    codes = []
    for row in ys:
        for col in xs:
            previous = ndvi(a, row * a["width"] + col, screen)
            values = [ndvi(b, (row - dy + dr) * b["width"] + col - dx + dc, screen)
                      for dc, dr in offsets]
            if previous is None or None in values:
                codes.append(-2)
                continue
            verdicts = [int(value - previous >= cut) - int(value - previous <= -cut)
                        for value in values]
            for scan, verdict in zip(scans, verdicts, strict=True):
                scan.append(verdict)
            codes.append(verdicts[0] if len(set(verdicts)) == 1 else 2)
    return xs, ys, scans, codes


def run(*args, ok=True):
    result = subprocess.run(["moon", "run", "cmd/main", "--", *map(str, args)], cwd=ROOT,
                            capture_output=True, encoding="utf-8", timeout=60)
    assert result.returncode == (0 if ok else 2), result.stdout + result.stderr
    return json.loads(result.stdout) if ok else result.stdout


def verify_geotiff(actual, a, b, xs, ys, codes):
    import rasterio
    from export_geotiff import export

    with TemporaryDirectory() as temp:
        directory = Path(temp)
        source = directory / "alignment.json"
        source.write_text(json.dumps(actual), encoding="utf-8")
        path, = export(source, directory)
        with rasterio.open(path) as raster:
            assert raster.crs.to_epsg() == a["epsg"]
            assert raster.shape == (len(ys), len(xs))
            assert tuple(raster.transform)[:6] == (30, 0, a["x"] + 30 * xs.start,
                                                   0, -30, a["y"] - 30 * ys.start)
            assert raster.nodata == -32768
            assert raster.read_masks(1).ravel().tolist() == [0 if value == -2 else 255 for value in codes]
            assert raster.read(1).ravel().tolist() == [-32768 if value == -2 else value for value in codes]
            assert raster.tags()["before"] == a["scene"] and raster.tags()["after"] == b["scene"]


def verify_sweep(paths, a, b, screen, offsets, flags, expected_valid):
    cuts = [Fraction(1, 5), Fraction(1, 10), Fraction(3, 20), Fraction(3, 20), Fraction(2)]
    actual = run(*paths, "--shift-sweep", ",".join(str(float(cut)) for cut in cuts), *flags)
    assert (actual["offsets"], actual["valid"]) == (len(offsets), expected_valid)
    assert [row["threshold"] for row in actual["rows"]] == list(map(float, cuts))
    reference_counts = {}
    for cut, row in zip(cuts, actual["rows"], strict=True):
        if cut not in reference_counts:
            xs, ys, scans, _ = reference(a, b, cut, screen, offsets)
            assert (actual["x"], actual["y"], actual["width"], actual["height"]) == (
                a["x"] + 30 * xs.start, a["y"] - 30 * ys.start, len(xs), len(ys))
            count = len(scans[0])
            assert count == expected_valid
            votes = [set(values) for values in zip(*scans, strict=True)]
            reference_counts[cut] = (900 * sum(0 not in v for v in votes),
                                     900 * sum(v != {0} for v in votes),
                                     sum({-1, 1} <= v for v in votes))
        bounds = row["bounds"]
        assert (int(bounds["certain_change_m2"]), int(bounds["possible_change_m2"]),
                bounds["opposite_direction"]) == reference_counts[cut], (cut, row)
    print("  five threshold rows agree with independent Fraction classification")


def verify_cropped_pair(args):
    paths, (a, b) = load_pair(ROOT, ROOT / "data/nanjing/sources.json")
    # Keep physical locations of real pixels while offsetting the chip origin
    # in both dimensions. This exercises the rolling window's two offsets.
    width = 119
    height = 121
    c0, r0 = 3, 2
    clipped = dict(b, width=width, height=height, x=b["x"] + 30 * c0, y=b["y"] - 30 * r0)
    for band in ("red", "nir", "qa", "saturation"):
        src = b[band]
        clipped[band] = [src[row * b["width"] + col]
                         for row in range(r0, r0+height) for col in range(c0, c0+width)]
    offsets = OFFSETS + [(dc, dr) for dc in (1, -1) for dr in (1, -1)]
    xs, ys, scans, codes = reference(a, clipped, Fraction(3, 20), True, offsets)
    with TemporaryDirectory() as temp:
        path = Path(temp) / "cropped.json"
        path.write_text(json.dumps(clipped), encoding="utf-8")
        pair = (paths[0], path)
        flags = ["--include-diagonals"]
        actual = run(*pair, 0.15, "--shift-stress", *flags)
        assert actual["stability"] == codes
        if args.geotiff:
            verify_geotiff(actual, a, clipped, xs, ys, codes)
        verify_sweep(pair, a, clipped, True, offsets, flags, len(scans[0]))
    print("PASS cropped real pair with nonzero row and column offsets")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--geotiff", action="store_true", help="also verify the exported raster through GDAL")
    args = parser.parse_args()
    for folder in ("data", "data/feidong", "data/nanjing"):
        paths, (a, b) = load_pair(ROOT, ROOT / folder / "sources.json")
        for screen in (True, False):
            for diagonals in (False, True):
                offsets = OFFSETS + [(dc, dr) for dc in (1, -1) for dr in (1, -1)] if diagonals else OFFSETS
                xs, ys, scans, codes = reference(a, b, Fraction(3, 20), screen, offsets)
                flags = [] if screen else ["--direct"]
                if diagonals:
                    flags.append("--include-diagonals")
                actual = run(*paths, 0.15, "--shift-stress", *flags)
                assert actual["stability"] == codes
                if args.geotiff:
                    verify_geotiff(actual, a, b, xs, ys, codes)
                valid = len(scans[0])
                assert actual["valid"] == valid
                verify_sweep(paths, a, b, screen, offsets, flags, valid)
                assert actual["width"] == len(xs) and actual["height"] == len(ys)
                assert actual["x"] == a["x"] + xs.start * 30
                assert actual["y"] == a["y"] - ys.start * 30
                assert actual["epsg"] == a["epsg"] and actual["cell"] == 30
                assert [(s["dc"], s["dr"]) for s in actual["scenarios"]] == offsets
                for scenario, scan in zip(actual["scenarios"], scans, strict=True):
                    assert (scenario["gain"], scenario["loss"], scenario["stable"]) == (
                        scan.count(1), scan.count(-1), scan.count(0))
                    assert scenario["different_from_base"] == sum(
                        x != y for x, y in zip(scan, scans[0], strict=True))
                areas = [900 * (scan.count(1) + scan.count(-1)) for scan in scans]
                assert (int(actual["min_change_m2"]), int(actual["max_change_m2"])) == (min(areas), max(areas))
                assert actual["unstable"] == codes.count(2)
                votes = [set(pixel) for pixel in zip(*scans, strict=True)]
                lower = 900 * sum(0 not in vote for vote in votes)
                upper = 900 * sum(bool(vote - {0}) for vote in votes)
                flips = sum({-1, 1} <= vote for vote in votes)
                bounds = actual["pixelwise_change_bounds"]
                assert (int(bounds["certain_change_m2"]), int(bounds["possible_change_m2"]),
                        bounds["opposite_direction"]) == (lower, upper, flips)
                assert lower <= min(areas) <= max(areas) <= upper
                print(f"{folder} QA={screen} offsets={len(offsets)}: {valid} valid, "
                      f"{codes.count(2)} unstable, pixelwise bounds {lower}..{upper} m^2, {flips} sign flips")
                if diagonals:
                    assert valid <= axial_valid
                    extra = sum(len(set(row[:5])) == 1 and len(set(row)) > 1
                                for row in zip(*scans, strict=True))
                    print(f"  same nine-position footprint: {extra} newly unstable due to diagonals")
                else:
                    axial_valid = valid
    verify_cropped_pair(args)
    paths, _ = load_pair(ROOT, ROOT / "data/feidong/sources.json")
    assert "below minimum" in run(*paths, 0.15, "--shift-stress", "--min-coverage", 1, ok=False)
    assert "choose only one" in run(*paths, 0.15, "--shift-stress", "--summary", ok=False)
    assert "requires --shift-stress" in run(*paths, 0.15, "--include-diagonals", ok=False)
    assert "requires comma-separated thresholds" in run(*paths, "--shift-sweep", ok=False)
    assert "NDVI threshold" in run(*paths, "--shift-sweep", "0.1,0", ok=False)
    assert "choose only one" in run(*paths, "--shift-sweep", "0.1", "--summary", ok=False)


if __name__ == "__main__":
    main()

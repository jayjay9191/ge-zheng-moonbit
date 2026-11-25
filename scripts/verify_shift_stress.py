"""Independent offset classifier for five- and nine-position stress tests."""
import argparse
from fractions import Fraction
import json
import math
from pathlib import Path
from random import Random
import subprocess
from tempfile import TemporaryDirectory
from source_manifest import load_pair

ROOT = Path(__file__).resolve().parents[1]
OFFSETS = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]
DIAGONALS = [(dc, dr) for dc in (1, -1) for dr in (1, -1)]


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


def verify_class_geotiff():
    import rasterio
    from export_geotiff import export

    paths, (a, b) = load_pair(ROOT, ROOT / "data/nanjing/sources.json")
    cut = Fraction(3, 20)
    actual = run(*paths, float(cut))
    dx = (b["x"] - a["x"]) // 30
    dy = (a["y"] - b["y"]) // 30
    xs = range(max(0, dx), min(a["width"], dx + b["width"]))
    ys = range(max(0, dy), min(a["height"], dy + b["height"]))
    expected = []
    for row in ys:
        for col in xs:
            before = ndvi(a, row * a["width"] + col, True)
            after = ndvi(b, (row - dy) * b["width"] + col - dx, True)
            expected.append(None if before is None or after is None else after - before)
    classes = [-32768 if delta is None else int(delta >= cut) - int(delta <= -cut)
               for delta in expected]
    masks = [0 if delta is None else 255 for delta in expected]

    with TemporaryDirectory() as temp:
        directory = Path(temp)
        source = directory / "class.json"
        source.write_text(json.dumps(actual), encoding="utf-8")
        class_path, delta_path = export(source, directory)
        for path in (class_path, delta_path):
            with rasterio.open(path) as raster:
                assert raster.crs.to_epsg() == a["epsg"]
                assert raster.shape == (len(ys), len(xs))
                assert tuple(raster.transform)[:6] == (30, 0, a["x"] + 30 * xs.start,
                                                       0, -30, a["y"] - 30 * ys.start)
                assert raster.nodata == -32768
                assert raster.read_masks(1).ravel().tolist() == masks
                samples = raster.read(1).ravel().tolist()
                if path == class_path:
                    assert samples == classes
                else:
                    for stored, delta in zip(samples, expected, strict=True):
                        if delta is None:
                            assert stored == -32768
                        else:
                            assert abs(stored - float(delta)) < 1e-7

        # Both sample values round to Float32 0.5, but only the exact
        # threshold belongs to the gain class in the original JSON.
        boundary = dict(actual, width=2, height=1, threshold=0.5,
                        classes=[0, 1], delta=[math.nextafter(0.5, 0.0), 0.5])
        source.write_text(json.dumps(boundary), encoding="utf-8")
        class_path, delta_path = export(source, directory / "boundary")
        with rasterio.open(class_path) as classes_at_cut, rasterio.open(delta_path) as rounded:
            assert classes_at_cut.read(1).tolist() == [[0, 1]]
            assert rounded.read(1).tolist() == [[0.5, 0.5]]

        sample = next(i for i, mask in enumerate(masks) if mask)
        wrong_class = 0 if actual["classes"][sample] != 0 else 1
        for band, invalid in (("classes", 1.25), ("classes", 65537),
                              ("classes", wrong_class), ("delta", "0.5"),
                              ("delta", float("nan")), ("delta", None)):
            malformed = dict(actual)
            malformed[band] = actual[band].copy()
            malformed[band][sample] = invalid
            source.write_text(json.dumps(malformed), encoding="utf-8")
            destination = directory / "invalid"
            try:
                export(source, destination)
            except ValueError:
                assert not destination.exists()
            else:
                raise AssertionError((band, invalid))
    print(f"PASS {len(expected)} Nanjing class and delta pixels match the reference after GDAL readback")


def verify_sweep(paths, a, b, screen, offsets, flags):
    cuts = [Fraction(1, 5), Fraction(1, 10), Fraction(3, 20), Fraction(3, 20), Fraction(2)]
    actual = run(*paths, "--shift-sweep", ",".join(str(float(cut)) for cut in cuts), *flags)
    assert actual["offsets"] == len(offsets)
    assert actual["qa_screened"] == screen
    assert [row["threshold"] for row in actual["rows"]] == list(map(float, cuts))
    reference_counts = {}
    for cut, row in zip(cuts, actual["rows"], strict=True):
        if cut not in reference_counts:
            xs, ys, scans, _ = reference(a, b, cut, screen, offsets)
            assert (actual["x"], actual["y"], actual["width"], actual["height"]) == (
                a["x"] + 30 * xs.start, a["y"] - 30 * ys.start, len(xs), len(ys))
            count = len(scans[0])
            assert actual["valid"] == count
            assert actual["valid_fraction"] == count / (len(xs) * len(ys))
            votes = [set(values) for values in zip(*scans, strict=True)]
            reference_counts[cut] = (900 * sum(0 not in v for v in votes),
                                     900 * sum(v != {0} for v in votes),
                                     sum({-1, 1} <= v for v in votes))
        bounds = row["bounds"]
        assert (int(bounds["certain_change_m2"]), int(bounds["possible_change_m2"]),
                bounds["opposite_direction"]) == reference_counts[cut], (cut, row)


def verify_cropped_pairs(args):
    paths, chips = load_pair(ROOT, ROOT / "data/nanjing/sources.json")
    # Crop one date at a time to verify nonzero offsets in both directions.
    width, height, c0, r0 = 119, 121, 3, 2
    offsets = OFFSETS + DIAGONALS
    with TemporaryDirectory() as temp:
        for cropped in (0, 1):
            chip = chips[cropped]
            clipped = dict(chip, width=width, height=height,
                           x=chip["x"] + 30 * c0, y=chip["y"] - 30 * r0)
            for band in ("red", "nir", "qa", "saturation"):
                src = chip[band]
                clipped[band] = [src[row * chip["width"] + col]
                                 for row in range(r0, r0 + height)
                                 for col in range(c0, c0 + width)]
            a, b = (clipped, chips[1]) if cropped == 0 else (chips[0], clipped)
            xs, ys, _, codes = reference(a, b, Fraction(3, 20), True, offsets)
            path = Path(temp) / f"cropped-{cropped}.json"
            path.write_text(json.dumps(clipped), encoding="utf-8")
            pair = (path, paths[1]) if cropped == 0 else (paths[0], path)
            flags = ["--include-diagonals"]
            actual = run(*pair, 0.15, "--shift-stress", *flags)
            assert actual["stability"] == codes
            if args.geotiff:
                verify_geotiff(actual, a, b, xs, ys, codes)
            verify_sweep(pair, a, b, True, offsets, flags)
    print("PASS cropped real pairs with both signs of row and column offsets")


def verify_synthetic_pairs():
    rng = Random(20261125)

    def chip(scene, day, x, y):
        width, height = rng.randrange(8, 13), rng.randrange(8, 13)
        cells = width * height
        return dict(scene=scene, date=day, epsg=32650, x=x, y=y, cell=30,
                    width=width, height=height,
                    red=[rng.randrange(10000, 28000) for _ in range(cells)],
                    nir=[rng.randrange(10000, 36000) for _ in range(cells)],
                    qa=[rng.choice((1, 2, 4, 8, 16, 32, 64, 128)) if rng.randrange(15) == 0 else 0
                        for _ in range(cells)],
                    saturation=[rng.choice((1, 8, 16, 2048)) if rng.randrange(25) == 0 else 0
                                for _ in range(cells)])

    with TemporaryDirectory() as temp:
        paths = [Path(temp) / name for name in ("before.json", "after.json")]
        for case in range(48):
            a = chip("synthetic-before", "2024-09-09", 300000, 3500000)
            b = chip("synthetic-after", "2024-09-25", a["x"] + rng.randrange(-2, 3) * 30,
                     a["y"] + rng.randrange(-2, 3) * 30)
            for path, data in zip(paths, (a, b), strict=True):
                path.write_text(json.dumps(data), encoding="utf-8")
            screen = case % 3 != 0
            offsets = OFFSETS + DIAGONALS if case % 2 else OFFSETS
            flags = [] if screen else ["--direct"]
            if case % 2:
                flags.append("--include-diagonals")
            verify_sweep(paths, a, b, screen, offsets, flags)
    print("PASS 48 seeded synthetic pairs x 5 thresholds against independent Fraction bounds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true", help="verify the Nanjing nine-position QA case")
    parser.add_argument("--geotiff", action="store_true", help="also verify the exported raster through GDAL")
    args = parser.parse_args()
    if not __debug__:
        parser.error("enable Python assertions (remove -O or PYTHONOPTIMIZE)")
    folders = ("data/nanjing",) if args.quick else ("data", "data/feidong", "data/nanjing")
    for folder in folders:
        paths, (a, b) = load_pair(ROOT, ROOT / folder / "sources.json")
        for screen in (True, False):
            for diagonals in (False, True):
                if args.quick and not (screen and diagonals):
                    continue
                offsets = OFFSETS + DIAGONALS if diagonals else OFFSETS
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
                verify_sweep(paths, a, b, screen, offsets, flags)
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
                    if not args.quick:
                        assert valid <= axial_valid
                    extra = sum(len(set(row[:5])) == 1 and len(set(row)) > 1
                                for row in zip(*scans, strict=True))
                    print(f"  same nine-position footprint: {extra} newly unstable due to diagonals")
                else:
                    axial_valid = valid
    if args.geotiff:
        verify_class_geotiff()
    if args.quick:
        return
    verify_cropped_pairs(args)
    verify_synthetic_pairs()
    paths, _ = load_pair(ROOT, ROOT / "data/feidong/sources.json")
    assert "below minimum" in run(*paths, 0.15, "--shift-stress", "--min-coverage", 1, ok=False)
    assert "choose only one" in run(*paths, 0.15, "--shift-stress", "--summary", ok=False)
    assert "requires --shift-stress" in run(*paths, 0.15, "--include-diagonals", ok=False)
    assert "requires comma-separated thresholds" in run(*paths, "--shift-sweep", ok=False)
    assert "NDVI threshold" in run(*paths, "--shift-sweep", "0.1,0", ok=False)
    assert "choose only one" in run(*paths, "--shift-sweep", "0.1", "--summary", ok=False)


if __name__ == "__main__":
    main()

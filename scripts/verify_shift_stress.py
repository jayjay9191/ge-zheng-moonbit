"""Independent offset classifier for the fixed five-position stress test."""
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


def reference(a, b, cut, screen):
    # Derive candidate indices independently from absolute easting and northing.
    dx = (b["x"] - a["x"]) // a["cell"]
    dy = (a["y"] - b["y"]) // a["cell"]
    xs = range(max(0, dx + 1), min(a["width"], dx + b["width"] - 1))
    ys = range(max(0, dy + 1), min(a["height"], dy + b["height"] - 1))
    scans = [[] for _ in OFFSETS]
    codes = []
    for row in ys:
        for col in xs:
            previous = ndvi(a, row * a["width"] + col, screen)
            values = [ndvi(b, (row - dy + dr) * b["width"] + col - dx + dc, screen)
                      for dc, dr in OFFSETS]
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--geotiff", action="store_true", help="also verify the exported raster through GDAL")
    args = parser.parse_args()
    for folder in ("data", "data/feidong", "data/nanjing"):
        paths, (a, b) = load_pair(ROOT, ROOT / folder / "sources.json")
        for screen in (True, False):
            xs, ys, scans, codes = reference(a, b, Fraction(3, 20), screen)
            flags = [] if screen else ["--direct"]
            actual = run(*paths, 0.15, "--shift-stress", *flags)
            assert actual["stability"] == codes
            if args.geotiff:
                verify_geotiff(actual, a, b, xs, ys, codes)
            valid = len(scans[0])
            assert actual["valid"] == valid
            assert actual["width"] == len(xs) and actual["height"] == len(ys)
            assert actual["x"] == a["x"] + xs.start * 30
            assert actual["y"] == a["y"] - ys.start * 30
            assert actual["epsg"] == a["epsg"] and actual["cell"] == 30
            assert [(s["dc"], s["dr"]) for s in actual["scenarios"]] == OFFSETS
            for scenario, scan in zip(actual["scenarios"], scans, strict=True):
                assert (scenario["gain"], scenario["loss"], scenario["stable"]) == (
                    scan.count(1), scan.count(-1), scan.count(0))
                assert scenario["different_from_base"] == sum(
                    x != y for x, y in zip(scan, scans[0], strict=True))
            areas = [900 * (scan.count(1) + scan.count(-1)) for scan in scans]
            assert (int(actual["min_change_m2"]), int(actual["max_change_m2"])) == (min(areas), max(areas))
            assert actual["unstable"] == codes.count(2)
            print(f"{folder} QA={screen}: {valid} valid, {codes.count(2)} unstable, range {min(areas)}..{max(areas)} m^2")
    paths, _ = load_pair(ROOT, ROOT / "data/feidong/sources.json")
    assert "below minimum" in run(*paths, 0.15, "--shift-stress", "--min-coverage", 1, ok=False)
    assert "choose only one" in run(*paths, 0.15, "--shift-stress", "--summary", ok=False)


if __name__ == "__main__":
    main()

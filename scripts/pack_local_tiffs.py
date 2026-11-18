"""Package four local Landsat UInt16 GeoTIFF bands into a MoonBit input chip."""
import argparse
from datetime import date
import json
from math import floor
from pathlib import Path

import rasterio


def pack(scene, date_text, paths):
    date.fromisoformat(date_text)
    if not scene.strip():
        raise ValueError("Scene ID is required")
    bands = {}
    grid = None
    for label, path in paths.items():
        with rasterio.open(path) as src:
            epsg = src.crs.to_epsg() if src.crs else None
            t = src.transform
            if (epsg is None or epsg // 100 not in (326, 327) or not 1 <= epsg % 100 <= 60
                    or (t.a, t.b, t.d, t.e) != (30, 0, 0, -30)
                    or floor(t.c) != t.c or floor(t.f) != t.f):
                raise ValueError(f"{label}: expected a north-up 30 m WGS84 UTM grid")
            if src.count != 1 or src.dtypes[0] != "uint16" or src.nodata not in (None, 0):
                raise ValueError(f"{label}: expected one untouched UInt16 band with fill value 0")
            current = (epsg, int(t.c), int(t.f), src.width, src.height)
            if not 1 <= src.width <= 2048 or not 1 <= src.height <= 2048:
                raise ValueError(f"{label}: crop to at most 2048 × 2048 before packing")
            if grid is not None and current != grid:
                raise ValueError(f"{label}: all four bands must have identical grids")
            grid = current
            bands[label] = src.read(1).ravel().tolist()
    epsg, x, y, width, height = grid
    return dict(scene=scene, date=date_text, epsg=epsg, x=x, y=y, width=width,
                height=height, cell=30, **bands)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", required=True)
    parser.add_argument("--date", required=True)
    for flag in ("red", "nir", "qa", "saturation"):
        parser.add_argument("--" + flag, required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = pack(args.scene, args.date,
                  {key: getattr(args, key) for key in ("red", "nir", "qa", "saturation")})
    args.output.write_text(json.dumps(result, separators=(",", ":")), encoding="utf-8")

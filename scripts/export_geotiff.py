"""Export the grid already calculated by MoonBit for QGIS, ArcGIS or GDAL."""
import argparse
import json
from pathlib import Path

import numpy as np
import rasterio
from rasterio.transform import from_origin


def export(source: Path, output: Path) -> tuple[Path, ...]:
    grid = json.loads(source.read_bytes())
    shape = grid["height"], grid["width"]
    if grid["cell"] != 30 or min(shape) <= 0:
        raise ValueError("A 30 m pixel-grid audit result is required")
    excluded = -32768
    if "stability" in grid:
        codes = grid["stability"]
        if len(codes) != shape[0] * shape[1] or any(code not in (-2, -1, 0, 1, 2) for code in codes):
            raise ValueError("Invalid alignment stability raster")
        stability = np.asarray(codes, dtype="int16").reshape(shape)
        stability[stability == -2] = excluded
        layers = [("ndvi-shift-stability.tif", stability, "NDVI alignment stability")]
    else:
        if len(grid["classes"]) != shape[0] * shape[1]:
            raise ValueError("A pixel-grid audit result is required")
        classes = np.asarray(grid["classes"], dtype="int16").reshape(shape)
        delta = np.asarray([excluded if v is None else v for v in grid["delta"]],
                           dtype="float32").reshape(shape)
        if not np.array_equal(classes == -2, delta == excluded):
            raise ValueError("Classification and difference masks disagree")
        classes[classes == -2] = excluded
        layers = [("ndvi-class.tif", classes, "classification"), ("ndvi-delta.tif", delta, "NDVI delta")]
    output.mkdir(parents=True, exist_ok=True)
    options = dict(driver="GTiff", height=shape[0], width=shape[1], count=1,
                   crs=f"EPSG:{grid['epsg']}", compress="deflate", nodata=excluded,
                   transform=from_origin(grid["x"], grid["y"], grid["cell"], grid["cell"]))
    paths = []
    for name, array, label in layers:
        path = output / name
        with rasterio.open(path, "w", dtype=array.dtype.name, **options) as dest:
            dest.write(array, 1)
            dest.set_band_description(1, label)
            dest.update_tags(before=grid["first_scene"], after=grid["second_scene"],
                             threshold=str(grid["threshold"]), qa_screened=str(grid["qa_screened"]).lower())
        paths.append(path)
    return tuple(paths)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit_json", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    for path in export(args.audit_json, args.output_directory):
        print(path)

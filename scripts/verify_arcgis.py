"""Replay the Feidong Landsat chips using ArcGIS Pro Python and compare GeoTIFFs."""
import json

import arcpy
import numpy as np

from replay import ROOT
from source_manifest import load_pair

DATA = ROOT / "data/feidong"
OUT = ROOT / "results/feidong"


def write_raster(path, pixels, chip, nodata=None):
    cell = chip["cell"]
    corner = arcpy.Point(chip["x"], chip["y"] - chip["height"] * cell)
    arcpy.NumPyArrayToRaster(pixels, corner, cell, cell, nodata).save(str(path))
    arcpy.management.DefineProjection(str(path), arcpy.SpatialReference(chip["epsg"]))


def read_raster(path, chip, nodata=None):
    raster = arcpy.Raster(str(path))
    assert (raster.height, raster.width) == (chip["height"], chip["width"]), path
    assert raster.spatialReference.factoryCode == chip["epsg"], path
    assert (raster.extent.XMin, raster.extent.YMax) == (chip["x"], chip["y"]), path
    assert raster.meanCellWidth == raster.meanCellHeight == chip["cell"], path
    return arcpy.RasterToNumPyArray(raster, nodata_to_value=nodata)


def reflectance(bands, screen):
    red_dn, nir_dn, qa, saturation = bands
    red, nir = (dn.astype("float64") * 0.0000275 - 0.2 for dn in (red_dn, nir_dn))
    total = red + nir
    good = (red >= 0) & (nir >= 0) & (red <= 1) & (nir <= 1) & (total > 0)
    if screen:
        good &= ((qa & 0b111111) == 0) & ((saturation & 0x818) == 0)
    return np.divide(nir - red, total, out=np.full(red.shape, np.nan), where=good)


def main():
    _, chips = load_pair(ROOT, DATA / "sources.json")
    chip = chips[0]
    gis = OUT / "arcgis"
    gis.mkdir(parents=True, exist_ok=True)
    arcpy.env.overwriteOutput = True
    bands = []
    for i, scene in enumerate(chips, 1):
        group = []
        for name in ("red", "nir", "qa", "saturation"):
            path = gis / f"scene-{i}-{name}.tif"
            original = np.asarray(scene[name], dtype="uint16").reshape(scene["height"], scene["width"])
            write_raster(path, original, scene)
            pixels = read_raster(path, scene)
            np.testing.assert_array_equal(pixels, original)
            group.append(pixels)
        bands.append(group)
    proof = {"arcgis_pro": arcpy.GetInstallInfo()["Version"], "shape": [chip["height"], chip["width"]],
             "epsg": chip["epsg"], "cell_m": chip["cell"], "scenes": [scene["scene"] for scene in chips]}
    examples = {}
    for name, screen in (("direct", False), ("screened", True)):
        old, new = (reflectance(group, screen) for group in bands)
        delta = new - old
        good = np.isfinite(delta)
        nodata = -32768
        classes = np.where(good, (delta >= 0.15).astype("int16") - (delta <= -0.15), nodata)
        moonbit = json.loads((OUT / f"{name}.json").read_bytes())
        baseline = np.asarray(moonbit["classes"]).reshape(classes.shape)
        np.testing.assert_array_equal(classes, np.where(baseline == -2, nodata, baseline))
        expected_delta = np.asarray(moonbit["delta"], dtype="float64").reshape(delta.shape)
        np.testing.assert_allclose(delta, expected_delta, rtol=0, atol=1e-12)
        for raster_name, values in (("ndvi-class", classes), ("ndvi-delta", np.where(good, delta, nodata).astype("float32"))):
            peer = OUT / "gis" / name / f"{raster_name}.tif"
            np.testing.assert_array_equal(read_raster(peer, chip, nodata), values)
            path = gis / f"{name}-{raster_name}.tif"
            write_raster(path, values, chip, nodata)
            np.testing.assert_array_equal(read_raster(path, chip, nodata), values)
        count = {"valid": int(good.sum()), "gain": int((classes == 1).sum()),
                 "loss": int((classes == -1).sum()), "stable": int((classes == 0).sum())}
        count.update(gain_m2=count["gain"] * chip["cell"] ** 2, loss_m2=count["loss"] * chip["cell"] ** 2)
        assert all(count[k] == int(moonbit[k]) for k in count)
        proof[name] = {**count, "max_delta_error": float(np.max(np.abs(delta[good] - expected_delta[good])))}
        if screen:
            row, col = np.argwhere(classes == 1)[0]
            examples["retained_gain"] = (int(row), int(col))
        examples["masked_cloud"] = (9, 13)
    assert classes[9, 13] == -32768 and bands[0][2][9, 13] & 8
    for key, (row, col) in examples.items():
        proof[key] = {"row": row + 1, "column": col + 1, "before_qa": int(bands[0][2][row, col]),
                      "screened_delta": float(delta[row, col]) if good[row, col] else None}
    report = json.dumps(proof, indent=2) + "\n"
    (gis / "verification.json").write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    main()

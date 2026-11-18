
"""Clip two real Landsat COG scenes without resampling. Run from the project root."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import io
import json
from pathlib import Path
import rasterio
from affine import Affine

import requests
from rasterio.warp import transform
from rasterio.windows import Window

STAC = "https://planetarycomputer.microsoft.com/api/stac/v1"
SIGN = "https://planetarycomputer.microsoft.com/api/sas/v1/sign"
SCENES = ["LC09_L2SP_121038_20240418_02_T1", "LC09_L2SP_121038_20241011_02_T1"]
ASSETS = {"red": "red", "nir": "nir08", "qa": "qa_pixel", "saturation": "qa_radsat"}
CENTER = (117.435, 31.615)
SIZE = 128


def get_json(url, **params):
    response = requests.get(url, params=params, timeout=30)
    response.raise_for_status()
    return response.json()


class RangeFile(io.RawIOBase):
    """Read COG blocks through Requests when GDAL's HTTP transport is unavailable."""
    block_size = 1024 * 1024

    def __init__(self, url):
        self.url = url
        self.position = 0
        self.blocks = {}
        self.session = requests.Session()
        self._block(0)

    def _block(self, index):
        if index not in self.blocks:
            start = index * self.block_size
            end = start + self.block_size - 1
            r = self.session.get(self.url, headers={"Range": f"bytes={start}-{end}"}, timeout=45, stream=True)
            with r:
                data_range = r.headers.get("Content-Range", "")
                if r.status_code != 206 or not data_range.startswith(f"bytes {start}-"):
                    raise OSError(f"COG range request failed: HTTP {r.status_code}, offset {start}")
                self.size = int(data_range.rsplit("/", 1)[1])
                self.blocks[index] = r.content
        return self.blocks[index]

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        base = (0, self.position, self.size)[whence]
        self.position = base + offset
        return self.position

    def read(self, size=-1):
        end = self.size if size < 0 else min(self.size, self.position + size)
        chunks = []
        while self.position < end:
            index, offset = divmod(self.position, self.block_size)
            chunk = self._block(index)[offset:offset + end - self.position]
            if not chunk:
                raise OSError("Truncated COG range")
            chunks.append(chunk)
            self.position += len(chunk)
        return b"".join(chunks)

    def close(self):
        self.session.close()
        super().close()


def read_band(href, reference):
    signed = get_json(SIGN, href=href)["href"]

    def opener(path, mode="rb"):
        if path.replace(chr(92), "/") == "test/test":
            return io.BytesIO(b"test")
        if path != "source.tif":
            raise FileNotFoundError(path)
        return RangeFile(signed)

    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", GDAL_PAM_ENABLED="NO"):
        with rasterio.open("source.tif", opener=opener, driver="GTiff") as src:
            epsg, ox, oy = reference
            if not (src.transform.a == 30 and src.transform.e == -30
                    and src.transform.b == src.transform.d == 0
                    and src.crs and src.crs.to_epsg() == epsg):
                raise ValueError("Expected matching 30 m north-up UTM")
            col, row = (~src.transform) * (ox, oy)
            if abs(col - round(col)) > 1e-7 or abs(row - round(row)) > 1e-7:
                raise ValueError("Band grid differs from reference; refusing to resample")
            window = Window(round(col), round(row), SIZE, SIZE)
            values = src.read(1, window=window)
            if values.shape != (SIZE, SIZE):
                raise ValueError("Clip extends beyond source scene")
            return values.ravel().tolist(), {"url": href.split("?")[0], "window": list(window.flatten())}


def fetch(scenes=SCENES, center=CENTER, output=Path("data")):
    output.mkdir(parents=True, exist_ok=True)
    item_urls = [f"{STAC}/collections/landsat-c2-l2/items/{scene}" for scene in scenes]
    with ThreadPoolExecutor(max_workers=4) as pool:
        items = list(pool.map(get_json, item_urls))
        props = items[0]["properties"]
        epsg = props["proj:epsg"]
        grid = Affine(*props["proj:transform"][:6])
        x, y = transform("EPSG:4326", f"EPSG:{epsg}", [center[0]], [center[1]])
        col, row = (~grid) * (x[0], y[0])
        ox, oy = grid * (int(col) - SIZE // 2, int(row) - SIZE // 2)
        reference = (epsg, ox, oy)
        tasks = {(i, key): pool.submit(read_band, item["assets"][name]["href"], reference)
                 for i, item in enumerate(items) for key, name in ASSETS.items()}
        sources = []
        for i, (item, item_url) in enumerate(zip(items, item_urls, strict=True)):
            arrays, assets = {}, {}
            for key in ASSETS:
                arrays[key], assets[key] = tasks[i, key].result()
                print(item["id"], key, "done", flush=True)
            payload = {"scene": item["id"], "date": item["properties"]["datetime"][:10],
                       "epsg": epsg, "x": int(ox), "y": int(oy), "width": SIZE,
                       "height": SIZE, "cell": 30, **arrays}
            path = output / f"scene-{i + 1}.json"
            path.write_bytes(json.dumps(payload, separators=(",", ":")).encode())
            sources.append({"file": path.as_posix(), "stac": item_url,
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                            "assets": assets, "center_lonlat": center})
    (output / "sources.json").write_text(json.dumps(sources, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenes", nargs=2, default=SCENES, metavar=("BEFORE", "AFTER"))
    parser.add_argument("--center", nargs=2, type=float, default=CENTER, metavar=("LON", "LAT"))
    parser.add_argument("--output", type=Path, default=Path("data"))
    args = parser.parse_args()
    fetch(args.scenes, args.center, args.output)

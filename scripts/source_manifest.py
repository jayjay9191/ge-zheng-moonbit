"""Check the local data evidence against the declared STAC product and windows."""
import hashlib
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit


def load_pair(root: Path, manifest: Path):
    root = root.resolve()
    entries = json.loads(manifest.read_bytes())
    if not isinstance(entries, list) or len(entries) != 2:
        raise ValueError("Expected two source entries")
    paths = []
    chips = []
    for entry in entries:
        path = (root / entry["file"]).resolve()
        if not path.is_relative_to(root):
            raise ValueError("Source file must stay inside the project")
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != entry["sha256"]:
            raise ValueError(f"{path.name}: SHA-256 mismatch")
        chip = json.loads(raw)
        stac = urlsplit(entry["stac"])
        if stac.scheme != "https" or unquote(stac.path.rsplit("/", 1)[-1]) != chip["scene"]:
            raise ValueError(f"{path.name}: scene does not match the STAC item")
        date_token = chip["date"].replace("-", "")
        if date_token not in chip["scene"].split("_"):
            raise ValueError(f"{path.name}: scene and capture date disagree")
        if set(entry["assets"]) != {"red", "nir", "qa", "saturation"}:
            raise ValueError(f"{path.name}: incomplete Landsat asset list")
        for asset in entry["assets"].values():
            source = urlsplit(asset["url"])
            if source.scheme != "https" or not source.netloc or source.query:
                raise ValueError(f"{path.name}: source must be a public HTTPS asset URL")
            _, _, width, height = asset["window"]
            if (width, height) != (chip["width"], chip["height"]):
                raise ValueError(f"{path.name}: source window and chip shape disagree")
        paths.append(path)
        chips.append(chip)
    return paths, chips

"""Compare the same Landsat grid twice, varying only the QA mask."""
import hashlib
import json
from pathlib import Path

from replay import ROOT, run, verify

DATA = ROOT / "data/feidong"
OUT = ROOT / "results/feidong"
THRESHOLD = 0.15


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sources = json.loads((DATA / "sources.json").read_bytes())
    paths = [ROOT / item["file"] for item in sources]
    for path, item in zip(paths, sources, strict=True):
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"], path
    a, b = [json.loads(path.read_bytes()) for path in paths]
    assert all(a[k] == b[k] for k in ("x", "y", "epsg", "cell", "height", "width"))
    summary = {}
    maps = []
    for name, screen in (("direct", False), ("screened", True)):
        result, duration = run(*paths, THRESHOLD, direct=not screen)
        assert result.returncode == 0, result
        audit = json.loads(result.stdout)
        error = verify(audit, a, b, THRESHOLD, screen_qa=screen)
        summary[name] = {
            k: v for k, v in audit.items()
            if k not in ("classes", "delta", "ndvi_before", "ndvi_after", "water_code")
        }
        summary[name].update(reference_max_error=error, run_ms=duration)
        (OUT / f"{name}.json").write_text(result.stdout, encoding="utf-8")
        maps.append(audit)
    direct, screened = maps
    retained = [i for i, value in enumerate(screened["classes"]) if value != -2]
    removed = [i for i, value in enumerate(screened["classes"])
               if value == -2 and direct["classes"][i] != -2]
    for i in retained:
        assert screened["classes"][i] == direct["classes"][i]
        assert screened["delta"][i] == direct["delta"][i]
    assert len(removed) == direct["valid"] - screened["valid"]
    changed = [i for i in removed if direct["classes"][i] != 0]
    summary["qa_removed"] = len(removed)
    summary["qa_removed_above_threshold"] = len(changed)
    summary["qa_removed_gain"] = sum(direct["classes"][i] == 1 for i in changed)
    summary["qa_removed_loss"] = sum(direct["classes"][i] == -1 for i in changed)
    if changed:
        i = max(changed, key=lambda index: abs(direct["delta"][index]))
        r, c = divmod(i, a["width"])
        summary["example"] = {
            "row": r + 1, "column": c + 1, "x": a["x"] + (c + 0.5) * a["cell"],
            "y": a["y"] - (r + 0.5) * a["cell"], "direct_delta": direct["delta"][i],
            "qa_before": a["qa"][i], "qa_after": b["qa"][i],
            "sat_before": a["saturation"][i], "sat_after": b["saturation"][i],
        }
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

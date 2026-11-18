"""Build from MoonBit source and exercise both offline cases and the CLI."""
import json
from pathlib import Path
import tempfile
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RESULT = ROOT / "gezheng.js"
PAIR = ("data/feidong/scene-1.json", "data/feidong/scene-2.json", "0.15")


def cli(*flags):
    return subprocess.run(["node", str(RESULT), *PAIR, *flags], cwd=ROOT,
                          capture_output=True, text=True, encoding="utf-8")


def check_features():
    summary = cli("--summary")
    full = cli()
    assert summary.returncode == full.returncode == 0, (summary.stderr, full.stderr)
    small = json.loads(summary.stdout)
    large = json.loads(full.stdout)
    for name in ("valid", "gain", "loss", "gain_m2", "loss_m2", "first_qa", "second_qa"):
        assert small[name] == large[name], name
    assert "classes" not in small and "before_reason" not in small
    pixel = cli("--inspect", "10", "14")
    assert pixel.returncode == 0, pixel.stdout
    value = json.loads(pixel.stdout)
    assert value["qa_before"] & 8 and value["reason_before"] == 2 and value["delta"] is None
    denied = cli("--min-coverage", "0.70")
    assert denied.returncode == 2 and "11257/16384" in denied.stdout, denied.stdout
    source = (ROOT / PAIR[0]).read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(dir=ROOT / "_build") as scratch:
        duplicated = Path(scratch) / "duplicate-key.json"
        duplicated.write_text('{"width":1,' + source.lstrip()[1:], encoding="utf-8")
        bad = subprocess.run(["node", str(RESULT), str(duplicated), PAIR[1], PAIR[2]],
                             cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
        assert bad.returncode == 2 and "INPUT ERROR" in bad.stdout, bad.stdout


def main():
    subprocess.run(["moon", "test"], check=True, cwd=ROOT)
    subprocess.run(["moon", "build", "--release", "--target", "js"], check=True, cwd=ROOT)
    shutil.copyfile(ROOT / "_build/js/release/build/cmd/main/main.js", RESULT)
    check_features()
    for script in ("replay.py", "replay_land.py", "render_report.py", "render_land.py"):
        subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts" / script)],
                       cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        print(f"PASS {script}", flush=True)
    print("PASS coverage floor, single-pixel evidence, summary parity and both offline cases")


if __name__ == "__main__":
    main()

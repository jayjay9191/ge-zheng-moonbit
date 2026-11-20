"""Check the real built CLI against both measured Landsat windows."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "_build/js/release/build/cmd/main/main.js"


def run(folder, *flags, success=True):
    result = subprocess.run(
        ["node", str(PROGRAM), f"{folder}/scene-1.json", f"{folder}/scene-2.json", "0.15", *flags],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    assert result.returncode == (0 if success else 2), result.stdout + result.stderr
    return json.loads(result.stdout) if success else result.stdout


def main():
    subprocess.run(["moon", "build", "--release", "--target", "js"], cwd=ROOT, check=True)
    expected = {
        "data": ([11446, 10703, 10013], [285, 94, 52], 14224, 2160, 11239, 10797),
        "data/feidong": ([155, 86, 49], [1495, 577, 290], 11257, 5127, 3031, 663),
    }
    for folder, (gains, losses, valid, excluded, changed_before, changed_after) in expected.items():
        sweep = run(folder, "--sweep")
        for i, row in enumerate(sweep["rows"]):
            assert row["threshold"] == [0.1, 0.15, 0.2][i]
            assert row["counts"] == dict(gain=gains[i], loss=losses[i], valid=valid,
                                          excluded=excluded, stable=valid-gains[i]-losses[i])
        assert run(folder, "--sweep", "0.2,0.1")["rows"][0]["threshold"] == 0.2
        impact = run(folder, "--qa-impact")
        assert (impact["changed_before"], impact["changed_after"]) == (changed_before, changed_after)
        whole = run(folder, "--summary")
        for shape in ("2x2", "1x1", "3x5"):
            tiles = run(folder, "--tiles", shape)
            for field in ("gain", "loss", "stable", "valid", "excluded"):
                assert sum(tile["counts"][field] for tile in tiles) == whole[field]
        print(f"PASS {folder}: sweep, QA impact {changed_before} -> {changed_after}, 3 tile shapes")
    for flags in (("--sweep", "0"), ("--sweep", ""), ("--sweep", "2.01"),
                  ("--tiles", "0x2"), ("--tiles", "2"), ("--tiles",),
                  ("--tiles", "129x2"), ("--sweep", "--qa-impact"),
                  ("--qa-impact", "--direct"), ("--sweep", "--summary")):
        run("data", *flags, success=False)
    print("PASS invalid thresholds, dimensions and conflicting CLI modes")


if __name__ == "__main__":
    main()

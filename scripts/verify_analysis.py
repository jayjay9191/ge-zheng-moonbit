"""Check the real built CLI against both measured Landsat windows."""
from collections import Counter
import json
from pathlib import Path
import subprocess

from replay import verify
from source_manifest import load_pair

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "_build/js/release/build/cmd/main/main.js"


def run(folder, *flags, success=True, threshold="0.15"):
    result = subprocess.run(
        ["node", str(PROGRAM), f"{folder}/scene-1.json", f"{folder}/scene-2.json", threshold, *flags],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    assert result.returncode == (0 if success else 2), result.stdout + result.stderr
    return json.loads(result.stdout) if success else result.stdout


def main():
    sources = [path for path in ROOT.glob("*.mbt")
               if not path.name.endswith(("_test.mbt", "_wbtest.mbt", "_data.mbt"))
               and "generated" not in path.name]
    counts = {path.name: sum(bool(line.strip()) and not line.lstrip().startswith("//")
                            for line in path.read_text(encoding="utf-8").splitlines())
              for path in sources}
    assert sum(counts.values()) >= 500, counts
    print(f"PASS library source gate: {sum(counts.values())} nonblank/noncomment lines; excludes CLI, tests and data")
    subprocess.run(["moon", "build", "--release", "--target", "js"], cwd=ROOT, check=True)
    expected = {
        "data": ([11446, 10703, 10013], [285, 94, 52], 14224, 2160, 11239, 10797),
        "data/feidong": ([155, 86, 49], [1495, 577, 290], 11257, 5127, 3031, 663),
    }
    compared = 0
    max_error = 0.0
    for folder, (gains, losses, valid, excluded, changed_before, changed_after) in expected.items():
        sweep = run(folder, "--sweep")
        _, (before, after) = load_pair(ROOT, ROOT / folder / "sources.json")
        assert len(sweep["rows"]) == 3
        for i, cutoff in enumerate((0.1, 0.15, 0.2)):
            row = sweep["rows"][i]
            assert row["threshold"] == cutoff
            screened = run(folder, threshold=str(cutoff))
            direct = run(folder, "--direct", threshold=str(cutoff))
            max_error = max(max_error, verify(screened, before, after, cutoff),
                            verify(direct, before, after, cutoff, screen_qa=False))
            compared += 2 * screened["overlap"]
            assert row["counts"] == {key: screened[key] for key in row["counts"]}
            if cutoff == 0.15:
                classes = screened["classes"]
            assert row["counts"] == dict(gain=gains[i], loss=losses[i], valid=valid,
                                          excluded=excluded, stable=valid-gains[i]-losses[i])
        assert run(folder, "--sweep", "0.2,0.1")["rows"][0]["threshold"] == 0.2
        impact = run(folder, "--qa-impact")
        assert (impact["changed_before"], impact["changed_after"]) == (changed_before, changed_after)
        whole = run(folder, "--summary")
        for shape in ("2x2", "1x1", "3x5"):
            tiles = run(folder, "--tiles", shape)
            rows, columns = map(int, shape.split("x"))
            width, height = before["width"], before["height"]
            assert len(tiles) == rows * columns
            for index, tile in enumerate(tiles):
                row, column = divmod(index, columns)
                top, bottom = row * height // rows, (row + 1) * height // rows
                left, right = column * width // columns, (column + 1) * width // columns
                assert [tile[key] for key in ("row", "column", "row_start", "column_start",
                                             "height", "width")] == [
                    row + 1, column + 1, top, left, bottom - top, right - left]
                labels = Counter(classes[y * width + x]
                                 for y in range(top, bottom) for x in range(left, right))
                assert tile["counts"] == dict(gain=labels[1], loss=labels[-1], stable=labels[0],
                                              excluded=labels[-2], valid=sum(labels.values()) - labels[-2])
            for field in ("gain", "loss", "stable", "valid", "excluded"):
                assert sum(tile["counts"][field] for tile in tiles) == whole[field]
        print(f"PASS {folder}: sweep, QA impact {changed_before} -> {changed_after}, 3 tile shapes")
    print(f"PASS independent Fraction replay: {compared:,} pixel comparisons; max delta error {max_error:.3g}")
    for flags in (("--sweep", "0"), ("--sweep", ""), ("--sweep", "2.01"),
                  ("--tiles", "0x2"), ("--tiles", "2"), ("--tiles",),
                  ("--tiles", "129x2"), ("--sweep", "--qa-impact"),
                  ("--qa-impact", "--direct"), ("--sweep", "--summary")):
        run("data", *flags, success=False)
    for threshold in ("0", "-0.1", "2.01"):
        run("data", "--sweep", threshold=threshold, success=False)
    print("PASS invalid thresholds, dimensions and conflicting CLI modes")


if __name__ == "__main__":
    main()

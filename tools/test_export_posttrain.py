"""Complete mixed exports keep each physical scenario in exactly one dataset split."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
VARIANTS = ("refinery", "scarce", "long-beam", "open-floor")
families = {"train": set(), "validation": set()}
with tempfile.TemporaryDirectory() as directory:
    for variant in VARIANTS:
        output = Path(directory) / variant
        split = "validation" if variant == "open-floor" else "train"
        subprocess.run(
            [str(EXPORTER), str(output), "10", "1", variant, "mixed", "0", split],
            cwd=ROOT,
            check=True,
        )
        manifest = json.loads((output / "manifest.json").read_text())
        assert manifest["split"] == split and len(manifest["runs"]) == 10
        assert [run["prompt_selection"]["variant"] for run in manifest["runs"]] == [
            "canonical",
            "plain",
            "numbered",
            "questions",
            "reordered",
        ] * 2
        expected = {run["scenario_family"] for run in manifest["runs"]}
        assert len(expected) == 1
        counts = {}
        for name in ("train", "validation"):
            rows = [
                json.loads(line)
                for line in (output / (name + ".jsonl")).read_text().splitlines()
            ]
            assert (
                len(rows)
                == manifest[name + "_examples"]
                == (720 if name == split else 0)
            )
            families[name].update(row["seed"] for row in rows)
            for row in rows:
                assert row["seed"] in expected
                counts[row["episode_id"]] = counts.get(row["episode_id"], 0) + 1
                assert row["prompt_template"]["bank"] == "gift-refinements-rules-v2"
                for message in row["prompt"]:
                    assert (
                        row["prompt_template"][message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                action = json.loads(row["completion"][0]["content"])
                assert action["job"] in ("collect", "meet", "hold", "evade")
                assert action["consume"] in ("now", "end", "never")
        assert len(counts) == 10 and set(counts.values()) == {72}
        print(variant, "10 complete mixed exports into", split, "PASS", flush=True)
assert len(families["train"]) == 3 and len(families["validation"]) == 1
assert families["train"].isdisjoint(families["validation"])

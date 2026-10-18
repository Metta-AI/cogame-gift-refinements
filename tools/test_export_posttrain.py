"""Complete private candidate exports, original canonical parity, and inert seed families."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
ORIGINAL = Path(sys.argv[2]).resolve()
OUTPUT = Path(tempfile.mkdtemp(prefix="gift-source-export-"))
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
families = set()
for variant in ("refinery", "scarce", "long-beam", "open-floor"):
    original = OUTPUT / ("original-" + variant)
    subprocess.run([str(ORIGINAL), str(original), "10", "1", variant], cwd=ROOT, check=True, timeout=600)
    reference = {}
    for split in ("train", "validation"):
        for line in (original / (split + ".jsonl")).read_text().splitlines():
            row = json.loads(line)
            reference[row["episode_id"], row["decision_id"]] = row
    output = OUTPUT / variant
    subprocess.run([str(EXPORTER), str(output), "10", "1", variant], cwd=ROOT, check=True, timeout=600)
    episodes, decisions, execution = {}, {}, {}
    for name in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / name).stat().st_mode & 0o777 == 0o600
    assert not (output / "train.jsonl").exists() and not (output / "validation.jsonl").exists()
    for line in (output / "trajectories.jsonl").open():
        row = json.loads(line)
        assert row["source_revision"] == revision
        identity = row["episode_id"]
        if row["event_type"] == "episode":
            episodes[identity] = row
            continue
        decisions.setdefault(identity, []).append(row)
        assert row["action_status"] == "accepted"
        (attempt,) = row["attempts"]
        assert attempt["accepted"] and attempt["origin"] == "teacher"
        assert attempt["request"] is None and attempt["platform_call_id"] is None
        assert row["selected_attempt_id"] == attempt["attempt_id"]
        assert row["executed_action"] == attempt["parsed_action"] == json.loads(attempt["response"])
        metadata = row["observation"]["prompt_template"]
        assert metadata["bank"] == "gift-refinements-rules-v1" and metadata["variant"] == "canonical"
        for message in attempt["prompt"]:
            assert (
                metadata[message["role"] + "_sha256"].lower() == hashlib.sha256(message["content"].encode()).hexdigest()
            )
    for line in (output / "execution.jsonl").open():
        row = json.loads(line)
        execution.setdefault(row["episode_id"], []).append(row)
    assert len(episodes) == 10 and episodes.keys() == decisions.keys() == execution.keys()
    physical_frames = None
    for identity, episode in episodes.items():
        assert episode["status"] == "completed" and episode["outcome"]["reason"] == "complete"
        seed = int(identity.split("-seed-")[1].split("-")[0])
        rows = decisions[identity]
        assert len(rows) == 72 and len(execution[identity]) == 12
        for index, row in enumerate(rows):
            old = reference[f"gift-refinements-{variant}-{seed}", index]
            assert row["attempts"][0]["prompt"] == old["prompt"]
            assert row["executed_action"] == json.loads(old["completion"][0]["content"])
            assert row["observation"]["scenario_family"] == episode["seed_family"]
        frames = []
        for index, turn in enumerate(execution[identity]):
            batch = rows[index * 6 : (index + 1) * 6]
            assert turn["decision_ids"] == [row["decision_id"] for row in batch]
            assert turn["turn"] == index + 1 and turn["terminal"] == (index == 11)
            assert turn["event_end"] - turn["event_start"] == len(turn["events"])
            assert turn["start_tick"] == index * 60 and turn["end_tick"] == (index + 1) * 60
            assert len(turn["kernel_actions"]) == len(turn["frames"]) == 60
            assert all(len(actions) == 6 for actions in turn["kernel_actions"])
            frames.extend(turn["frames"])
            orders = [event for event in turn["events"] if event["k"] == "order"]
            assert len(orders) == 6
            for seat, (decision, event) in enumerate(zip(batch, orders, strict=True)):
                assert event["seat"] == seat and event["source"] == "scripted"
                assert all(
                    event[key] == decision["executed_action"][key] for key in ("job", "gift", "consume", "say", "notes")
                )
        assert [frame["tick"] for frame in frames] == list(range(720))
        assert [cog["score"] for cog in frames[-1]["cogs"]] == episode["outcome"]["scores"]
        if physical_frames is None:
            physical_frames = frames
        else:
            assert physical_frames == frames, "different seed labels must not imply independent gameplay"
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
    selected = {episode["seed_family"] for episode in episodes.values()}
    assert len(selected) == 1
    families.update(selected)
    print(
        variant,
        "ten original comparisons and candidate executions; one physical scenario across ten seeds PASS",
        flush=True,
    )
assert len(families) == 4
print("Forty games are four distinct physical scenarios; private candidates require review. Evidence:", OUTPUT)

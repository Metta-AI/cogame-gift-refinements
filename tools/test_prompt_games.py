"""Complete games: wording parity, original numeric behavior, and scenario families."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
ORIGINAL = Path(sys.argv[2]).resolve()
VARIANTS = ("refinery", "scarce", "long-beam", "open-floor")
WORDINGS = ("canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference")


def play(binary, variant, seed, wording="canonical", prompt_seed=0, text=True, original=False, private=False):
    command = [str(binary), str(ROOT / "coworld_manifest_template.json"), variant]
    if text:
        command.append("text")
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 6,
                "seed": str(seed),
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, families, systems = [], set(), {}
        while observation["kind"] == "decision":
            index, seat = observation["decision_id"], observation["seat"]
            assert index == len(trace) and seat == index % 6
            view = observation["semantic_view"].copy()
            if not original:
                metadata = view.pop("prompt_template")
                families.add(view.pop("scenario_family"))
                assert metadata["bank"] == "gift-refinements-rules-v1"
                assert metadata["selection"] == wording and metadata["seed"] == prompt_seed
                assert metadata["variant"] == (WORDINGS[prompt_seed % 5] if wording == "mixed" else wording)
                for message in observation["messages"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
            system, user = (message["content"] for message in observation["messages"])
            assert systems.setdefault(seat, system) == system
            assert all("tokens" not in peer and "notes" not in peer for peer in view["cogs"])
            assert "SPECTATOR-SPEECH-" not in user and "SPECTATOR-SPEECH-" not in json.dumps(view)
            if private and index >= 6:
                assert f"PRIVATE-SEAT-{seat}" in user
                assert all(f"PRIVATE-SEAT-{other}" not in user for other in range(6) if other != seat)
            action = json.loads(request({"kind": "teacher"})["response"])
            if not text:
                encoded = request({"kind": "encode"})
                assert len(encoded["values"]) == 764
                assert [len(head["choices"]) for head in encoded["action_heads"]] == [4, 5, 11, 3]
            if private:
                action.update(say=f"SPECTATOR-SPEECH-{seat}", notes=f"PRIVATE-SEAT-{seat}")
                if index == 0:
                    action.update(job=" HOLD ", target=view["cogs"][0]["alias"].upper(), gift="100", consume=" NEVER ")
            result = request({"kind": "step", "decision_id": index, "response": json.dumps(action)})
            assert result["kind"] == "accepted"
            if private and index == 0:
                assert result["action"]["job"] == "hold" and result["action"]["gift"] == 10
                assert result["action"]["consume"] == "never"
            else:
                assert result["action"] == action
            trace.append((view, user, result["action"]))
            observation = result["observation"]
        assert len(trace) == 72 and len(observation["scores"]) == 6
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        if not original:
            assert len(families) == 1
        return trace, observation, systems, families


families = set()
for variant in VARIANTS:
    original = play(ORIGINAL, variant, 17, text=False, original=True)
    numeric = play(BRIDGE, variant, 17, text=False)
    assert numeric[:3] == original[:3]
    families.update(numeric[3])
    canonical = play(BRIDGE, variant, 17)
    assert canonical == play(BRIDGE, variant, 99), "seed labels must not claim different scenarios"
    rendered = {}
    for wording, seed in [(wording, 0) for wording in WORDINGS] + [("mixed", seed) for seed in range(5)]:
        run = play(BRIDGE, variant, 17, wording, seed)
        assert run[:2] == canonical[:2] and run[3] == canonical[3]
        for seat, system in run[2].items():
            assert system.split("\n\n", 1)[1] == canonical[2][seat].split("\n\n", 1)[1]
        if wording == "mixed":
            assert run[2] == rendered[WORDINGS[seed]]
        else:
            rendered[wording] = run[2]
    for seat in range(6):
        assert len({prompts[seat] for prompts in rendered.values()}) == 7
    play(BRIDGE, variant, 17, private=True)
    print(variant, "complete wording, original numeric, inert seed, privacy and normalization checks PASS", flush=True)
assert len(families) == 4
for wording in WORDINGS[-2:]:
    result = subprocess.run(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), "refinery", "text"],
        input=json.dumps({"kind": "reset", "players": 6, "seed": "17", "promptVariant": wording, "split": "train"})
        + "\n",
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode != 0 and "held-out wording cannot be used for training" in result.stderr
print(
    "Four physical scenario families; all seed/wording replicas stay together; held-out training gate PASS", flush=True
)

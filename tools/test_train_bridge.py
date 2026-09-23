"""Play every certified variant through the numeric decision protocol."""

import json
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("refinery", "scarce", "long-beam", "open-floor"):
    with subprocess.Popen(
        [sys.argv[1], str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as bridge:
        assert bridge.stdin is not None and bridge.stdout is not None

        def request(payload):
            bridge.stdin.write(json.dumps(payload) + "\n")
            bridge.stdin.flush()
            return json.loads(bridge.stdout.readline())

        observation = request({"kind": "reset", "seed": "gift-bridge-test", "players": 6})
        dimensions = None
        decisions = 0
        while observation["kind"] == "decision":
            view = observation["semantic_view"]
            assert "tokens" in view["you"]
            assert all("tokens" not in peer for peer in view["cogs"])
            encoded = request({"kind": "encode"})
            assert encoded["decision_id"] == observation["decision_id"]
            dimensions = dimensions or len(encoded["values"])
            assert len(encoded["values"]) == dimensions
            assert [head["name"] for head in encoded["action_heads"]] == [
                "job", "target", "gift", "consume"
            ]
            assert [len(head["choices"]) for head in encoded["action_heads"]] == [
                4, 5, 11, 3
            ]
            response = request({"kind": "teacher"})["response"]
            action = json.loads(response)
            for head in encoded["action_heads"]:
                assert action[head["name"]] in head["choices"]
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": response}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            next_observation = result["observation"]
            if next_observation["kind"] == "decision" and decisions % 6 != 5:
                assert next_observation["turn"] == observation["turn"]
            observation = next_observation
            decisions += 1
        assert decisions == 72 and len(observation["scores"]) == 6
        assert all(score >= 0 for score in observation["scores"].values())
        bridge.stdin.close()
        assert bridge.wait() == 0
    print(variant, decisions, dimensions, observation["scores"])

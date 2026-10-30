"""Partial native HTTP -> parser/kernel -> writer Unicode regression; local sentinel only."""

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from uuid import UUID, uuid4


def scalar_json(node):
    if isinstance(node, str):
        node.encode("utf8", errors="strict")
    elif isinstance(node, dict):
        for key, value in node.items():
            scalar_json(key)
            scalar_json(value)
    elif isinstance(node, list):
        for value in node:
            scalar_json(value)


def verify(output, calls, expect):
    raw = (output / "trajectory.jsonl").read_bytes()
    native = json.loads((output / "native-summary.json").read_text())
    assert native["rounds_applied"] == 2 and native["configured_rounds"] == 12
    assert native["ticks"] == 120 and native["reason"] == "deadline"
    assert not native["complete_game"] and native["fallbacks"] == 0
    try:
        rows = [json.loads(line) for line in raw.decode("utf8").splitlines()]
        scalar_json(rows)
        valid = True
    except (UnicodeError, json.JSONDecodeError):
        valid = False
    if expect == "original":
        assert not valid, (
            "original source did not reproduce unsafe private serialization"
        )
        return {"expected_original_failure": True, "strict_scalar_json": False}
    assert valid
    decisions = [r for r in rows if r["event_type"] == "decision"]
    assert len(decisions) == 12 and rows[-1]["status"] == "failed"
    wire = {c["call_id"]: c for c in calls}
    forensic = 0
    for row in decisions:
        obs = row["observation"]
        if "invalid_native_evidence_json_b64" not in obs:
            for attempt in row["attempts"]:
                UUID(attempt["platform_call_id"])
            continue
        forensic += 1
        assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
        assert row["executed_action"] is None and row["attempts"] == []
        original = base64.b64decode(
            obs["invalid_native_evidence_json_b64"], validate=True
        )
        evidence = json.loads(original.decode("utf8", errors="surrogateescape"))
        round_id, seat = map(int, row["decision_id"].split("-"))
        snap = next(
            s for s in native["notes"] if s["round"] == round_id and s["seat"] == seat
        )
        actual = json.loads(
            base64.b64decode(snap["installed_action_json_b64"]).decode(
                "utf8", errors="surrogateescape"
            )
        )
        assert evidence["executed_action"] == actual
        for attempt in evidence["attempts"]:
            call = wire[attempt["platform_call_id"]]
            assert attempt["response_body_b64"] == call["response_b64"]
    assert forensic == 7
    assert (
        decisions[4]["action_status"] == "rejected"
        and decisions[4]["selected_attempt_id"] is None
    )
    missing = decisions[11]["attempts"][0]
    assert (
        missing["stop_reason"] is None
        and missing["input_tokens"] is None
        and missing["output_tokens"] is None
    )
    assert (
        decisions[11]["executed_action"]["notes"] == "safe"
        and decisions[11]["action_status"] == "accepted"
    )
    for index, text in ((0, "café"), (1, "😀")):
        assert decisions[index]["action_status"] == "accepted"
        assert decisions[index]["executed_action"]["notes"] == text
    assert "invalid_native_evidence_json_b64" in decisions[8]["observation"]
    return {
        "strict_scalar_json": True,
        "forensic_rows": forensic,
        "exact_native_action_bytes": True,
    }


def verify_grammar(output, calls, expect):
    rows = [
        json.loads(line)
        for line in (output / "trajectory.jsonl").read_text().splitlines()
    ]
    scalar_json(rows)
    native = json.loads((output / "native-summary.json").read_text())
    assert native["rounds_applied"] == 2 and native["ticks"] == 120
    assert (
        native["reason"] == "deadline"
        and not native["complete_game"]
        and native["fallbacks"] == 0
    )
    decisions = [row for row in rows if row["event_type"] == "decision"]
    assert len(decisions) == 12 and rows[-1]["status"] == "truncated"
    for index, row in enumerate(decisions):
        snapshot = native["notes"][index]
        actual = json.loads(base64.b64decode(snapshot["installed_action_json_b64"]))
        assert actual == row["executed_action"]
        for attempt in row["attempts"]:
            UUID(attempt["platform_call_id"])
            call = next(
                call for call in calls if call["call_id"] == attempt["platform_call_id"]
            )
            assert attempt["response_body_b64"] == call["response_b64"]
    for index in (0, 1, 2, 3, 6, 11):
        row = decisions[index]
        if expect == "original":
            assert (
                row["action_status"] == "accepted"
                and row["selected_attempt_id"] is not None
            )
        else:
            assert (
                row["action_status"] == "rejected"
                and row["selected_attempt_id"] is None
            )
    for index in (4, 5, 7, 9, 10):
        assert decisions[index]["action_status"] == "accepted"
    assert decisions[8]["action_status"] == "rejected"
    for index in (7, 9, 10):
        assert len(decisions[index]["attempts"]) == 2
        assert not decisions[index]["attempts"][0]["accepted"]
        assert decisions[index]["attempts"][1]["accepted"]
    assert (
        decisions[1]["executed_action"]["job"]
        == decisions[11]["executed_action"]["job"]
        == "hold"
    )
    return {
        "grammar_native_actions_unchanged": True,
        "strict_gate_expected": expect == "guarded",
        "statuses": [row["action_status"] for row in decisions],
    }


def main():
    allowed = {
        k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ
    }
    if set(os.environ) - set(allowed) - {"LC_CTYPE", "__CF_USER_TEXT_ENCODING"}:
        os.execve(sys.executable, [sys.executable, *sys.argv], allowed)
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nim", type=Path, required=True)
    parser.add_argument("--nimcache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--grammar", action="store_true")
    parser.add_argument("--expect", choices=("original", "guarded"), default="guarded")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    assert shutil.disk_usage(output).free >= 2 * 1024**3
    paths = [
        l.strip().split(":", 1)[1].strip('"')
        for l in (root / "nim.cfg").read_text().splitlines()
        if l.strip().startswith("--path:")
    ]
    command = [
        str(args.nim.resolve()),
        "c",
        "-d:release",
        "--hints:off",
        "--skipUserCfg:on",
        "--skipParentCfg:on",
        "--nimcache:" + str(args.nimcache.resolve()),
        "-o:" + str(output / "component"),
        "--path:src",
        *["--path:" + p for p in paths],
        "tools/ci/native_unicode_component.nim",
    ]
    card = {
        "compile_command": command,
        "parent_env_keys": sorted(os.environ),
        "compile_env_keys": sorted(allowed),
        "expect": args.expect,
        "full_games": 0,
        "provider_calls": 0,
        "fixture_usage_is_synthetic": True,
    }

    def save():
        (output / "proof.json").write_text(json.dumps(card, indent=2) + "\n")

    save()
    with (output / "compile.log").open("w") as log:
        subprocess.run(
            command,
            cwd=root,
            env=allowed,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
            timeout=240,
        )
    card["binary_sha256"] = hashlib.sha256(
        (output / "component").read_bytes()
    ).hexdigest()
    cases = [
        ('{"job":"collect","notes":"caf\\u00e9"}', None),
        ('{"job":"collect","notes":"\\ud83d\\ude00"}', None),
        ('{"job":"collect","notes":"\\udc00"}', None),
        ('{"job":"collect","notes":"BYTE"}', b"\x80"),
        ('{"job":"collect","\\udc00":1}', None),
        ('{"job":"collect","notes":"safe"}', None),
        ('{"job":"collect","notes":"BYTE"}', b"\xc0\x80"),
        ('{"job":"collect","notes":"BYTE"}', b"\xf4\x90\x80\x80"),
        ('{"job":"collect","notes":"BYTE"}', b"\xe2\x28\xa1"),
        ('{"job":"collect","notes":"BYTE"}', b"\xe2\x82"),
        ('{"job":"collect","notes":"\\ud800"}', None),
        ('{"job":"collect","notes":"safe"}', None),
    ]
    if args.grammar:
        cases = [
            ('{"job":"collect","job":"collect"}', None),
            ('{"job":"collect","job":"hold"}', None),
            ('{"job":"collect",/*local*/"notes":"safe"}', None),
            ('{"job":"collect","gift":01,"target":"Fay"}', None),
            ('```json\n{"job":"collect","notes":"safe"}\n```', None),
            ('{"job":"collect"}', None),
            ('{"job":"collect",}', None),
            ('{"job":"collect","gift":+1,"target":"Fay"}', None),
            ('{"job":"collect","unused":' + "[" * 34 + "0" + "]" * 34 + "}", None),
            ('{"job":"collect",\v"notes":"safe"}', None),
            ('{"job":"collect","unused":NaN}', None),
            ('{"job":"collect","job":"hold"} then {"job":"collect"}', None),
        ]
    calls, counts = [], {}
    started = time.monotonic()

    class Sentinel(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            assert self.path == "/v1/messages"
            body = self.rfile.read(int(self.headers["Content-Length"]))
            request = json.loads(body.decode("utf8", errors="surrogateescape"))
            assert (
                request["model"] == "local/gift-unicode-sentinel"
                and request["max_tokens"] == 1000
            )
            user = request["messages"][0]["content"]
            round_match = re.search(r"ROUND (\d+) / 12", user)
            assert round_match is not None
            round_id = int(round_match.group(1)) - 1
            seat = int(self.headers["X-Coworld-Player-Slot"])
            key = (round_id, seat)
            counts[key] = counts.get(key, 0) + 1
            text, invalid = cases[round_id * 6 + seat]
            if counts[key] > 1:
                text, invalid = '{"job":"collect"}', None
            payload = json.dumps(
                {
                    "id": "local-message",
                    "stop_reason": "end_turn",
                    "model": "local/gift-unicode-sentinel"
                    if key != (0, 5) or args.grammar
                    else "bad\udc00",
                    "content": [{"type": "text", "text": text}],
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                }
            ).encode()
            if key == (1, 5) and args.expect == "guarded" and not args.grammar:
                # Optional capture metadata is absent; native text/action is still ordinary valid.
                decoded = json.loads(payload)
                for field in ("stop_reason", "model", "usage"):
                    decoded.pop(field, None)
                payload = json.dumps(decoded).encode()
            if invalid is not None:
                payload = payload.replace(b"BYTE", invalid)
            call = {
                "call_id": str(uuid4()),
                "request_b64": base64.b64encode(body).decode(),
                "response_b64": base64.b64encode(payload).decode(),
                "elapsed_seconds": time.monotonic() - started,
                "round": round_id,
                "seat": seat,
            }
            calls.append(call)
            assert len(calls) <= 24
            with (output / "wire.jsonl").open("a") as stream:
                stream.write(json.dumps(call) + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("X-Softmax-Llm-Call-Id", call["call_id"])
            if key == (0, 5) and not args.grammar:
                self.send_header("X-Local-Invalid", "\x80")
            self.end_headers()
            self.wfile.write(payload)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    child = allowed | {
        "COWORLD_EPISODE_ID": "local-gift-unicode-partial",
        "COWORLD_GAME_VERSION": "local-component",
        "COWORLD_SOURCE_REVISION": "local-source-probe",
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
        "COWORLD_LLM_MODEL": "local/gift-unicode-sentinel",
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
    }
    run_command = [str(output / "component"), str(output), str(root)]
    card.update(run_env_keys=sorted(child), run_command=run_command)
    save()
    process = None
    try:
        with (output / "run.log").open("w") as log:
            process = subprocess.Popen(
                run_command,
                cwd=root,
                env=child,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            while process.poll() is None:
                size = sum(p.stat().st_size for p in output.rglob("*") if p.is_file())
                assert time.monotonic() - started < 60 and size <= 8 * 1024**2
                assert shutil.disk_usage(output).free >= 2 * 1024**3
                with (output / "metrics.jsonl").open("a") as stream:
                    stream.write(
                        json.dumps(
                            {
                                "elapsed_seconds": time.monotonic() - started,
                                "http_calls": len(calls),
                                "artifact_bytes": size,
                            }
                        )
                        + "\n"
                    )
                time.sleep(0.1)
            assert process.returncode == 0
        card.update(
            (verify_grammar if args.grammar else verify)(output, calls, args.expect),
            fixture_http_calls=len(calls),
            execution_seconds=time.monotonic() - started,
        )
        save()
        print(json.dumps(card))
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        server.shutdown()


if __name__ == "__main__":
    main()

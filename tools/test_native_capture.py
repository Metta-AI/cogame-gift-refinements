"""Complete native games against a local sentinel, never a provider or teacher."""

import argparse
import base64
import hashlib
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from itertools import pairwise
from pathlib import Path
from urllib.request import urlopen
from uuid import UUID


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def observe_globals(port, root, stop, failures, checker):
    """Exercise real viewer startup/reconnects and pongs while native turns wait."""
    from websockets.exceptions import WebSocketException
    from websockets.sync.client import connect

    observations = []
    try:
        with connect(
            f"ws://127.0.0.1:{port}/global", max_size=1024 * 1024, max_queue=1024
        ) as live:
            started = time.monotonic()
            packet = live.recv(timeout=3)
            assert isinstance(packet, bytes) and packet
            (root / "global-startup.bin").write_bytes(packet)
            observations.append(
                {"kind": "startup", "seconds": time.monotonic() - started}
            )
            next_snapshot = time.monotonic()
            next_ping = time.monotonic()
            while not stop.wait(0.05):
                if (root / "results.json").exists():
                    break
                try:
                    packet = live.recv(timeout=0.05)
                except TimeoutError:
                    pass
                else:
                    first = root / "global-first-physical.bin"
                    if not first.exists():
                        assert isinstance(packet, bytes) and packet
                        first.write_bytes(packet)
                        checked = subprocess.run(
                            [str(checker), "--viewer-first-frame", str(first)],
                            check=False,
                            capture_output=True,
                            timeout=10,
                        )
                        (root / "global-first-physical-check.log").write_bytes(
                            checked.stdout + checked.stderr
                        )
                        assert checked.returncode == 0, (
                            "first physical frame lost its lead history"
                        )
                if time.monotonic() >= next_ping:
                    assert live.ping().wait(2), "viewer pong starved during native wait"
                    next_ping = time.monotonic() + 1
                if time.monotonic() < next_snapshot:
                    continue
                for path in ("healthz", "client/global"):
                    with urlopen(
                        f"http://127.0.0.1:{port}/{path}", timeout=2
                    ) as response:
                        assert response.status == 200 and response.read(1024)
                with connect(
                    f"ws://127.0.0.1:{port}/global", max_size=1024 * 1024
                ) as late:
                    started = time.monotonic()
                    packet = late.recv(timeout=3)
                    assert isinstance(packet, bytes) and packet
                    # Retain a finite sample, not every sprite stream or tick.
                    name = "global-current-" + str(min(len(observations), 3)) + ".bin"
                    if not (root / name).exists():
                        (root / name).write_bytes(packet)
                    observations.append(
                        {"kind": "reconnect", "seconds": time.monotonic() - started}
                    )
                next_snapshot = time.monotonic() + 8
    except (
        AssertionError,
        OSError,
        WebSocketException,
        subprocess.SubprocessError,
    ) as error:
        if not (root / "results.json").exists():
            failures.append(repr(error))
    finally:
        (root / "global-readiness.json").write_text(
            json.dumps({"observations": observations, "failures": failures}, indent=2)
        )


def run_case(
    game,
    player,
    output,
    mode,
    variant,
    missing=False,
    capture=True,
    ordinary_clock=False,
    viewer_checker=None,
):
    root = output / (mode if capture else mode + "-no-capture")
    root.mkdir(mode=0o700)
    records = []

    class Sentinel(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_POST(self):
            assert self.path == "/v1/messages"
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            request = json.loads(raw)
            assert request["model"] == "local/capture-sentinel"
            assert self.headers["X-Coworld-Player-Slot"] == "0"
            number = len(records)
            received_at = time.monotonic()
            if ordinary_clock and number == 0:
                time.sleep(12)  # Real native wait, below its unchanged 20 s deadline.
            order: dict[str, object] = {
                "job": "collect",
                "target": None,
                "gift": 0,
                "consume": "end",
                "say": "",
                "notes": "local sentinel only",
            }
            if mode == "defaulted":
                order = {"job": "collect"}
            if mode == "clamped":
                order.update(gift=31, target="Bex")
            if mode == "truncated":
                order.update(say="a" * 90, notes="b" * 400)
            if mode == "unknown":
                order["unknown_field"] = 1
            if mode == "normalized":
                order["gift"] = "0"  # native repair; cannot become an unchanged label
            text = json.dumps(order, separators=(",", ":"))
            if mode == "fenced":
                text = "```json\n" + text + "\n```"
            if mode == "retry" and number % 2 == 0:
                text = "invalid local sentinel response"
            status = 429 if mode == "throttle" else 200
            body = json.dumps(
                {
                    "model": "local/capture-sentinel",
                    "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": text}],
                    "usage": {"input_tokens": 17, "output_tokens": 11},
                }
            ).encode()
            call = str(UUID(int=number + 1))
            records.append(
                {
                    "request": request,
                    "request_raw": raw.decode(),
                    "response_raw": body.decode(),
                    "response": text,
                    "call": call,
                    "status": status,
                    "received_at_monotonic": received_at,
                }
            )
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Softmax-Llm-Call-Id", call)
            self.send_header("request-id", "local-sentinel-" + call)
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = free_port()
    config = {
        "num_agents": 6,
        "seed": 1,
        "variant": variant,
        "rounds": 12,
        "ticksPerRound": 60,
        "minTurnSeconds": 25 if ordinary_clock else 0,
        "playerConnectTimeoutSeconds": 5,
        "shutdownGraceSeconds": 0,
        "tokens": [f"t{s}" for s in range(6)],
    }
    if variant == "open-floor":
        config["pillars"] = 0
    (root / "config.json").write_text(json.dumps(config))
    env = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(("AWS_", "ANTHROPIC_", "COWORLD_", "COGAME_", "PLAYER_"))
    }
    env.update(
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.server_port}",
        COWORLD_LLM_MODEL="local/capture-sentinel",
        COWORLD_EPISODE_ID="local-" + mode,
        COWORLD_GAME_VERSION="local-fixture",
        COWORLD_SOURCE_REVISION="local-source-fixture",
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
    )
    if not capture:
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    processes = []
    logs = []
    viewer_stop = threading.Event()
    viewer_failures = []
    viewer = None
    try:
        logs.append((root / "game.log").open("wb"))
        process = subprocess.Popen(
            [
                str(game),
                "--host:127.0.0.1",
                f"--port:{port}",
                "--config-path:" + str(root / "config.json"),
                "--results-uri:" + (root / "results.json").as_uri(),
                "--save-replay-uri:" + (root / "replay.json").as_uri(),
            ],
            env=env,
            stdout=logs[-1],
            stderr=subprocess.STDOUT,
        )
        processes.append(process)
        deadline = time.monotonic() + (420 if ordinary_clock else 60)
        while True:
            assert process.poll() is None, (root / "game.log").read_text()[-2000:]
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                assert time.monotonic() < deadline
                time.sleep(0.05)
        if ordinary_clock:
            viewer = threading.Thread(
                target=observe_globals,
                args=(port, root, viewer_stop, viewer_failures, viewer_checker),
            )
            viewer.start()
        for seat in range(6):
            seat_env = dict(
                env,
                COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
            )
            if seat == 0:
                seat_env["PLAYER_PROMPT"] = "Local sentinel protocol test only."
            else:
                seat_env["PLAYER_SCRIPTED"] = "reciprocator"
            logs.append((root / f"player{seat}.log").open("wb"))
            processes.append(
                subprocess.Popen(
                    [str(player)],
                    env=seat_env,
                    stdout=logs[-1],
                    stderr=subprocess.STDOUT,
                )
            )
        for p in processes:
            while p.poll() is None:
                assert not viewer_failures, viewer_failures
                assert time.monotonic() < deadline, (
                    "native episode exceeded finite deadline"
                )
                time.sleep(0.05)
            assert p.returncode == 0
    finally:
        viewer_stop.set()
        if viewer:
            viewer.join(timeout=10)
        for p in processes:
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=5)
        for log in logs:
            log.close()
        server.shutdown()
        server.server_close()
        (root / "sentinel-http.json").write_text(json.dumps(records, indent=2))
    if ordinary_clock:
        assert not viewer_failures, viewer_failures
        assert len(records) == 12
        assert all(
            b["received_at_monotonic"] - a["received_at_monotonic"] >= 24.5
            for a, b in pairwise(records)
        ), "native batch spacing was shortened"
    (root / "sentinel-http.json").write_text(json.dumps(records, indent=2))
    replay = json.loads((root / "replay.json").read_text())
    results = json.loads((root / "results.json").read_text())
    assert results["reason"] == "complete" and results["rounds"] == 12
    assert len(replay["frames"]) == 720
    trajectory = root / "trajectory.jsonl"
    if missing or not capture:
        assert not trajectory.exists(), (
            "old source unexpectedly emitted private native capture"
        )
        return {
            "mode": mode,
            "missing_native_capture": True,
            "completed_ticks": 720,
            "http_calls": len(records),
        }
    assert trajectory.stat().st_mode & 0o777 == 0o600
    rows = [json.loads(line) for line in trajectory.read_text().splitlines()]
    assert len(rows) == 73 and rows[-1]["status"] == "completed"
    assert rows[-1]["outcome"] == results
    assert "scenario-" in rows[-1]["seed_family"]
    orders = {(x["round"], x["seat"]): x for x in replay["events"] if x["k"] == "order"}
    seen = []
    exclusions = 0
    for row in rows[:-1]:
        seat = int(row["seat"])
        observation = row["observation"]
        execution = observation.pop("execution")
        assert execution["end_tick"] - execution["start_tick"] == 60
        assert len(execution["post_tick_hashes"]) == 60
        controls = base64.b64decode(execution["seat_controls_b64"], validate=True)
        assert len(controls) == 60 and all(
            x < len(execution["action_names"]) for x in controls
        )
        native = orders[(observation["round"], seat)]
        action = row["executed_action"]
        assert action == {k: native[k] for k in action}
        assert all(
            "tokens" not in peer and "notes" not in peer for peer in observation["cogs"]
        )
        assert "seed" not in observation
        for attempt in row["attempts"]:
            assert seat == 0 and attempt["origin"] == "model"
            record = records[len(seen)]
            seen.append(attempt)
            assert attempt["request"] == record["request"]
            assert attempt["response"] in (None, record["response"])
            assert attempt["raw_response"] == record["response_raw"]
            assert (
                base64.b64decode(attempt["response_body_b64"]).decode()
                == record["response_raw"]
            )
            assert attempt["platform_call_id"] == record["call"]
            assert attempt["http_status"] == record["status"]
            assert attempt["provider_request_id"] == "local-sentinel-" + record["call"]
            decoder_keys = {
                "max_tokens",
                "max_completion_tokens",
                "temperature",
                "top_p",
                "top_k",
                "output_config",
                "seed",
                "stop",
                "stop_sequences",
                "stop_regex",
                "no_stop_trim",
                "tool_choice",
                "tools",
                "thinking",
                "reasoning",
                "response_format",
            }
            assert attempt["decoder"] == {
                k: v for k, v in record["request"].items() if k in decoder_keys
            }
            if mode in {"normalized", "clamped", "truncated", "unknown"}:
                assert not attempt["accepted"] and attempt["parsed_action"] == action
                assert (
                    row["action_status"] == "rejected"
                    and row["selected_attempt_id"] is None
                )
                assert "changed a supplied JSON" in attempt["rejection_reason"]
                assert (
                    native["source"] == "llm"
                )  # gameplay still applies its ordinary native parser
                exclusions += 1
            elif attempt["accepted"]:
                assert attempt["parsed_action"] == action
        if seat:
            assert not row["attempts"] and row["selected_attempt_id"] is None
    assert len(seen) == len(records) == (24 if mode == "retry" else 12)
    selected = [r for r in rows[:-1] if r["selected_attempt_id"]]
    assert len(selected) == (
        0
        if mode in {"throttle", "normalized", "clamped", "truncated", "unknown"}
        else 12
    )
    if mode == "throttle":
        assert sum(r["action_status"] == "fallback" for r in rows[:-1]) == 12
    return {
        "mode": mode,
        "variant": variant,
        "ticks": 720,
        "decisions": 72,
        "http_calls": len(records),
        "model_selected": len(selected),
        "normalization_exclusions": exclusions,
        "family": rows[-1]["seed_family"],
        "trajectory_sha256": hashlib.sha256(trajectory.read_bytes()).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--expect-missing", action="store_true")
    parser.add_argument("--ordinary-clock", action="store_true")
    parser.add_argument("--viewer-checker", type=Path)
    args = parser.parse_args()
    if args.ordinary_clock:
        assert args.viewer_checker and args.viewer_checker.is_file(), (
            "ordinary clock requires --viewer-checker"
        )
    output = (
        args.output.resolve()
        if args.output
        else Path(tempfile.mkdtemp(prefix="gift-native-capture-"))
    )
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    modes = (
        [("success", "open-floor")]
        if args.ordinary_clock
        else [("success", "refinery")]
        if args.expect_missing
        else [
            ("success", "refinery"),
            ("fenced", "open-floor"),
            ("defaulted", "refinery"),
            ("normalized", "refinery"),
            ("retry", "refinery"),
            ("throttle", "refinery"),
            ("clamped", "refinery"),
            ("truncated", "refinery"),
            ("unknown", "refinery"),
        ]
    )
    result = [
        run_case(
            args.game.resolve(),
            args.player.resolve(),
            output,
            mode,
            variant,
            args.expect_missing,
            ordinary_clock=args.ordinary_clock,
            viewer_checker=args.viewer_checker.resolve()
            if args.viewer_checker
            else None,
        )
        for mode, variant in modes
    ]
    if not args.expect_missing and not args.ordinary_clock:
        for mode, variant in modes:
            run_case(
                args.game.resolve(),
                args.player.resolve(),
                output,
                mode,
                variant,
                capture=False,
            )
            before = output / mode
            after = output / (mode + "-no-capture")
            assert json.loads((before / "results.json").read_text()) == json.loads(
                (after / "results.json").read_text()
            )
            assert (
                json.loads((before / "replay.json").read_text())["frames"]
                == json.loads((after / "replay.json").read_text())["frames"]
            )
            enabled_requests = [
                x["request"]
                for x in json.loads((before / "sentinel-http.json").read_text())
            ]
            disabled_requests = [
                x["request"]
                for x in json.loads((after / "sentinel-http.json").read_text())
            ]
            assert enabled_requests == disabled_requests
    for file in output.rglob("*"):
        if file.is_file():
            file.chmod(0o600)
    (output / "proof.json").write_text(
        json.dumps(
            {
                "local_sentinel_only": True,
                "no_capture_all_cases_parity": not args.expect_missing,
                "cases": result,
            },
            indent=2,
        )
        + "\n"
    )
    print(json.dumps({"output": str(output), "cases": result}, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Load `coworld_manifest_template.json` with the INSTALLED coworld package.

Goes to: tools/ci/check_manifest_loads.py, run by ci.yml's `manifest-loads` job.

`coworld build` calls `coworld.bundle._load_template_manifest(manifest_json,
version, image_placeholders)`, which substitutes the `{{SERVICE_IMAGE}}`
placeholders and then runs `validate_upload_manifest` -- a pydantic contract far
stricter than any JSON Schema this repo can carry. 0.1.42 wants
`game.replay_viewer` (not a top-level one), no top-level `version`, no
`game.display_name`, a present `game.owner`, `game.runnable.type == "game"`,
`episode_timeout_minutes` at the top level, `variants[].description` on every
variant, `game.docs` / `game.protocols` as `{type, value}` objects, and no
runner-managed `tokens` in the certification fixture. cogame-collab-cooking hit
those at PHASE 40, on a template its own repo CI had passed (2026-08-25).

So the template is loaded here by the same code, with the same placeholders
`coworld build` would derive from `compose.yaml` -- derived without invoking
`docker compose config`, because this job has no docker and does not need one.

    python3 tools/ci/check_manifest_loads.py [coworld_manifest_template.json]

Exit 0 on success, 1 with the loader's own error on rejection, and 1 if the
loader cannot be found at all: a rename is a signal to update CANDIDATES, not a
reason to let a broken manifest through.
"""

from __future__ import annotations

import importlib
import json
import re
import sys
from pathlib import Path

# (module, attribute). `coworld.bundle._load_template_manifest` is where it has
# lived since 0.1.38; the rest are historical/likely homes, tried in order.
CANDIDATES = [
    ("coworld.bundle", "_load_template_manifest"),
    ("coworld.manifest", "_load_template_manifest"),
    ("coworld.build", "_load_template_manifest"),
    ("coworld.bundle", "load_template_manifest"),
]

SERVICE_RE = re.compile(r"^  ([A-Za-z0-9_.-]+):\s*$")
IMAGE_RE = re.compile(r"^\s+image:\s*(\S+)\s*$")


def compose_image_placeholders(compose_path: Path) -> dict[str, str]:
    """`{{SERVICE_IMAGE}} -> image`, exactly as `_compose_image_placeholders`.

    A two-space-indented key under `services:` is a service; the `image:` under
    it is its image. That is the whole of what the real helper reads out of
    `docker compose config`, and this job has no docker.
    """
    placeholders: dict[str, str] = {}
    service = None
    in_services = False
    for line in compose_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("services:"):
            in_services = True
            continue
        if not in_services:
            continue
        if line and not line.startswith(" "):
            break                       # a new top-level key ends the section
        match = SERVICE_RE.match(line)
        if match:
            service = match.group(1)
            continue
        if service is not None:
            image = IMAGE_RE.match(line)
            if image:
                key = "{{" + service.upper().replace("-", "_") + "_IMAGE}}"
                placeholders[key] = image.group(1)
                service = None
    if not placeholders:
        raise SystemExit(f"::error::no services with an image: in {compose_path}")
    return placeholders


def find_loader():
    for module_name, attribute in CANDIDATES:
        try:
            module = importlib.import_module(module_name)
        except Exception:
            continue
        loader = getattr(module, attribute, None)
        if callable(loader):
            return f"{module_name}.{attribute}", loader
    return None, None


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "coworld_manifest_template.json")
    compose = Path(sys.argv[2] if len(sys.argv) > 2 else "compose.yaml")
    for required in (path, compose):
        if not required.exists():
            print(f"::error::{required} is missing")
            return 1
    # A syntax check first, so a trailing comma reports as a trailing comma.
    try:
        manifest_json = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"::error::{path} is not valid JSON: {exc}")
        return 1

    placeholders = compose_image_placeholders(compose)
    print(f"compose placeholders: {placeholders}")

    name, loader = find_loader()
    if loader is None:
        print("::error::the installed coworld package exposes no "
              "_load_template_manifest. The phase-40 loader has been renamed: "
              "update CANDIDATES in tools/ci/check_manifest_loads.py.")
        return 1

    print(f"loading {path} with {name}")
    try:
        manifest = loader(manifest_json, "0.0.1", placeholders)
    except Exception as exc:
        print(f"::error::{name} rejected the manifest: {type(exc).__name__}: {exc}")
        return 1

    game = getattr(manifest, "game", None)
    print(f"manifest loads: game.name="
          f"{getattr(game, 'name', None)!r} "
          f"variants={len(getattr(manifest, 'variants', []) or [])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

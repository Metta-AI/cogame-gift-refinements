#!/usr/bin/env python3
"""Load `coworld_manifest_template.json` with the INSTALLED coworld package.

Goes to: tools/ci/check_manifest_loads.py, run by ci.yml.

`coworld build`'s own `_load_template_manifest` is stricter than any schema this
repo can carry: 0.1.42 wants `game.replay_viewer` (not a top-level one), no
top-level `version`, no `game.display_name`, a present `game.owner`, and no
runner-managed `tokens` in the certification fixture. cogame-collab-cooking hit
every one of those at phase 40, on a template repo CI had passed
(2026-08-25) -- so the template is loaded HERE, by the same code, and a
manifest the release would reject fails in repo CI instead.

    python3 tools/ci/check_manifest_loads.py [path/to/coworld_manifest_template.json]

Exit 0 on success. Exit 1 with the loader's own error on rejection. Exit 0 with
a loud SKIP if the installed package does not expose the private helper (the
CLI is pinned in coworld-release.yml, so a rename is a signal to update this
file, not a reason to fail the build).
"""

from __future__ import annotations

import importlib
import json
import sys
from pathlib import Path

CANDIDATES = [
    ("coworld.manifest", "_load_template_manifest"),
    ("coworld.build", "_load_template_manifest"),
    ("coworld.cli.build", "_load_template_manifest"),
    ("coworld.manifest", "load_template_manifest"),
]


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
    if not path.exists():
        print(f"::error::{path} is missing")
        return 1
    # A syntax check first, so a trailing comma reports as a trailing comma.
    try:
        json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"::error::{path} is not valid JSON: {exc}")
        return 1

    name, loader = find_loader()
    if loader is None:
        print("::warning::SKIP - the installed coworld package exposes no "
              "_load_template_manifest; the phase-40 loader has been renamed. "
              "Update tools/ci/check_manifest_loads.py's CANDIDATES.")
        return 0

    print(f"loading {path} with {name}")
    try:
        manifest = loader(str(path))
    except TypeError:
        manifest = loader(path)
    except Exception as exc:
        print(f"::error::{name} rejected the manifest: {type(exc).__name__}: {exc}")
        return 1
    game = (manifest or {}).get("game", {}) if isinstance(manifest, dict) else {}
    print(f"manifest loads: game.name={game.get('name')!r} "
          f"variants={len((manifest or {}).get('variants', []))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

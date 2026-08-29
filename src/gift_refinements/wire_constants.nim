## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the chrome sprite id).
##
## Forked from `coworld-ctf/src/ctf/wire_constants.nim`. THE GLOBAL KEEPS ITS
## NAME. `client/chrome_common.js` reads `window.CTF_WIRE` and ships as the
## starter's file plus only the fleet-wide 0.5x transport patch, so renaming
## the global would force a gratuitous divergence; `Dockerfile.replay-viewer`'s
## `grep -q '^window.CTF_WIRE={'` assertion is kept for the same reason.
##
## Historically each HTML client re-typed these as literals and nothing
## enforced agreement. This module renders them ONCE, from the same Nim consts
## the engine runs on; `server.nim` splices the block into every served client
## page and `tools/gen_wire_constants.nim` emits it for the static wasm bundle.

import std/strutils

import ./sim_types, ./global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.CTF_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",shotFxTicks:" & $FxWindow &
  ",shotTrailFalloff:1" &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.CTF_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")

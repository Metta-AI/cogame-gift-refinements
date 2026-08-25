## The static replay bundle's wasm entry point.
##
## Same structure as `coworld-ctf/replay-viewer/ctf_replay.nim` -- `stampStage`,
## the `gr_*` exports, and the `emscripten_exit_with_live_runtime()` epilogue
## (without it Nim's `main` destroys every module global while JS keeps calling
## in). What is DROPPED is `ctf_mismatch_tick`: Gift Refinements records STATE,
## not inputs, so playback never re-simulates and there is nothing to mismatch.
##
## `gr_load_replay` parses the JSON replay, hydrates the frame array and builds
## the tick -> events index; `gr_frame` advances or seeks and rebuilds the
## viewer packet. THE PACKET BUILT BY `gr_load_replay` IS THE ONLY ONE CARRYING
## THE LAYER/VIEWPORT/BOARD DEFINITIONS -- it is read directly and never
## re-derived from a later frame (matrix-games, 2026-08-24).
##
## A mid-seek click that arrives before the first chrome frame is QUEUED and
## converged with a bounded per-frame tick walk (SeekTicksPerFrame), never
## dropped (paintball, 2026-08-25).

import std/json

import gift_refinements/[sim_types, replays, broadcast, global]

const
  SeekTicksPerFrame = 240
    ## Ticks the converge walk may cross in one presentation frame. A seek is
    ## an array index here, so this only bounds the tracker's event fold.

var
  runtimeLoaded = false
  doc: ReplayDoc
  tracker: BroadcastTracker
  viewer: GlobalViewerState
  packet: seq[uint8]
  lastError: string
  playhead = 0
  pendingSeek = -1
  playing = true
  looping = false
  speedIndex = 0
  leadSent = false
  endHold = 0

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 -- allocation failure aborts the runtime loudly --
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not linear memory), so
## the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc speedFor(index: int): int =
  PlaybackSpeeds[clamp(index, 0, PlaybackSpeeds.high)]

proc windowEvents(): JsonNode =
  ## Every event inside the FX window ending at the playhead, plus the events
  ## that fired on this exact tick (the chrome feed reads those).
  result = newJArray()
  for tick in max(0, playhead - FxWindow + 1) .. playhead:
    for event in doc.eventsAt(tick):
      result.add(event)

proc renderCurrent() =
  let
    frame = doc.frames[clamp(playhead, 0, doc.frames.high)]
    events = windowEvents()
    terminal = playhead >= doc.maxTick()
    over =
      if terminal: overJson(doc.scene, doc.results, tracker, playhead)
      else: nil
    chrome = buildStateJson(
      doc.scene, frame, tracker, events, playing, speedFor(speedIndex),
      doc.maxTick(), looping, transportEnabled = true, over = over,
      leadSeries = (if leadSent: @[] else: doc.pool),
      beats = (if leadSent: nil else: doc.beats))
  leadSent = true
  var nextViewer: GlobalViewerState
  packet = buildViewerPacket(doc.scene, frame, events, chrome, viewer, nextViewer)
  nextViewer.replaySeekTick = -1
  nextViewer.replayCommands = @[]
  viewer = nextViewer

proc seekTo(tick: int) =
  ## A seek is an array index: there is no re-simulation. The tracker is
  ## re-folded from the event stream up to the new playhead, which is exactly
  ## why scrubbing back un-draws a defection.
  playhead = clamp(tick, 0, doc.maxTick())
  tracker.resync(doc.events, playhead)
  endHold = 0

proc applyCommand(command: char) =
  case command
  of ' ': playing = not playing
  of 'p': playing = true
  of 'P': playing = false
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  of '+', '=': speedIndex = min(PlaybackSpeeds.high, speedIndex + 1)
  of '-', '_': speedIndex = max(0, speedIndex - 1)
  of ',', '<':
    playing = false
    seekTo(0)
  of 'b':
    playing = false
    seekTo(playhead - 1)
  of 'e':
    playing = false
    seekTo(doc.maxTick())
  of '.', '>':
    playing = false
    seekTo(playhead + TargetFps * 5)
  of 'r': looping = not looping
  else: discard

proc grLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "gr_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    doc = parseReplay(data.bytesFromPointer(int(length)))
    stampStage("index events")
    tracker = initBroadcastTracker()
    viewer = initGlobalViewerState()
    playhead = 0
    playing = true
    leadSent = false
    runtimeLoaded = true
    stampStage("render first frame (" & $doc.scene.cols & "x" &
      $doc.scene.rows & ")")
    renderCurrent()
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg
    return 0

proc grInput(data: ptr uint8, length: cint) {.exportc: "gr_input", cdecl.} =
  if not runtimeLoaded:
    return
  viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))
  if viewer.replaySeekTick >= 0:
    pendingSeek = viewer.replaySeekTick
    viewer.replaySeekTick = -1
  for command in viewer.replayCommands:
    applyCommand(command)
  viewer.replayCommands = @[]

proc grFrame(): cint {.exportc: "gr_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage("advance replay")
  try:
    if pendingSeek >= 0:
      # A click that arrived before the first chrome frame is CONVERGED here,
      # bounded per frame, rather than dropped.
      let target = clamp(pendingSeek, 0, doc.maxTick())
      if abs(target - playhead) <= SeekTicksPerFrame:
        seekTo(target)
        pendingSeek = -1
      else:
        seekTo(playhead + (if target > playhead: SeekTicksPerFrame
                           else: -SeekTicksPerFrame))
    elif playing:
      if playhead >= doc.maxTick():
        # Hold the final frame for two seconds before a looping replay
        # restarts, so the end-card is readable.
        inc endHold
        if looping and endHold > TargetFps * 2:
          seekTo(0)
          playing = true
      else:
        let next = min(doc.maxTick(), playhead + speedFor(speedIndex))
        for tick in playhead + 1 .. next:
          for event in doc.eventsAt(tick):
            tracker.ingest(event)
        playhead = next
    renderCurrent()
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg
    return -1

proc grPacketPointer(): ptr uint8 {.exportc: "gr_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc grPacketLength(): cint {.exportc: "gr_packet_len", cdecl.} =
  cint(packet.len)

proc grErrorPointer(): ptr uint8 {.exportc: "gr_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc grErrorLength(): cint {.exportc: "gr_error_len", cdecl.} =
  cint(lastError.len)

proc grStagePointer(): ptr uint8 {.exportc: "gr_stage_ptr", cdecl.} =
  ## The progress note. Unlike gr_error_*, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc grStageLength(): cint {.exportc: "gr_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the parsed replay, the sprite caches and the fonts while the wasm
  # module stays alive and JS keeps calling gr_load_replay / gr_frame. The
  # whole session then runs on freed globals. Unwinding main through
  # emscripten's live-runtime exit skips the destructor epilogue entirely, so
  # the globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()

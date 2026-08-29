## The replay file: `gift-refinements.replay.v1`, strict UTF-8 JSON, one
## document.
##
## Rewritten rather than forked: `coworld-ctf/src/ctf/replays.nim` and
## `replay_runtime.nim` record INPUTS and re-simulate on playback. Gift
## Refinements records STATE, so playback never re-simulates, a seek is an
## array index, and there is no native/wasm divergence to chase -- which is
## also why `#mmwarn` and `ctf_mismatch_tick` are dropped from the viewer.
##
## SELF-SUFFICIENT BY CONSTRUCTION. Aliases, policy names, body colours, the
## full board geometry, every rule constant, the seed, per-tick state, the pad
## occupancy bitmap, the tokens-in-play series, the beat timeline, every event
## AND the final results all live in these bytes. The viewer contacts no server
## except S3 for the file, and `results.reason` is inside the replay as well as
## in the hosted artifact, so the two are byte-reconcilable (paintball,
## 2026-08-25).

import std/[json, tables]

import ./sim_types, ./events, ./sim

type
  ReplayDoc* = object
    ## A parsed replay, ready to play. The wasm viewer builds its whole world
    ## from this and nothing else.
    scene*: Scene
    seed*: int
    frames*: seq[ViewFrame]
    pool*: seq[array[2, int]]
    beats*: JsonNode
    events*: JsonNode
    results*: JsonNode
    byTick*: Table[int, JsonNode]  ## tick -> the events that fired on it

proc configJson(scene: Scene, seed: int): JsonNode =
  var walls = newJArray()
  for cellItem in scene.walls:
    walls.add(%[cellItem.x, cellItem.y])
  var pads = newJArray()
  for cellItem in scene.pads:
    pads.add(%[cellItem.x, cellItem.y])
  var spawns = newJArray()
  for cellItem in scene.spawns:
    spawns.add(%[cellItem.x, cellItem.y])
  %*{
    "variant": scene.variant,
    "cols": scene.cols, "rows": scene.rows, "cell": scene.cell,
    "rounds": scene.rounds, "ticksPerRound": scene.ticksPerRound,
    "walls": walls, "pads": pads, "spawns": spawns,
    "maxLevel": scene.maxLevel,
    "giftMultiplier": scene.giftMultiplier,
    "invCap": scene.invCap,
    "beamRange": scene.beamRange,
    "giftCooldown": scene.giftCooldown,
    "maxBeamsPerRound": scene.maxBeamsPerRound,
    "collectCooldown": scene.collectCooldown,
    "moveCooldown": scene.moveCooldown,
    "consumeCooldown": scene.consumeCooldown,
    "spawnTicks": scene.spawnTicks
  }

proc beatsJson*(sim: SimServer): JsonNode =
  result = newJArray()
  for beat in sim.beats:
    var node = %*{"t": beat.t, "k": beat.kind}
    if beat.n > 0:
      node["n"] = %beat.n
    if beat.seat >= 0:
      node["seat"] = %beat.seat
    result.add(node)

proc buildReplayJson*(sim: SimServer): JsonNode =
  ## The whole document. Every string in it has already been rune-truncated at
  ## the point it entered the sim, so this never has to cut anything.
  let scene = sim.scene()
  var frames = newJArray()
  for frame in sim.frames:
    var cogs = newJArray()
    for slot in 0 ..< SeatCount:
      let cog = frame.cogs[slot]
      cogs.add(%cog.x)
      cogs.add(%cog.y)
      cogs.add(%cog.tokens[0])
      cogs.add(%cog.tokens[1])
      cogs.add(%cog.tokens[2])
      cogs.add(%cog.score)
      cogs.add(%cog.flags)
    var pads = newJArray()
    for lit in frame.pads:
      pads.add(%(if lit: 1 else: 0))
    frames.add(%*{"t": frame.tick, "c": cogs, "p": pads})
  var pool = newJArray()
  for row in sim.pool:
    pool.add(%[row[0], row[1]])
  %*{
    "protocol": ReplayProtocol,
    "game": GameName,
    "gameVersion": GameVersion,
    "seed": sim.config.seed,
    "names": scene.names,
    "policyNames": scene.policyNames,
    "colors": scene.colors,
    "config": configJson(scene, sim.config.seed),
    "frames": frames,
    "series": {"pool": pool},
    "beats": beatsJson(sim),
    "events": eventsJson(sim.events),
    "results": sim.resultsJson()
  }

proc replayBytes*(sim: SimServer): string =
  $buildReplayJson(sim)

proc readCells(node: JsonNode): seq[Cell] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    if item.kind == JArray and item.len >= 2:
      result.add(cell(int(item[0].getBiggestInt()), int(item[1].getBiggestInt())))

proc readStrings(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    result.add(item.getStr())

proc parseReplay*(data: string): ReplayDoc =
  ## Parses replay BYTES into a ready-to-play document. Raises GiftError with a
  ## named reason on anything malformed -- the wasm shell surfaces that string
  ## as `data-replay-error`, so it must say what is actually wrong.
  var root: JsonNode
  try:
    root = parseJson(data)
  except CatchableError as error:
    raise newException(GiftError, "replay is not JSON: " & error.msg)
  if root.kind != JObject:
    raise newException(GiftError, "replay is not a JSON object")
  if root{"protocol"}.getStr() != ReplayProtocol:
    raise newException(GiftError,
      "replay protocol is " & root{"protocol"}.getStr().cleanText(48) &
      ", expected " & ReplayProtocol)
  let config = root{"config"}
  if config.isNil or config.kind != JObject:
    raise newException(GiftError, "replay has no config block")

  result.seed = int(root{"seed"}.getBiggestInt())
  result.scene = Scene(
    cols: int(config{"cols"}.getBiggestInt()),
    rows: int(config{"rows"}.getBiggestInt()),
    cell: int(config{"cell"}.getBiggestInt()),
    variant: config{"variant"}.getStr(),
    walls: readCells(config{"walls"}),
    pads: readCells(config{"pads"}),
    spawns: readCells(config{"spawns"}),
    names: readStrings(root{"names"}),
    policyNames: readStrings(root{"policyNames"}),
    colors: readStrings(root{"colors"}),
    rounds: int(config{"rounds"}.getBiggestInt()),
    ticksPerRound: int(config{"ticksPerRound"}.getBiggestInt()),
    maxLevel: int(config{"maxLevel"}.getBiggestInt()),
    giftMultiplier: int(config{"giftMultiplier"}.getBiggestInt()),
    invCap: int(config{"invCap"}.getBiggestInt()),
    beamRange: int(config{"beamRange"}.getBiggestInt()),
    giftCooldown: int(config{"giftCooldown"}.getBiggestInt()),
    maxBeamsPerRound: int(config{"maxBeamsPerRound"}.getBiggestInt()),
    collectCooldown: int(config{"collectCooldown"}.getBiggestInt()),
    moveCooldown: int(config{"moveCooldown"}.getBiggestInt()),
    consumeCooldown: int(config{"consumeCooldown"}.getBiggestInt()),
    spawnTicks: int(config{"spawnTicks"}.getBiggestInt())
  )
  if result.scene.cols <= 0 or result.scene.rows <= 0:
    raise newException(GiftError, "replay config has no board size")
  if result.scene.names.len != SeatCount:
    raise newException(GiftError,
      "replay names[] has " & $result.scene.names.len & " entries, expected " &
      $SeatCount)

  let frames = root{"frames"}
  if frames.isNil or frames.kind != JArray or frames.len == 0:
    raise newException(GiftError, "replay has no frames")
  for frame in frames:
    var built = ViewFrame(tick: int(frame{"t"}.getBiggestInt()))
    let cogs = frame{"c"}
    if cogs.isNil or cogs.kind != JArray or cogs.len < SeatCount * 7:
      raise newException(GiftError,
        "replay frame " & $built.tick & " does not carry six cog septets")
    for slot in 0 ..< SeatCount:
      let base = slot * 7
      built.cogs[slot] = ViewCog(
        x: int(cogs[base].getBiggestInt()),
        y: int(cogs[base + 1].getBiggestInt()),
        tokens: [int(cogs[base + 2].getBiggestInt()),
                 int(cogs[base + 3].getBiggestInt()),
                 int(cogs[base + 4].getBiggestInt())],
        score: int(cogs[base + 5].getBiggestInt()),
        flags: int(cogs[base + 6].getBiggestInt()))
    let pads = frame{"p"}
    if not pads.isNil and pads.kind == JArray:
      for lit in pads:
        built.pads.add(lit.getBiggestInt() != 0)
    result.frames.add(built)

  let pool = root{"series"}{"pool"}
  if not pool.isNil and pool.kind == JArray:
    for row in pool:
      if row.kind == JArray and row.len >= 2:
        result.pool.add([int(row[0].getBiggestInt()),
                         int(row[1].getBiggestInt())])

  result.beats = root{"beats"}
  if result.beats.isNil: result.beats = newJArray()
  result.events = root{"events"}
  if result.events.isNil: result.events = newJArray()
  result.results = root{"results"}
  if result.results.isNil: result.results = newJObject()

  result.byTick = initTable[int, JsonNode]()
  for event in result.events:
    let t = int(event{"t"}.getBiggestInt())
    if t notin result.byTick:
      result.byTick[t] = newJArray()
    result.byTick[t].add(event)

proc eventsAt*(doc: ReplayDoc, tick: int): JsonNode =
  if tick in doc.byTick: doc.byTick[tick] else: newJArray()

proc maxTick*(doc: ReplayDoc): int =
  if doc.frames.len == 0: 0 else: doc.frames[^1].tick

# ---------------------------------------------------------------------------
# playhead speed
# ---------------------------------------------------------------------------
# The playhead itself lives in `replay-viewer/gift_refinements_replay.nim`
# (module globals in the wasm entry); the speed transport lives here so the
# native tests can exercise it.

const ReplayHalfSpeedIndex* = -1
  ## `speedIndex` sentinel for the replay-only 1/2x playback (command '5'):
  ## one tick is spent every other presentation frame (halfPhase parity).

proc replaySpeedAt*(speedIndex: int): int =
  ## The integer tick multiplier (1 while at 1/2x — the fractional pace
  ## lives in replayStepBudget's frame parity).
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(speedIndex: int): float =
  ## The speed the chrome shows: 0.5 at half speed, else the integer speed.
  if speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(replaySpeedAt(speedIndex))

proc replayStepBudget*(speedIndex: int, halfPhase: bool): int =
  ## Ticks the playhead may advance this presentation frame. At 1/2x a tick
  ## is spent only every other frame (halfPhase parity).
  if speedIndex == ReplayHalfSpeedIndex:
    (if halfPhase: 1 else: 0)
  else:
    replaySpeedAt(speedIndex)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## One playback speed command. '5' selects the 1/2x replay speed
  ## (ReplayHalfSpeedIndex); '-' floors there.
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, ReplayHalfSpeedIndex)
  of '5': speedIndex = ReplayHalfSpeedIndex
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

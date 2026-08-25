## The sprite-protocol emitter: what a `/global` spectator and the static wasm
## replay bundle both see.
##
## A heavily reduced fork of `coworld-ctf/src/ctf/global.nim`. KEPT: the
## sprite-protocol emitter, layer/object pooling, per-viewer sprite dedup, the
## chrome `TextMessage` smuggling through the reserved 1x1 sprite, and
## `boardRenderScaleFor`. DELETED: fog-of-war/FOV, the first-person PiP, the
## articulated rig art, the grenade/spray/shield/barrier families, the endzone
## bakes, perks and handicaps.
##
## The board is BAKED ONCE into horizontal bands (object ids 40+, z pinned at
## the bottom, layer 0), exactly as paintbot does it: that keeps every sprite
## message far under the hosted replay's 1 MiB WebSocket frame cap AND lets
## `broadcast_core.js`'s static-band cache blit the whole deck in one
## drawImage per composite. Everything that moves is a small dynamic object
## above it.
##
## ONE renderer, two hosts. Both the live server and the wasm replayer call
## `buildViewerPacket` with a `Scene` + a `ViewFrame` + this tick's event
## window, so there is exactly one place the board is drawn and no second code
## path to drift.

import std/[json, math, os, strutils, tables]

import bitworld/spriteprotocol
import pixie

import ./sim_types

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the broadcast chrome
    ## JSON. The chrome used to ride a separate opt-in `TextMessage`; that
    ## interactive channel does NOT survive a hosted replay, so the HUD froze
    ## at its DOM defaults while the board played fine. Smuggling the chrome
    ## through the SAME binary channel the board rides makes it survive every
    ## playback path.
  MapLayerId* = 0
  MapBandSpriteBase = 30
  MapBandObjectBase = 40
  MapBandRows = 4
  StaticBandZ = -32768

  TokenSpriteBase = 100        ## 100 + level
  CogSpriteBase = 110          ## 110 + slot * 3 + pose (0 front, 1 beam, 2 bank)
  PadLitSpriteId = 130
  BeamLaneSpriteId = 131
  BeamFizzleSpriteId = 132
  BurstSpriteId = 133
  PuffSpriteId = 134
  PipSpriteBase = 140          ## 140 + level
  BadgeFrameSpriteId = 150
  LabelSpriteBase = 200        ## 200 + slot
  BadgeSpriteBase = 220        ## 220 + slot (content-keyed, re-baked on change)

  PadObjectBase = 500          ## 500 + pad index
  TokenObjectBase = 540        ## 540 + pad index
  CogObjectBase = 600          ## 600 + slot
  LabelObjectBase = 620        ## 620 + slot
  BadgeObjectBase = 640        ## 640 + slot
  FxObjectBase = 700           ## a pool for beams, bursts and puffs

  FxWindow* = 6
    ## Ticks a beam / burst / puff stays on screen. Derived from the EVENT
    ## stream in a window around the playhead rather than remembered, so a seek
    ## rebuilds exactly the same picture and scrubbing back un-draws it.
  # Exported because tools/ci/renderer_fixture.html mirrors this anchor in JS:
  # the real board is blitted as sprites, so the fixture is the only place
  # --strict-text-bounds has canvas text to measure, and
  # tests/test_broadcast.nim pins the mirror to this value.
  CogPx* = 44                  ## drawn cog size in board px (cells are 48)
  TokenPx = 24
  PipPx = 12

type
  SpriteDef = object
    id: int
    label: string

  GlobalViewerState* = object
    ## Per-viewer sprite/object bookkeeping plus the transport commands this
    ## viewer has sent since the last frame.
    defs*: seq[SpriteDef]
    objectIds*: seq[int]
    leadSent*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]

proc initGlobalViewerState*(): GlobalViewerState =
  result.replaySeekTick = -1

proc boardRenderScaleFor*(cols, rows: int): int =
  ## Board pixels per LOGICAL cell-grid pixel. Gift Refinements authors its art
  ## at the final board resolution (48 px cells, a 1152 x 672 board), so this
  ## is always 1 -- but the chrome frame ships it as `bs` and every viewer
  ## control multiplies through it, so it stays a function rather than a
  ## literal.
  1

# ---------------------------------------------------------------------------
#  Art loading and baking
# ---------------------------------------------------------------------------

var
  artCache: Table[string, Image]
  bandCache: seq[tuple[id, y, height: int, pixels: seq[uint8]]]
  bandKey = ""
  typefaceCache: Typeface
  textCache: Table[string, tuple[width, height: int, pixels: seq[uint8]]]

proc art(name: string): Image =
  if name notin artCache:
    artCache[name] = readImage(gameDir() / "data" / name)
  artCache[name]

proc straightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc scaled(name: string, w, h: int): Image =
  let key = name & "@" & $w & "x" & $h
  if key notin artCache:
    artCache[key] = art(name).resize(w, h)
  artCache[key]

proc boardTypeface(): Typeface =
  if typefaceCache.isNil:
    typefaceCache = readTypeface(gameDir() / "data" / "font.ttf")
  typefaceCache

proc textSprite(
  text: string, r, g, b: uint8, sizePx: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## One line of board text with a soft dark drop shadow, so a thin stroke stays
  ## legible over the busy deck. Baked once per (text, colour, size).
  let key = text & "|" & $r & "," & $g & "," & $b & "|" & $sizePx
  if key in textCache:
    return textCache[key]
  let font = newFont(boardTypeface())
  font.size = float32(sizePx)
  font.lineHeight = float32(sizePx) * 1.25
  let
    bounds = font.layoutBounds(text)
    width = max(1, int(ceil(bounds.x)) + 6)
    height = max(1, int(ceil(bounds.y)) + 4)
  var image = newImage(width, height)
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(0, 0, 0, 0.72)
  image.fillText(font, text, translate(vec2(4, 3)))
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(float32(r) / 255, float32(g) / 255,
                           float32(b) / 255, 1)
  image.fillText(font, text, translate(vec2(3, 2)))
  if textCache.len > 2048:
    textCache.clear()
  result = (width, height, straightRgba(image))
  textCache[key] = result

proc bakeBoard(scene: Scene): seq[tuple[id, y, height: int, pixels: seq[uint8]]] =
  ## The whole deck, in `MapBandRows` horizontal bands. Foundry-floor tiles in
  ## a two-grain checker, the wall ring, the pillars, and the 18 seep pads in
  ## their DARK state (a lit pad is a dynamic overlay, because it changes).
  let key = $scene.cols & "x" & $scene.rows & ":" & $scene.walls.len & ":" &
    $scene.pads.len
  if key == bandKey and bandCache.len > 0:
    return bandCache
  let
    cellPx = scene.cell
    width = scene.cols * cellPx
    height = scene.rows * cellPx
  var board = newImage(width, height)
  let
    floorA = scaled("floor.png", cellPx, cellPx)
    floorB = scaled("floor_alt.png", cellPx, cellPx)
    wall = scaled("wall.png", cellPx, cellPx)
    pillar = scaled("pillar.png", cellPx, cellPx)
    padDark = scaled("pad_dark.png", cellPx, cellPx)
  var blockedAt = newSeq[bool](scene.cols * scene.rows)
  for cellItem in scene.walls:
    if cellItem.x in 0 ..< scene.cols and cellItem.y in 0 ..< scene.rows:
      blockedAt[cellItem.y * scene.cols + cellItem.x] = true
  for y in 0 ..< scene.rows:
    for x in 0 ..< scene.cols:
      let at = vec2(float32(x * cellPx), float32(y * cellPx))
      if blockedAt[y * scene.cols + x]:
        # The ring is the frame of the board; a pillar is interior cover. They
        # are drawn differently on purpose: a spectator must be able to see at
        # a glance which beams are blocked by which.
        let onRing = x == 0 or y == 0 or x == scene.cols - 1 or
          y == scene.rows - 1
        board.draw(if onRing: wall else: pillar, translate(at))
      else:
        board.draw(if (x + y) mod 2 == 0: floorA else: floorB, translate(at))
  for pad in scene.pads:
    board.draw(padDark,
      translate(vec2(float32(pad.x * cellPx), float32(pad.y * cellPx))))
  let pixels = straightRgba(board)
  result = @[]
  let bandHeight = (height + MapBandRows - 1) div MapBandRows
  var y0 = 0
  var band = 0
  while y0 < height:
    let rows = min(bandHeight, height - y0)
    var slice = newSeq[uint8](width * rows * 4)
    copyMem(slice[0].addr, pixels[y0 * width * 4].addr, width * rows * 4)
    result.add((MapBandSpriteBase + band, y0, rows, slice))
    inc band
    y0 += rows
  bandKey = key
  bandCache = result

# ---------------------------------------------------------------------------
#  Packet assembly
# ---------------------------------------------------------------------------

proc defIndex(state: GlobalViewerState, id: int): int =
  for i in 0 ..< state.defs.len:
    if state.defs[i].id == id:
      return i
  -1

proc addSpriteChanged(
  packet: var seq[uint8], state: var GlobalViewerState,
  id, width, height: int, pixels: openArray[uint8], label: string
) =
  ## Appends a sprite definition only when this viewer has not already been
  ## sent this id with this exact content key. Every sprite MUST carry a
  ## non-empty label: it is the content key, and an empty one silently re-sends
  ## forever.
  doAssert label.len > 0, "sprite " & $id & " needs a non-empty label"
  doAssert id >= 0 and id <= 65535,
    "sprite id " & $id & " (" & label & ") crosses the u16 wire ceiling"
  let index = state.defIndex(id)
  if index >= 0:
    if state.defs[index].label == label:
      return
    state.defs[index].label = label
  else:
    state.defs.add(SpriteDef(id: id, label: label))
  packet.addSprite(id, width, height, pixels, label)

proc addImageSprite(
  packet: var seq[uint8], state: var GlobalViewerState,
  id: int, image: Image, label: string
) =
  packet.addSpriteChanged(state, id, image.width, image.height,
    straightRgba(image), label)

proc fxEvents(events: JsonNode, tick: int): seq[tuple[node: JsonNode, age: int]] =
  ## Every gift / miss / consume / autobank / spill row inside the FX window,
  ## with its age in ticks. Derived, never remembered -- which is what makes a
  ## seek land on the identical picture.
  if events.isNil:
    return
  for event in events:
    let t = int(event{"t"}.getBiggestInt())
    if t > tick or t <= tick - FxWindow:
      continue
    case event{"k"}.getStr()
    of "gift", "giftmiss", "consume", "autobank", "spill":
      result.add((event, tick - t))
    else: discard

proc buildViewerPacket*(
  scene: Scene,
  frame: ViewFrame,
  windowEvents: JsonNode,
  chromeJson: string,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## One presentation frame for one viewer: the board (once), everything that
  ## moves (this tick), and the chrome JSON on the reserved sprite.
  nextState = state
  let cellPx = scene.cell
  result = @[]

  # --- layer + viewport, once ----------------------------------------------
  if nextState.defs.len == 0:
    result.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
    result.addViewport(MapLayerId, scene.cols * cellPx, scene.rows * cellPx)
    for band in bakeBoard(scene):
      result.addSpriteChanged(nextState, band.id, scene.cols * cellPx,
        band.height, band.pixels, "deck band " & $band.id)
      result.addObject(MapBandObjectBase + (band.id - MapBandSpriteBase),
        0, band.y, StaticBandZ, MapLayerId, band.id)
    for level in 0 .. 2:
      result.addImageSprite(nextState, TokenSpriteBase + level,
        scaled("token_" & LevelNames[level] & ".png", TokenPx, TokenPx),
        "token " & LevelNames[level])
      result.addImageSprite(nextState, PipSpriteBase + level,
        scaled("pip_" & LevelNames[level] & ".png", PipPx, PipPx),
        "pip " & LevelNames[level])
    result.addImageSprite(nextState, PadLitSpriteId,
      scaled("pad_lit.png", cellPx, cellPx), "pad lit")
    result.addImageSprite(nextState, BeamLaneSpriteId,
      art("beam_lane.png"), "beam lane")
    result.addImageSprite(nextState, BeamFizzleSpriteId,
      art("beam_fizzle.png"), "beam fizzle")
    result.addImageSprite(nextState, BurstSpriteId, art("burst.png"), "burst")
    result.addImageSprite(nextState, PuffSpriteId, art("puff.png"), "puff")
    result.addImageSprite(nextState, BadgeFrameSpriteId, art("badge.png"),
      "badge frame")
    for slot in 0 ..< SeatCount:
      let colour = scene.colors[slot]
      for pose, suffix in ["front", "beam", "bank"]:
        result.addImageSprite(nextState, CogSpriteBase + slot * 3 + pose,
          scaled("cog_" & colour & "_" & suffix & ".png", CogPx, CogPx),
          "cog " & colour & " " & suffix)
      let label = textSprite(scene.names[slot].toUpperAscii(), 242, 232, 216, 13)
      result.addSpriteChanged(nextState, LabelSpriteBase + slot,
        label.width, label.height, label.pixels, "alias " & scene.names[slot])

  var live: seq[int] = @[]

  # --- seep pads with a loose raw token on them ----------------------------
  for i, pad in scene.pads:
    if i >= frame.pads.len or not frame.pads[i]:
      continue
    let
      px = pad.x * cellPx
      py = pad.y * cellPx
    result.addObject(PadObjectBase + i, px, py, -200, MapLayerId, PadLitSpriteId)
    result.addObject(TokenObjectBase + i, px + (cellPx - TokenPx) div 2,
      py + (cellPx - TokenPx) div 2, -100, MapLayerId, TokenSpriteBase)
    live.add(PadObjectBase + i)
    live.add(TokenObjectBase + i)

  # --- the six cogs, their alias plates and their inventory badges ---------
  for slot in 0 ..< SeatCount:
    let
      cog = frame.cogs[slot]
      px = cog.x * cellPx
      py = cog.y * cellPx
      pose =
        if (cog.flags and 1) != 0: 2        ## banking
        elif (cog.flags and 2) != 0: 1      ## firing
        else: 0
    result.addObject(CogObjectBase + slot, px + (cellPx - CogPx) div 2,
      py + (cellPx - CogPx) div 2, py + 100, MapLayerId,
      CogSpriteBase + slot * 3 + pose)
    live.add(CogObjectBase + slot)

    let label = textSprite(scene.names[slot].toUpperAscii(), 242, 232, 216, 13)
    result.addObject(LabelObjectBase + slot,
      px + (cellPx - label.width) div 2, py + cellPx - 6, py + 120, MapLayerId,
      LabelSpriteBase + slot)
    live.add(LabelObjectBase + slot)

    # The badge is content-keyed: "3/4/2" bakes once and is re-sent only when
    # the counts actually change, so a still cog costs nothing per frame.
    if cog.tokens[0] + cog.tokens[1] + cog.tokens[2] > 0:
      var parts: seq[string] = @[]
      const Glyphs = ["\u25CF", "\u25C6", "\u2726"]
      for level in 0 .. 2:
        if cog.tokens[level] > 0:
          parts.add(Glyphs[level] & $cog.tokens[level])
      let
        text = parts.join(" ")
        badge = textSprite(text, 245, 226, 190, 13)
      result.addSpriteChanged(nextState, BadgeSpriteBase + slot,
        badge.width, badge.height, badge.pixels, "badge " & $slot & " " & text)
      result.addObject(BadgeObjectBase + slot,
        px + (cellPx - badge.width) div 2, py - badge.height + 4, py + 130,
        MapLayerId, BadgeSpriteBase + slot)
      live.add(BadgeObjectBase + slot)

  # --- beams, bursts and spills, derived from the event window -------------
  var fx = FxObjectBase
  for item in fxEvents(windowEvents, frame.tick):
    let kind = item.node{"k"}.getStr()
    case kind
    of "gift":
      let
        fx0 = int(item.node{"fx"}.getBiggestInt())
        fy0 = int(item.node{"fy"}.getBiggestInt())
        tx = int(item.node{"tx"}.getBiggestInt())
        ty = int(item.node{"ty"}.getBiggestInt())
        got = int(item.node{"got"}.getBiggestInt())
        count = int(item.node{"n"}.getBiggestInt())
        steps = max(abs(tx - fx0), abs(ty - fy0))
      if steps <= 0:
        continue
      let
        stepX = (tx - fx0) div steps
        stepY = (ty - fy0) div steps
      for cellStep in 0 ..< steps:
        let
          lx = (fx0 + stepX * cellStep) * cellPx + cellPx div 2
          ly = (fy0 + stepY * cellStep) * cellPx + cellPx div 2
        result.addObject(fx, lx - cellPx div 2, ly - 8, 900, MapLayerId,
          BeamLaneSpriteId)
        live.add(fx)
        inc fx
      # The minted tokens fly along the lane and land in the receiver's badge.
      let progress = min(1.0, float(item.age + 1) / float(FxWindow))
      for token in 0 ..< min(count, 3):
        let
          lead = clamp(progress - float(token) * 0.12, 0.0, 1.0)
          px = int(float(fx0 * cellPx) + float((tx - fx0) * cellPx) * lead) +
            (cellPx - TokenPx) div 2
          py = int(float(fy0 * cellPx) + float((ty - fy0) * cellPx) * lead) +
            (cellPx - TokenPx) div 2
        result.addObject(fx, px, py, 950, MapLayerId,
          TokenSpriteBase + clamp(got, 0, 2))
        live.add(fx)
        inc fx
    of "giftmiss":
      let
        seat = int(item.node{"seat"}.getBiggestInt())
        cog = frame.cogs[clamp(seat, 0, SeatCount - 1)]
      result.addObject(fx, cog.x * cellPx, cog.y * cellPx + cellPx div 2 - 8,
        900, MapLayerId, BeamFizzleSpriteId)
      live.add(fx)
      inc fx
    of "consume", "autobank":
      let
        seat = int(item.node{"seat"}.getBiggestInt())
        cog = frame.cogs[clamp(seat, 0, SeatCount - 1)]
      result.addObject(fx, cog.x * cellPx + cellPx div 2 - 32,
        cog.y * cellPx + cellPx div 2 - 32, 960, MapLayerId, BurstSpriteId)
      live.add(fx)
      inc fx
    of "spill":
      let
        seat = int(item.node{"seat"}.getBiggestInt())
        cog = frame.cogs[clamp(seat, 0, SeatCount - 1)]
      result.addObject(fx, cog.x * cellPx, cog.y * cellPx - cellPx div 2, 970,
        MapLayerId, PuffSpriteId)
      live.add(fx)
      inc fx
    else: discard

  # --- retire anything that was on screen last frame and is not now --------
  for id in state.objectIds:
    var stillLive = false
    for keep in live:
      if keep == id:
        stillLive = true
        break
    if not stillLive:
      result.addDeleteObject(id)
  nextState.objectIds = live

  # --- the chrome, on the reserved 1x1 sprite ------------------------------
  result.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chromeJson)

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState, message: string
) =
  ## Applies one or more global protocol client messages. Whole-string commands
  ## (`s:<tick>`) are intercepted BEFORE the legacy char-by-char transport
  ## path, so a multi-digit tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        discard              ## no POV lens: nothing here is fogged
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    else:
      discard

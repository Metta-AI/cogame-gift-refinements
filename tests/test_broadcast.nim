## The chrome frame and the viewer's provenance (design note "## Tests" item 9).
##
## The last block is the scope-duplication gate: a game-block function whose
## name collides with the page's chrome alias list is silently swallowed by the
## alias block's hoisted `var`, and the scrubber ends up with unlabelled div
## markers that never seek (cogame-tandem, 2026-08-23). Static greps all pass
## while the viewer is broken, so this test exists.

import std/[algorithm, json, os, sets, strutils]

import bitworld/spriteprotocol

import gift_refinements/[global, wire_constants]

import ./helpers

suite "broadcast"

let
  repoRoot = currentSourcePath().parentDir().parentDir()
  page = readFile(repoRoot / "client" / "replay_broadcast.html")
  gameBlock = readFile(repoRoot / "client" / "game_block.html")

proc chromeFrame(sim: SimServer, tick: int, terminal: bool): JsonNode =
  var tracker = initBroadcastTracker()
  let events = eventsJson(sim.events)
  tracker.resync(events, tick)
  let
    frame = sim.frames[clamp(tick, 0, sim.frames.high)]
    over =
      if terminal: overJson(sim.scene(), sim.resultsJson(), tracker, tick)
      else: nil
  parseJson(buildStateJson(
    sim.scene(), frame, tracker, events, playing = true, speed = 1,
    maxTick = sim.frames.high, looping = false, transportEnabled = true,
    over = over, leadSeries = sim.pool, beats = beatsJson(sim)))

let sim = playScripted(allOf(blReciprocator), variantConfig("refinery"))

block twoHeadlinePlates:
  let state = chromeFrame(sim, 400, false)
  var keys: seq[string] = @[]
  for key, _ in state["teams"]:
    keys.add(key)
  keys.sort()
  check(keys == @["banked", "gifts"],
    "the teams keys are " & $keys & ", expected banked and gifts")
  for key in keys:
    check(state["teams"][key]["policies"].len == 1,
      "plate " & key & " carries no headline")
    check(state["teams"][key].hasKey("lives"),
      "plate " & key & " carries no big number (the chrome reads `lives`)")
  check(state["teams"]["gifts"]["lives"].getInt() > 0,
    "the GIFTS GIVEN plate is empty on a room that gifted")
  check(state["teams"]["banked"]["lives"].getInt() > 0,
    "the TOKENS BANKED plate is empty on a room that banked")
  banner "teams is exactly {gifts, banked}, each with a headline and a total"

block rosterCarriesBothNameSpaces:
  var named = sim
  named.policyNames[0] = "gift-refinements-mirror"
  named.policyNames[2] = "gift-refinements-patron"
  let state = chromeFrame(named, 400, false)
  check(state["roster"].len == SeatCount, "the roster is not six entries")
  for entry in state["roster"]:
    let slot = entry["s"].getInt()
    check(entry["name"].getStr() == Aliases[slot],
      "roster[].name must be the in-game ALIAS")
    check(entry["alias"].getStr() == Aliases[slot], "roster[].alias is wrong")
    check(entry.hasKey("pol"), "roster[].pol (the policy name) is missing")
    check(entry.hasKey("t0") and entry.hasKey("t1") and entry.hasKey("t2"),
      "roster[] carries no inventory badge counts")
    check(entry.hasKey("recip"), "roster[] carries no reciprocity pip")
    check(entry["team"].getStr() == "",
      "a cog was assigned to a headline plate; the plates are TOTALS")
  check(state["roster"][0]["pol"].getStr() == "gift-refinements-mirror",
    "the policy name did not reach the roster strip")
  banner "roster[] carries the alias in `name` and the POLICY name in `pol`"

block leadSeriesIsTheShapeIngestLeadSeriesExpects:
  let state = chromeFrame(sim, 400, false)
  check(state["lead"]["teams"].len == 1 and
        state["lead"]["teams"][0].getStr() == "pool",
    "lead.teams must be exactly [\"pool\"]")
  check(state["lead"]["pts"].len == sim.pool.len, "lead.pts is the wrong length")
  for row in state["lead"]["pts"]:
    check(row.len == 2, "a lead.pts row is not [tick, tokensHeld]")
  banner "lead is {teams:[pool], pts:[[t, tokensHeld]]} - no chrome change needed"

block beatsAreTheFiveDeclaredKindsAndEndOnGameover:
  let state = chromeFrame(sim, sim.frames.high, true)
  var kinds = initHashSet[string]()
  for beat in state["beats"]:
    kinds.incl(beat["k"].getStr())
  for kind in kinds:
    check(kind in ["round", "firstgift", "super", "defect", "gameover"],
      "the chrome shipped an undeclared beat kind: " & kind)
  let last = state["beats"][state["beats"].len - 1]
  check(last["k"].getStr() == "gameover", "the last beat is not gameover")
  check(last["t"].getInt() == sim.frames.high,
    "the gameover beat is not at the final tick, so the rail's right edge " &
    "never reaches the endcard (territory, 2026-08-25)")
  banner "the beat timeline ships up front, uses five kinds, ends at gameover"

block terminalFrameCarriesTheVerdict:
  let state = chromeFrame(sim, sim.frames.high, true)
  check(state["ph"].getStr() == "gameover", "the terminal frame is not gameover")
  check(state.hasKey("over"), "the terminal frame carries no end-card state")
  let over = state["over"]
  check(over["endingText"].getStr() == "ROUND LIMIT",
    "the ending is not spelled out, got " & over["endingText"].getStr())
  check(over["scores"].len == SeatCount, "the end-card lists no scores")
  check(over.hasKey("gifts") and over.hasKey("minted") and
        over.hasKey("defections"),
    "the end-card line is missing its gift / minted / defection counts")
  banner "the end-card is STATE: a seek straight to the end still shows it"

block roundClockIsSpelledOut:
  let state = chromeFrame(sim, 300, false)
  check(state["gr"]["round"].getInt() == 6,
    "tick 300 is round " & $state["gr"]["round"].getInt() & ", expected 6")
  check(state["gr"]["rounds"].getInt() == 12, "the round count is wrong")
  check(state["gr"]["ticksPerRound"].getInt() == 60, "ticksPerRound is wrong")
  check("ROUND ' + (gr.round || 1) + ' / '" in gameBlock,
    "the game block does not spell the clock out as ROUND n / m")
  check("'tick ' + Math.max(0, s.t) + ' of ' + total" in gameBlock,
    "the clock caption is not `tick N of M`")
  banner "the chrome carries the round clock and the block spells it out"

block trustGraphIsRebuiltFromEvents:
  let state = chromeFrame(sim, 400, false)
  let trust = state["gr"]["trust"]
  check(trust.len > 0, "the trust graph is empty on a room that gifted")
  for edge in trust:
    check(edge["a"].getInt() < edge["b"].getInt(), "an edge is not ordered a<b")
    check(edge["ab"].getInt() > 0 or edge["ba"].getInt() > 0,
      "an edge with no traffic was published")
  # Heaviest first, so the three text rows under the hexagon are the three
  # biggest.
  var previous = high(int)
  for edge in trust:
    let weight = edge["ab"].getInt() + edge["ba"].getInt()
    check(weight <= previous, "the trust edges are not heaviest-first")
    previous = weight
  # And it is seek-accurate: an earlier tick can never carry MORE traffic.
  let early = chromeFrame(sim, 120, false)
  var earlyTotal, lateTotal = 0
  for edge in early["gr"]["trust"]:
    earlyTotal += edge["ab"].getInt() + edge["ba"].getInt()
  for edge in trust:
    lateTotal += edge["ab"].getInt() + edge["ba"].getInt()
  check(earlyTotal <= lateTotal,
    "scrubbing back did not un-draw traffic: " & $earlyTotal & " at tick 120 " &
    "against " & $lateTotal & " at tick 400")
  banner "the trust graph is edge-ordered, seek-accurate and rebuilt from events"

block feedTextStaysInsideTheCaps:
  for event in sim.events:
    if event.kind == evOrder:
      check(event.say.len <= MaxSayRunes * 4,
        "an order's say is longer than its cap can produce")
      check(event.notes.len <= MaxNotesRunes * 4,
        "an order's notes is longer than its cap can produce")
  banner "every feed row's source string is inside its cap"

block theViewerPacketBuildsAndDecodes:
  ## The board bake, the art load and the sprite ids are otherwise only ever
  ## exercised inside the wasm bundle, where a failure is a blank theater and a
  ## timeout. Building a packet natively and decoding it with the protocol's own
  ## parser catches a bad sprite id, an unreadable asset or a truncated message
  ## on the push that introduced it.
  let bytes = replayBytes(sim)
  let doc = parseReplay(bytes)
  var
    tracker = initBroadcastTracker()
    viewer = initGlobalViewerState()
    firstBytes = 0
  for tick in [0, 1, 120, 400, doc.maxTick()]:
    tracker.resync(doc.events, tick)
    var events = newJArray()
    for at in max(0, tick - FxWindow + 1) .. tick:
      for event in doc.eventsAt(at):
        events.add(event)
    let chrome = buildStateJson(
      doc.scene, doc.frames[tick], tracker, events, playing = true, speed = 1,
      maxTick = doc.maxTick(), looping = false, transportEnabled = true)
    var next: GlobalViewerState
    let packet = buildViewerPacket(
      doc.scene, doc.frames[tick], events, chrome, viewer, next)
    viewer = next
    check(packet.len > 0, "the viewer packet is empty at tick " & $tick)
    if tick == 0:
      firstBytes = packet.len
      # The hosted replay socket closes a frame over 1 MiB with a 1009 and the
      # viewer never draws, so the FIRST packet -- the one carrying the whole
      # baked deck -- is the one that has to fit.
      check(packet.len < 1024 * 1024,
        "the first packet is " & $(packet.len div 1024) &
        " KiB, over the 1 MiB websocket frame cap")
    else:
      check(packet.len < 64 * 1024,
        "a steady-state packet is " & $(packet.len div 1024) & " KiB")
    var sprites, objects, chromeSprites = 0
    for message in parseSpritePacket(packet):
      case message.kind
      of spkSprite:
        inc sprites
        check(message.sprite.id >= 0 and message.sprite.id <= 65535,
          "a sprite id crosses the u16 wire ceiling")
        if message.sprite.id == BroadcastChromeSpriteId:
          inc chromeSprites
          discard parseJson(message.sprite.label)   ## the chrome must be JSON
      of spkObject:
        inc objects
        check(message.objectDef.spriteId >= 0, "an object has no sprite")
      else: discard
    check(chromeSprites == 1,
      "tick " & $tick & " carried " & $chromeSprites & " chrome sprites")
    check(objects > SeatCount,
      "tick " & $tick & " placed only " & $objects & " objects")
    if tick == 0:
      check(sprites > 20,
        "the first packet defined only " & $sprites & " sprites; the board " &
        "bake and the cog art are missing")
  banner "the viewer packet builds, fits the frame cap (" &
    $(firstBytes div 1024) & " KiB first) and decodes"

# ---------------------------------------------------------------------------
#  Viewer provenance
# ---------------------------------------------------------------------------

block theFixtureMirrorsTheEnginesBoardAnchors:
  ## r1 review F11. The board is blitted as sprites, so no `fillText` ever runs
  ## on the replay path and `--strict-text-bounds` on the bundle measures ZERO
  ## strings; the worst-case renderer fixture is what actually gates drawn
  ## text, and its canvas half is a HAND-WRITTEN MIRROR of global.nim's
  ## anchors. A drift there would leave the flag measuring the wrong geometry
  ## while staying green, so the mirror is pinned to the engine's constants
  ## here.
  let fixture = readFile(repoRoot / "tools" / "ci" / "renderer_fixture.html")
  let anchors = "var CELL = " & $CellPx & ", COLS = " & $Cols & ", ROWS = " &
    $Rows & ", COG = " & $CogPx & ";"
  check(anchors in fixture,
    "the fixture's mirrored board anchors are not the engine's; expected the " &
    "line: " & anchors)
  var cells = "var cells = ["
  for slot in 0 ..< SeatCount:
    if slot > 0: cells.add(", ")
    cells.add("[" & $SpawnCells[slot][0] & ", " & $SpawnCells[slot][1] & "]")
  cells.add("];")
  check(cells in fixture,
    "the fixture draws its cogs somewhere other than the engine's spawns; " &
    "expected: " & cells)
  check("ctx.font = '13px monospace';" in fixture,
    "the fixture's caption size no longer matches global.nim's 13 px text")
  check("client/chrome_common.js` is NOT loaded" in fixture,
    "the fixture's header no longer says which half of the chrome is real")
  banner "the renderer fixture's canvas mirror is pinned to the engine anchors"

block chromeCommonIsUnedited:
  ## `client/chrome_common.js` ships BYTE-FOR-BYTE. It is not edited, which is
  ## why the wire-constants global keeps the name window.CTF_WIRE.
  let chrome = readFile(repoRoot / "client" / "chrome_common.js")
  check("window.ChromeCommon = function (ctx)" in chrome,
    "chrome_common.js is not the starter's file")
  check("window.CTF_WIRE" in chrome,
    "chrome_common.js reads a global this repo does not emit")
  # The other half of that invariant, asserted on the const the engine actually
  # emits rather than on a constant-true expression (r1 review F10): the same
  # string `Dockerfile.replay-viewer` greps for in the generated
  # wire_constants.js.
  check(WireConstantsJs.startsWith("window.CTF_WIRE={"),
    "the engine no longer emits the window.CTF_WIRE global chrome_common.js " &
    "reads; it emits " & WireConstantsJs[0 .. min(31, WireConstantsJs.high)])
  banner "chrome_common.js is the starter's file, reading window.CTF_WIRE"

block removedSurfacesAreGone:
  for id in ["viewpanel", "minimap-canvas", "zoombar", "zoom-slider",
             "zoom-read", "povBadge", "fpv-canvas", "fpv-hud", "fpv-map",
             "fpv-grip"]:
    check(("id=\"" & id & "\"") notin page,
      "the page still declares #" & id)
  for fn in ["renderFpv", "drawFpvEntity", "renderPov", "minimapSeek",
             "syncViewUi", "ingestFpMap", "renderMismatch"]:
    check(("function " & fn) notin page,
      "the page still defines " & fn & ", which only served a removed surface")
  banner "#viewpanel, #fpv, #povBadge and #mmwarn are gone, code and all"

block transportRulesHold:
  check("root.style.setProperty('--hudscale'" in page,
    "relayout() no longer sets --hudscale on :root")
  check("root.style.setProperty('--band'" in page,
    "relayout() no longer sets --band on :root")
  check("root.style.setProperty('--topband'" in page,
    "relayout() no longer sets --topband on :root")
  check("bottom: var(--band, 0px)" in page,
    "the endcard no longer stops at the transport band")
  check("var(--band" in gameBlock,
    "the appended panels are not clipped above the transport band")
  # Every seek dismisses the endcard: the page clears it on any non-gameover
  # frame, and a seek re-renders.
  check("$('endcard').classList.remove('on')" in page,
    "the endcard is no longer dismissed on a non-terminal frame")
  banner "--hudscale/--band/--topband on :root, endcard above the band"

block beatsAreLabelledClickableButtons:
  check("document.createElement('button')" in gameBlock,
    "the beat markers are not buttons")
  check("el.setAttribute('aria-label', label)" in gameBlock,
    "the beat markers carry no aria-label")
  check("CTX.send('s:' + tick)" in gameBlock,
    "the beat markers do not seek on click")
  for kind in ["round", "firstgift", "super", "defect", "gameover"]:
    check((".beat-marker." & kind) in gameBlock,
      "there is no CSS rule for the " & kind & " beat")
  banner "every beat is a labelled, clickable button with CSS for its kind"

block beatMarkersAreBuiltOnce:
  ## r1 review F4. Nothing ever removes a `.beat-marker` from #scrub, so the
  ## dedup map must survive a jump: clearing it on a backward seek made
  ## playback append a second, exactly superimposed button every time it
  ## re-crossed a live `round` or `defect` tick.
  let withoutDeclaration = gameBlock.replace("var placedBeats = {};", "")
  check("placedBeats = {}" notin withoutDeclaration,
    "the beat dedup map is reset, so a backward seek re-appends markers")
  check("if (placedBeats[key]) return;" in gameBlock,
    "buildGiftBeats no longer dedups on tick|kind|seat")
  banner "beat markers are built once per tick|kind|seat and never rebuilt"

block spoilersHoldThisBlocksBeatsBack:
  ## r1 review F3. The chrome's own gate (chrome_common.js `applySpoilers`)
  ## only sees the markers IT created; this block appends its own labelled
  ## buttons, so `?spoilers=0` only holds them back if the block gates them
  ## too — through the chrome object the page hands it in GR_CTX.
  check("C: C," in page,
    "GR_CTX no longer carries the chrome object the block's spoiler gate reads")
  check("CTX.C.getSpoilers()" in gameBlock,
    "the game block does not read the chrome's [spoilers] mode")
  check("function applyGiftSpoilers(s)" in gameBlock,
    "the game block has no spoiler gate for its own beat markers")
  check("giftMarkers.push(el)" in gameBlock,
    "the block's beat buttons are not registered with its spoiler gate")
  check("applyGiftSpoilers(s);" in gameBlock,
    "the spoiler gate is never applied on a frame")
  check("attributeFilter: ['class']" in gameBlock,
    "toggling [spoilers] while paused would not re-gate this block's markers")
  banner "?spoilers=0 holds this block's beat markers back as well"

block legibilityAt360:
  check(".plate-name" in gameBlock and "flex: 1 1 auto" in gameBlock and
        "min-width: 3.2em" in gameBlock,
    "the .plate-name rule that stops names collapsing to \"…\" is missing")
  check("#stage.tiny" in gameBlock,
    "the game block does not hide labels on a narrow board")
  check("stage.classList.toggle('tiny', boardW <= 620)" in page,
    "the page no longer switches #stage.tiny on a narrow board")
  check("stage.classList.toggle('mini'" in gameBlock,
    "the trust hexagon does not collapse under 480 px")
  banner "the scorebug and roster stay legible at 360 px"

block pushFeedKeepsItsOneArgumentSignature:
  ## Changing this signature is what broke cogball 0.1.4: the viewer loaded,
  ## passed every scrub readout, and froze mid-replay.
  check("function pushFeed(row) {" in page,
    "the page's pushFeed no longer takes exactly one argument")
  check("CTX.pushFeed(row);" in gameBlock,
    "the game block calls pushFeed with something other than one row")
  banner "pushFeed(row) keeps the starter's one-argument signature"

block theBeatBuilderIsNotMarkBeat:
  check("function buildGiftBeats(" in gameBlock,
    "the game block's beat builder is not named buildGiftBeats")
  check("function markBeat" notin gameBlock.replace("`function markBeat`", ""),
    "the game block declares a function called markBeat")
  banner "the game-block beat builder is buildGiftBeats"

block noGameBlockNameCollidesWithTheChromeAliasList:
  ## The gate. Strip comments from both halves, take every name the page's
  ## chrome alias block binds (`<name> = C.<something>`) and every name the
  ## game block declares (`function <name>` / `var <name>`), and require the
  ## intersection to be EMPTY. Hand-rolled rather than std/re: `re` needs
  ## libpcre at RUN time, and a test that cannot start is not a gate.
  proc stripComments(text: string): string =
    var
      i = 0
      inBlock = false
      inLine = false
    while i < text.len:
      if inBlock:
        if i + 1 < text.len and text[i] == '*' and text[i + 1] == '/':
          inBlock = false
          result.add(' ')
          inc i, 2
        else:
          result.add(if text[i] == '\n': '\n' else: ' ')
          inc i
      elif inLine:
        if text[i] == '\n':
          inLine = false
          result.add('\n')
        else:
          result.add(' ')
        inc i
      elif i + 1 < text.len and text[i] == '/' and text[i + 1] == '*':
        inBlock = true
        inc i, 2
      elif i + 1 < text.len and text[i] == '/' and text[i + 1] == '/':
        inLine = true
        inc i, 2
      else:
        result.add(text[i])
        inc i

  proc isNameChar(ch: char): bool =
    ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}

  proc identifierBefore(text: string, at: int): string =
    ## The identifier ending just before `at`, skipping whitespace.
    var i = at - 1
    while i >= 0 and text[i] in {' ', '\t'}: dec i
    let stop = i
    while i >= 0 and text[i].isNameChar(): dec i
    if stop <= i: return ""
    text[i + 1 .. stop]

  proc identifierAfter(text: string, at: int): string =
    var i = at
    while i < text.len and text[i] in {' ', '\t'}: inc i
    let start = i
    while i < text.len and text[i].isNameChar(): inc i
    if i <= start: return ""
    text[start ..< i]

  proc stripHtmlComments(text: string): string =
    ## The game block opens with an HTML banner that QUOTES `function markBeat`
    ## to say what must never be written. That is prose, not code.
    var i = 0
    while i < text.len:
      if i + 3 < text.len and text[i .. i + 3] == "<!--":
        let close = text.find("-->", i)
        if close < 0: return result
        for _ in i .. close + 2: result.add(' ')
        i = close + 3
      else:
        result.add(text[i])
        inc i

  let
    marker = "GIFT-REFINEMENTS additions to the inherited coworld-ctf chrome"
    head = stripComments(stripHtmlComments(page[0 ..< page.find(marker)]))
    block2 = stripComments(stripHtmlComments(gameBlock))

  # Every `<name> = C.<member>` binding in the page's chrome alias block.
  var aliases = initHashSet[string]()
  var cursor = 0
  while true:
    let at = head.find("= C.", cursor)
    if at < 0: break
    let name = head.identifierBefore(at)
    if name.len > 0: aliases.incl(name)
    cursor = at + 4
  check(aliases.len >= 20,
    "only found " & $aliases.len & " chrome aliases; the scan is broken")
  check("markBeat" in aliases,
    "markBeat is not in the alias list; the scan is broken")

  # Every `function <name>` and `var <name>` the game block declares.
  var declared = initHashSet[string]()
  for keyword in ["function ", "var "]:
    cursor = 0
    while true:
      let at = block2.find(keyword, cursor)
      if at < 0: break
      cursor = at + keyword.len
      if at > 0 and block2[at - 1].isNameChar():
        continue                      ## part of a longer word
      let name = block2.identifierAfter(at + keyword.len)
      if name.len > 0: declared.incl(name)
  check(declared.len >= 8,
    "only found " & $declared.len & " game-block declarations; the scan is broken")
  check("buildGiftBeats" in declared,
    "the scan did not see buildGiftBeats; it is broken")

  let clash = aliases * declared
  check(clash.len == 0,
    "these game-block names collide with the chrome alias list and would be " &
    "hoisted over: " & $clash)
  echo "  \u2713 no game-block name collides with the ", aliases.len,
    " chrome aliases"

echo "test_broadcast OK"

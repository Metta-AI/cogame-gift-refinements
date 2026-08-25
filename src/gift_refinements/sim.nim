## The gameplay core: the tick loop and the seven numbered steps.
##
## Forked from `coworld-ctf/src/ctf/sim.nim` -- the same shape (a `SimServer`
## that owns the whole episode, a `step` that resolves one tick, a `gameHash`
## that makes a seed reproduce a replay bit-exactly) with the CTF gameplay
## replaced by the design note's rules.
##
## THE SEVEN STEPS, in this order, every tick. Within a step seats resolve in
## ASCENDING SLOT ORDER unless the step names another order.
##
##   1. Regrow      every empty pad's timer ticks down; at 0 a raw token appears
##   2. Intent      the kernel derives each cog's single action (see kernel.nim)
##   3. Consume     score t0+t1+t2, zero the inventory -- BEFORE gifts, so a
##                  token beamed at you this tick lands after your cash-out
##   4. Gift beams  resolved against the LIVE state, in slot order
##   5. Collect     take the loose raw token under you
##   6. Move        against the live board; a cell a lower slot already moved
##                  into this tick counts as occupied
##   7. Record      append the frame, the events and the tokens-in-play row;
##                  on the final tick every cog autobanks BEFORE recording

import std/[json, strutils]

import ./sim_types, ./sim_config, ./board, ./events, ./ledger, ./orders

type
  EndReason* = enum
    erComplete = "complete"
    erDeadline = "deadline"
    erForfeit = "forfeit"

  EndEnding* = enum
    eeRoundLimit = "round_limit"
    eeDeadline = "deadline"
    eeForfeit = "forfeit"

  CogPeer* = object
    ## One other cog as this seat sees it. Every field is public knowledge:
    ## positions, scores, consumptions and every gift ever fired. INVENTORIES
    ## ARE NOT HERE and never will be -- that is what makes a promise-free
    ## trust game playable.
    slot*: int
    alias*: string
    x*, y*: int
    dist*: int
    hittable*: bool
    dir*: string
    score*: int
    youGave*, gaveYou*, net*: int
    gaveYouLastRound*: int
    lastGaveYouRound*: int
    bankedLastRound*: int

  RoundRow* = object
    round*, collected*, sent*, received*, banked*, heldAfter*, score*: int

  SeatView* = object
    ## The observation one seat gets at a round boundary. `decide.nim` renders
    ## it into the user prompt and `scripted.nim` decides from it directly --
    ## the two policy kinds see EXACTLY the same thing.
    slot*: int
    alias*: string
    round*, rounds*, roundsLeft*, ticksPerRound*, tick*: int
    variant*: string
    x*, y*: int
    tokens*: array[3, int]
    held*: int
    rawestLevel*: int
    score*: int
    beamsPerRound*: int
    invCap*, giftMultiplier*, maxLevel*: int
    hasLastOrder*: bool
    lastOrder*: Order
    peers*: seq[CogPeer]
    loose*: seq[tuple[x, y, dist: int]]
    ledgerTail*: seq[tuple[r, fromSeat, toSeat, sent, got, n: int]]
    bankTail*: seq[tuple[r, seat, n: int]]
    history*: seq[RoundRow]
    notes*: string

  Beat* = object
    t*: int
    kind*: string
    n*: int
    seat*: int

  SimServer* = object
    config*: GameConfig
    board*: Board
    cogs*: array[SeatCount, Cog]
    padTimer*: seq[int]         ## 0 = a loose raw token sits on the pad
    occupied*: seq[int]         ## cell index -> slot standing there, or -1
    tick*: int
    round*: int                 ## rounds COMPLETED
    ledger*: Ledger
    events*: seq[GiftEvent]
    frames*: seq[ViewFrame]
    pool*: seq[array[2, int]]   ## [tick, tokens held by all cogs]
    beats*: seq[Beat]
    orders*: array[SeatCount, Order]
    haveOrder*: array[SeatCount, bool]
    history*: array[SeatCount, seq[RoundRow]]
    roundStart*: array[SeatCount, tuple[collected, sent, received, banked, score: int]]
    aliases*: seq[string]
    policyNames*: seq[string]
    finished*: bool
    reason*: EndReason
    ending*: EndEnding
    hash*: uint64
    firstGiftTick*: int
    firstSuperTick*: int
    totalGifts*: int
    totalMinted*: int
    defections*: array[SeatCount, int]
    liveEvents*: seq[GiftEvent] ## events emitted during the tick just stepped

proc seatCount*(sim: SimServer): int = SeatCount

proc totalTicks*(sim: SimServer): int = sim.config.totalTicks()

proc mixHash(hash: var uint64, value: int) =
  hash = hash xor uint64(value + 0x9E37_79B9)
  hash = hash * 0x0000_0100_0000_01B3'u64
  hash = hash xor (hash shr 29)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.config.validate()
  result.board = initBoard(result.config)
  result.padTimer = newSeq[int](result.board.pads.len)
  result.occupied = newSeq[int](Cols * Rows)
  for i in 0 ..< result.occupied.len:
    result.occupied[i] = -1
  result.ledger = initLedger()
  result.hash = 0xCBF2_9CE4_8422_2325'u64
  result.firstGiftTick = -1
  result.firstSuperTick = -1
  result.reason = erComplete
  result.ending = eeRoundLimit
  for slot in 0 ..< SeatCount:
    result.aliases.add(Aliases[slot])
    result.policyNames.add(Aliases[slot])
    result.cogs[slot] = Cog(
      x: SpawnCells[slot][0],
      y: SpawnCells[slot][1],
      beamsLeft: result.config.maxBeamsPerRound
    )
    result.occupied[result.board.index(
      result.cogs[slot].x, result.cogs[slot].y)] = slot
    result.orders[slot] = defaultOrder()
  mixHash(result.hash, result.config.seed)

proc looseCells*(sim: SimServer): seq[Cell] =
  for i, pad in sim.board.pads:
    if sim.padTimer[i] == 0:
      result.add(pad)

proc tokensInPlay*(sim: SimServer): int =
  for slot in 0 ..< SeatCount:
    result += sim.cogs[slot].held()

proc addBeat(sim: var SimServer, t: int, kind: string, n = 0, seat = -1) =
  sim.beats.add(Beat(t: t, kind: kind, n: n, seat: seat))

proc emit(sim: var SimServer, event: GiftEvent) =
  sim.events.add(event)
  sim.liveEvents.add(event)

# ---------------------------------------------------------------------------
#  Step 1 -- regrow
# ---------------------------------------------------------------------------

proc stepRegrow(sim: var SimServer) =
  for i in 0 ..< sim.padTimer.len:
    if sim.padTimer[i] > 0:
      dec sim.padTimer[i]
      if sim.padTimer[i] == 0:
        sim.emit(spawnEvent(sim.tick, sim.board.pads[i].x, sim.board.pads[i].y))

# ---------------------------------------------------------------------------
#  Step 3 -- consume
# ---------------------------------------------------------------------------

proc bank(sim: var SimServer, slot: int, autobanked: bool, at: int) =
  ## `at` is the tick the rows are STAMPED with. It is `sim.tick` everywhere
  ## inside a tick; an early settle passes the last tick the replay actually
  ## carries, because `step()` advances `sim.tick` past the frame it recorded.
  let
    l0 = sim.cogs[slot].tokens[0]
    l1 = sim.cogs[slot].tokens[1]
    l2 = sim.cogs[slot].tokens[2]
    total = l0 + l1 + l2
  sim.cogs[slot].tokens = [0, 0, 0]
  sim.cogs[slot].score += total
  sim.cogs[slot].banked[0] += l0
  sim.cogs[slot].banked[1] += l1
  sim.cogs[slot].banked[2] += l2
  sim.cogs[slot].consumedThisTick = true
  if autobanked:
    sim.emit(autobankEvent(at, slot, total, sim.cogs[slot].score))
    return
  sim.cogs[slot].consumeCd = sim.config.consumeCooldown
  sim.emit(consumeEvent(at, slot, l0, l1, l2, sim.cogs[slot].score))
  # A defection is recorded at the till, not at the beam: taking is not a
  # betrayal until you cash it out and walk.
  for other in sim.ledger.defectionsAt(slot):
    sim.defections[slot] += 1
    sim.emit(defectEvent(at, slot, other))
    sim.addBeat(at, "defect", seat = slot)

proc stepConsume(sim: var SimServer, actions: openArray[Action]) =
  for slot in 0 ..< SeatCount:
    if actions[slot] != actConsume:
      continue
    if sim.cogs[slot].consumeCd > 0 or sim.cogs[slot].held() == 0:
      continue
    sim.bank(slot, autobanked = false, at = sim.tick)

# ---------------------------------------------------------------------------
#  Step 4 -- gift beams
# ---------------------------------------------------------------------------

proc giveTokens(
  sim: var SimServer, slot, level, count: int, cause: string
): int =
  ## Adds `count` tokens of `level` to `slot`, capped at invCap. Returns how
  ## many actually landed; the rest is a `spill`.
  let room = max(0, sim.config.invCap - sim.cogs[slot].tokens[level])
  let landed = min(room, count)
  sim.cogs[slot].tokens[level] += landed
  if landed < count:
    sim.emit(spillEvent(sim.tick, slot, level, count - landed, cause))
  landed

proc stepGifts(sim: var SimServer, actions: openArray[Action]) =
  for slot in 0 ..< SeatCount:
    let action = actions[slot]
    if action notin {actGiftN, actGiftE, actGiftS, actGiftW}:
      continue
    if sim.cogs[slot].giftCd > 0 or sim.cogs[slot].beamsLeft <= 0:
      continue
    let level = sim.cogs[slot].lowestLevel()
    if level < 0:
      continue                       ## a shooter holding zero does not fire
    let dir =
      case action
      of actGiftN: dirN
      of actGiftE: dirE
      of actGiftS: dirS
      else: dirW
    let trace = sim.board.traceBeam(
      sim.cogs[slot].x, sim.cogs[slot].y, dir, sim.config.beamRange,
      sim.occupied)
    sim.cogs[slot].giftCd = sim.config.giftCooldown
    sim.cogs[slot].beamsLeft -= 1
    sim.cogs[slot].firedThisTick = true
    if not trace.hit:
      sim.emit(giftMissEvent(sim.tick, slot, $dir))
      continue
    # 1. spend one token of the LOWEST held level.
    sim.cogs[slot].tokens[level] -= 1
    let
      target = trace.seat
      gotLevel = min(level + 1, sim.config.maxLevel)
      minted =
        if level < sim.config.maxLevel: sim.config.giftMultiplier else: 1
    # The `gift` row is emitted BEFORE the receipt is applied, so any `spill`
    # the receipt causes lands immediately AFTER the gift that caused it. A
    # consumer reading the stream in order can then attribute a spill to the
    # gift above it without guessing (tests/test_ledger.nim rebuilds the whole
    # ledger that way).
    sim.emit(giftEvent(
      sim.tick, slot, target, level, gotLevel, minted,
      sim.cogs[slot].x, sim.cogs[slot].y, trace.x, trace.y, trace.dist))
    let landed = sim.giveTokens(target, gotLevel, minted, "gift")
    sim.cogs[slot].giftsSent += 1
    sim.cogs[slot].tokensGiven += 1
    sim.cogs[target].giftsReceived += 1
    sim.cogs[target].tokensReceived += landed
    sim.totalGifts += 1
    sim.totalMinted += minted
    sim.ledger.recordGift(slot, target, 1, landed, sim.round + 1)
    if sim.firstGiftTick < 0:
      sim.firstGiftTick = sim.tick
      sim.addBeat(sim.tick, "firstgift")
    if gotLevel >= 2 and sim.firstSuperTick < 0 and landed > 0:
      sim.firstSuperTick = sim.tick
      sim.addBeat(sim.tick, "super")

# ---------------------------------------------------------------------------
#  Step 5 -- collect
# ---------------------------------------------------------------------------

proc stepCollect(sim: var SimServer, actions: openArray[Action]) =
  for slot in 0 ..< SeatCount:
    if actions[slot] != actCollect or sim.cogs[slot].collectCd > 0:
      continue
    let padIndex =
      sim.board.padAt[sim.board.index(sim.cogs[slot].x, sim.cogs[slot].y)]
    if padIndex < 0 or sim.padTimer[padIndex] != 0:
      continue
    if sim.cogs[slot].tokens[0] >= sim.config.invCap:
      sim.emit(spillEvent(sim.tick, slot, 0, 1, "collect"))
      continue
    sim.cogs[slot].tokens[0] += 1
    sim.cogs[slot].collected += 1
    sim.cogs[slot].collectCd = sim.config.collectCooldown
    sim.cogs[slot].collectedThisTick = true
    sim.padTimer[padIndex] = sim.config.spawnTicks
    sim.emit(collectEvent(sim.tick, slot, sim.cogs[slot].x, sim.cogs[slot].y))

# ---------------------------------------------------------------------------
#  Step 6 -- move
# ---------------------------------------------------------------------------

proc stepMove(sim: var SimServer, actions: openArray[Action]) =
  for slot in 0 ..< SeatCount:
    let action = actions[slot]
    if action notin {actMoveN, actMoveE, actMoveS, actMoveW}:
      continue
    if sim.cogs[slot].moveCd > 0:
      continue
    let delta = dirDelta(
      case action
      of actMoveN: dirN
      of actMoveE: dirE
      of actMoveS: dirS
      else: dirW)
    let
      nx = sim.cogs[slot].x + delta.dx
      ny = sim.cogs[slot].y + delta.dy
    if not sim.board.passable(nx, ny):
      continue                       ## an illegal move degrades to wait
    if sim.occupied[sim.board.index(nx, ny)] >= 0:
      continue
    sim.occupied[sim.board.index(sim.cogs[slot].x, sim.cogs[slot].y)] = -1
    sim.cogs[slot].x = nx
    sim.cogs[slot].y = ny
    sim.occupied[sim.board.index(nx, ny)] = slot
    sim.cogs[slot].moveCd = sim.config.moveCooldown

# ---------------------------------------------------------------------------
#  Step 7 -- record
# ---------------------------------------------------------------------------

proc captureFrame(sim: var SimServer) =
  var frame = ViewFrame(tick: sim.tick)
  for slot in 0 ..< SeatCount:
    var flags = 0
    if sim.cogs[slot].consumedThisTick: flags = flags or 1
    if sim.cogs[slot].firedThisTick: flags = flags or 2
    if sim.cogs[slot].collectedThisTick: flags = flags or 4
    frame.cogs[slot] = ViewCog(
      x: sim.cogs[slot].x,
      y: sim.cogs[slot].y,
      tokens: sim.cogs[slot].tokens,
      score: sim.cogs[slot].score,
      flags: flags
    )
    mixHash(sim.hash, sim.cogs[slot].x)
    mixHash(sim.hash, sim.cogs[slot].y)
    mixHash(sim.hash, sim.cogs[slot].tokens[0])
    mixHash(sim.hash, sim.cogs[slot].tokens[1])
    mixHash(sim.hash, sim.cogs[slot].tokens[2])
    mixHash(sim.hash, sim.cogs[slot].score)
    mixHash(sim.hash, flags)
  for i in 0 ..< sim.padTimer.len:
    frame.pads.add(sim.padTimer[i] == 0)
    mixHash(sim.hash, sim.padTimer[i])
  sim.frames.add(frame)
  sim.pool.add([sim.tick, sim.tokensInPlay()])

proc autobankAll*(sim: var SimServer, at = -1) =
  ## The market closes and everyone cashes out. Counted into `scores` exactly
  ## like a `consume`, so a seat that forgets to bank never scores 0 -- and no
  ## mid-game trust decision is touched. `at` overrides the tick the rows are
  ## stamped with; see `settleEarly`.
  let stamp = if at >= 0: at else: sim.tick
  for slot in 0 ..< SeatCount:
    if sim.cogs[slot].held() > 0:
      sim.bank(slot, autobanked = true, at = stamp)

proc settleEarly*(sim: var SimServer) =
  ## An episode that stops before its last scheduled tick (the play deadline,
  ## or fewer rounds than configured) still settles: everybody cashes out so
  ## the rounds actually played are scored honestly.
  ##
  ## The rows are stamped with the LAST RECORDED FRAME's tick, not `sim.tick`.
  ## `step()` records the frame and THEN advances `sim.tick`, so a settle after
  ## the loop that used `sim.tick` would place every `autobank` one tick past
  ## `frames[^1]` -- an index `parseReplay`'s tick -> events map hands to a
  ## playhead that can never reach it, so the closing cash-out would draw no
  ## burst and no feed row and `BroadcastTracker.resync(.., maxTick)` would
  ## never fold it, while `results.scores` counted it (r1 review F1).
  let settleTick = if sim.frames.len > 0: sim.frames[^1].tick else: 0
  sim.autobankAll(at = settleTick)

proc step*(sim: var SimServer, actions: openArray[Action]) =
  ## One tick, steps 1 and 3..7 (step 2, the kernel, is the caller's -- see
  ## kernel.nim, which is what supplies `actions`).
  doAssert actions.len == SeatCount
  sim.liveEvents.setLen(0)
  for slot in 0 ..< SeatCount:
    sim.cogs[slot].consumedThisTick = false
    sim.cogs[slot].firedThisTick = false
    sim.cogs[slot].collectedThisTick = false
  sim.stepRegrow()
  sim.stepConsume(actions)
  sim.stepGifts(actions)
  sim.stepCollect(actions)
  sim.stepMove(actions)
  let last = sim.totalTicks() - 1
  if sim.tick >= last:
    sim.autobankAll()
  sim.captureFrame()
  for slot in 0 ..< SeatCount:
    if sim.cogs[slot].moveCd > 0: dec sim.cogs[slot].moveCd
    if sim.cogs[slot].collectCd > 0: dec sim.cogs[slot].collectCd
    if sim.cogs[slot].giftCd > 0: dec sim.cogs[slot].giftCd
    if sim.cogs[slot].consumeCd > 0: dec sim.cogs[slot].consumeCd
  inc sim.tick

# ---------------------------------------------------------------------------
#  Round accounting
# ---------------------------------------------------------------------------

proc closeRound*(sim: var SimServer) =
  ## Closes the round accounting and emits `round`. Called at a round boundary
  ## (tick mod ticksPerRound == 0, tick > 0) by the server's round loop.
  var
    scores: seq[int] = @[]
    heldPer: seq[int] = @[]
  for slot in 0 ..< SeatCount:
    let start = sim.roundStart[slot]
    sim.history[slot].add(RoundRow(
      round: sim.round + 1,
      collected: sim.cogs[slot].collected - start.collected,
      sent: sim.cogs[slot].tokensGiven - start.sent,
      received: sim.cogs[slot].tokensReceived - start.received,
      banked: sim.cogs[slot].score - start.banked,
      heldAfter: sim.cogs[slot].held(),
      score: sim.cogs[slot].score
    ))
    sim.roundStart[slot] = (
      sim.cogs[slot].collected, sim.cogs[slot].tokensGiven,
      sim.cogs[slot].tokensReceived, sim.cogs[slot].score,
      sim.cogs[slot].score)
    sim.cogs[slot].beamsLeft = sim.config.maxBeamsPerRound
    scores.add(sim.cogs[slot].score)
    heldPer.add(sim.cogs[slot].held())
  sim.ledger.closeRound()
  inc sim.round
  var banked = 0
  for slot in 0 ..< SeatCount:
    banked += sim.cogs[slot].score
  # The close lands on the LAST TICK OF THE ROUND, not on the first tick of
  # the next one: `sim.tick` has already advanced past the frame that was
  # recorded, and an event outside `0 .. ticksPlayed` is unplaceable on the
  # scrubber and unindexable by the viewer (tests/test_replay.nim).
  let closeTick = max(0, sim.tick - 1)
  sim.emit(GiftEvent(
    kind: evRound, t: closeTick, round: sim.round, scores: scores,
    heldPer: heldPer, gifts: sim.totalGifts, minted: sim.totalMinted,
    banked: banked))
  sim.addBeat(closeTick, "round", n = sim.round)

proc finish*(sim: var SimServer, reason: EndReason) =
  ## Terminal bookkeeping: settle, emit `end`, and place the `gameover` beat at
  ## the final tick so the scrubber's right edge always reaches the endcard
  ## (territory, 2026-08-25).
  if sim.finished:
    return
  sim.finished = true
  # A forfeit (nobody connected) and a deadline reached before the first tick
  # both stop before any frame is recorded, and a replay with `frames: []` is
  # one this repo's OWN parser rejects ("replay has no frames",
  # replays.nim) -- the shipped viewer would show `data-replay-error` where the
  # note asks for "results + replay are still written". Record the opening
  # position so every legal `results.reason` writes a playable replay
  # (r1 review F2).
  if sim.frames.len == 0:
    sim.captureFrame()
  sim.reason = reason
  sim.ending =
    case reason
    of erComplete: eeRoundLimit
    of erDeadline: eeDeadline
    of erForfeit: eeForfeit
  var scores: seq[int] = @[]
  for slot in 0 ..< SeatCount:
    scores.add(sim.cogs[slot].score)
  let terminal = max(0, sim.tick - 1)
  sim.emit(GiftEvent(
    kind: evEnd, t: terminal, reason: $reason, ending: $sim.ending,
    scores: scores))
  sim.addBeat(terminal, "gameover")

# ---------------------------------------------------------------------------
#  The observation
# ---------------------------------------------------------------------------

proc bankedLastRound(sim: SimServer, slot: int): int =
  if sim.history[slot].len == 0: 0 else: sim.history[slot][^1].banked

proc seatView*(sim: SimServer, slot: int): SeatView =
  ## Everything this seat may legitimately know, and NOTHING else. Positions,
  ## scores, consumptions and every gift ever fired are public; inventories are
  ## private. No policy name, player name, account or model name is ever in
  ## here -- cogs are `Aro` .. `Fay` and nothing else.
  result.slot = slot
  result.alias = sim.aliases[slot]
  result.round = sim.round + 1
  result.rounds = sim.config.rounds
  result.roundsLeft = max(0, sim.config.rounds - sim.round)
  result.ticksPerRound = sim.config.ticksPerRound
  result.tick = sim.tick
  result.variant = sim.config.variant
  result.x = sim.cogs[slot].x
  result.y = sim.cogs[slot].y
  result.tokens = sim.cogs[slot].tokens
  result.held = sim.cogs[slot].held()
  result.rawestLevel = sim.cogs[slot].lowestLevel()
  result.score = sim.cogs[slot].score
  result.beamsPerRound = sim.config.maxBeamsPerRound
  result.invCap = sim.config.invCap
  result.giftMultiplier = sim.config.giftMultiplier
  result.maxLevel = sim.config.maxLevel
  result.hasLastOrder = sim.haveOrder[slot]
  result.lastOrder = sim.orders[slot]
  result.notes = sim.orders[slot].notes

  let field = sim.board.distanceField(sim.cogs[slot].x, sim.cogs[slot].y)
  for other in 0 ..< SeatCount:
    if other == slot:
      continue
    let shot = sim.board.hittable(
      sim.cogs[slot].x, sim.cogs[slot].y, sim.cogs[other].x, sim.cogs[other].y,
      sim.config.beamRange, sim.occupied)
    let raw = field[sim.board.index(sim.cogs[other].x, sim.cogs[other].y)]
    result.peers.add(CogPeer(
      slot: other,
      alias: sim.aliases[other],
      x: sim.cogs[other].x,
      y: sim.cogs[other].y,
      dist: (if raw >= 0: raw else: -1),
      hittable: shot.ok,
      dir: (if shot.ok: $shot.dir else: ""),
      score: sim.cogs[other].score,
      youGave: sim.ledger.youGave(slot, other),
      gaveYou: sim.ledger.gaveYou(slot, other),
      net: sim.ledger.net(slot, other),
      gaveYouLastRound: sim.ledger.roundGot[slot][other],
      lastGaveYouRound: sim.ledger.lastRound[other][slot],
      bankedLastRound: sim.bankedLastRound(other)))

  var loose: seq[tuple[x, y, dist: int]] = @[]
  for pad in sim.looseCells():
    let d = field[sim.board.index(pad.x, pad.y)]
    loose.add((pad.x, pad.y, (if d >= 0: d else: 999)))
  # nearest first, ties by (y, x): a deterministic list the prompt can quote.
  for i in 1 ..< loose.len:
    let key = loose[i]
    var j = i - 1
    while j >= 0 and (loose[j].dist > key.dist or
        (loose[j].dist == key.dist and
          (loose[j].y > key.y or (loose[j].y == key.y and loose[j].x > key.x)))):
      loose[j + 1] = loose[j]
      dec j
    loose[j + 1] = key
  result.loose = loose

  # The last 16 gifts and the last 8 consumes on the WHOLE board, oldest first.
  var gifts: seq[tuple[r, fromSeat, toSeat, sent, got, n: int]] = @[]
  var banks: seq[tuple[r, seat, n: int]] = @[]
  for event in sim.events:
    case event.kind
    of evGift:
      gifts.add((event.t div max(1, sim.config.ticksPerRound) + 1,
                 event.fromSeat, event.toSeat, event.sent, event.got, event.n))
    of evConsume, evAutobank:
      banks.add((event.t div max(1, sim.config.ticksPerRound) + 1,
                 event.seat, event.n))
    else: discard
  if gifts.len > 16:
    gifts = gifts[^16 .. ^1]
  if banks.len > 8:
    banks = banks[^8 .. ^1]
  result.ledgerTail = gifts
  result.bankTail = banks
  result.history = sim.history[slot]

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

proc resultsJson*(sim: SimServer): JsonNode =
  ## The `results.json` document. `names` are POLICY names (platform side);
  ## the aliases the seats saw ride alongside and into the replay's `names[]`.
  ## Arrays are indexed by slot and always length 6.
  var
    scores, collected, giftsSent, giftsReceived: seq[int] = @[]
    tokensGiven, tokensReceived: seq[int] = @[]
    bankedRaw, bankedRefined, bankedSuper: seq[int] = @[]
    defections, reciprocity: seq[int] = @[]
    win: seq[bool] = @[]
  var best = 0
  for slot in 0 ..< SeatCount:
    best = max(best, sim.cogs[slot].score)
  for slot in 0 ..< SeatCount:
    let cog = sim.cogs[slot]
    scores.add(cog.score)
    win.add(cog.score == best)
    collected.add(cog.collected)
    giftsSent.add(cog.giftsSent)
    giftsReceived.add(cog.giftsReceived)
    tokensGiven.add(cog.tokensGiven)
    tokensReceived.add(cog.tokensReceived)
    bankedRaw.add(cog.banked[0])
    bankedRefined.add(cog.banked[1])
    bankedSuper.add(cog.banked[2])
    defections.add(sim.defections[slot])
    reciprocity.add(reciprocityX100(cog.tokensGiven, cog.tokensReceived))
  %*{
    "names": sim.policyNames,
    "aliases": sim.aliases,
    "scores": scores,
    "win": win,
    "collected": collected,
    "gifts_sent": giftsSent,
    "gifts_received": giftsReceived,
    "tokens_given": tokensGiven,
    "tokens_received": tokensReceived,
    "banked_raw": bankedRaw,
    "banked_refined": bankedRefined,
    "banked_super": bankedSuper,
    "defections": defections,
    "reciprocity_x100": reciprocity,
    "total_gifts": sim.totalGifts,
    "total_minted": sim.totalMinted,
    "rounds": sim.round,
    "reason": $sim.reason,
    "ending": $sim.ending
  }

proc scene*(sim: SimServer): Scene =
  ## The static half of what the renderer needs. Built once by the live server
  ## and rebuilt from the replay bytes alone by the wasm viewer.
  result = Scene(
    cols: Cols, rows: Rows, cell: CellPx,
    variant: sim.config.variant,
    walls: sim.board.wallCells(),
    pads: sim.board.pads,
    spawns: sim.board.spawns,
    names: sim.aliases,
    policyNames: sim.policyNames,
    colors: @[],
    rounds: sim.config.rounds,
    ticksPerRound: sim.config.ticksPerRound,
    maxLevel: sim.config.maxLevel,
    giftMultiplier: sim.config.giftMultiplier,
    invCap: sim.config.invCap,
    beamRange: sim.config.beamRange,
    giftCooldown: sim.config.giftCooldown,
    maxBeamsPerRound: sim.config.maxBeamsPerRound,
    collectCooldown: sim.config.collectCooldown,
    moveCooldown: sim.config.moveCooldown,
    consumeCooldown: sim.config.consumeCooldown,
    spawnTicks: sim.config.spawnTicks
  )
  for colour in SeatColors:
    result.colors.add(colour)

proc gameHashHex*(sim: SimServer): string =
  ## The determinism handle `tests/test_sim.nim` compares across two runs in
  ## one process and across a fresh server.
  toHex(sim.hash)

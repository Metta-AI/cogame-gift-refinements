## The decision layer: one batched round of asking six seats what their cog
## does next, and always having an answer.
##
## Forked from `coworld-ctf/src/ctf/decide.nim`.
##
## CADENCE. One turn = one round = 60 ticks. At each round boundary the game
## builds ALL SIX seats' request bodies and issues them as ONE PARALLEL BATCH
## (`curly.makeRequests`) -- never sequentially, never one seat at a time. The
## single retry is likewise ONE batch, of only the seats that failed, and it is
## issued only after the first batch has resolved.
##
##   per round:   1 batch of 6, attempt1Ms = 20 s
##                + at most 1 retry batch of the failed seats, retryMs = 12 s
##                turnBudgetMs = 34 s caps the whole turn
##   worst case:  12 x 34 s = 408 s + sim 0.4 s + connect <= 30 s
##                + shutdown 20 s  =  ~459 s  <  720 s (0.6 x 1200)
##   typical:     max(minTurnSeconds 25, ~7 s) x 12  ~  300 s
##
## `minTurnSeconds` floors the spacing between BATCH STARTS, so the worst case
## is 12 requests / 25 s = 28.8 rpm, under the Bedrock sidecar's 30 rpm
## per-episode ceiling that bit cogame-raid.
##
## DEGRADE, NEVER HANG. `turn` never raises: every failure path ends in a legal
## order and the episode always advances. No tick is left unactuated -- the
## kernel always has an order: this round's, else last round's, else
## `reciprocator`'s.

import std/[json, monotimes, os, strutils, times]

import curly

import ./sim_types, ./sim_config, ./sim, ./orders, ./scripted, ./llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field --
    ## or never registers at all -- is `reciprocator`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: array[SeatCount, SeatPolicy]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    fallbacks*: int
    llmOrders*: int

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  for slot in 0 ..< SeatCount:
    result.seats[slot].baseline = blReciprocator
    result.seats[slot].label = "reciprocator"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < SeatCount and engine.seats[seat].isLlm: "llm"
  else: "scripted"

# ---------------------------------------------------------------------------
#  The observation
# ---------------------------------------------------------------------------

proc observationJson*(view: SeatView, scene: Scene): JsonNode =
  ## The `state` frame, and the same object rendered into the user prompt.
  ## VISIBLE: your cell, your three token counts, your lowest held level, your
  ## score, your beam budget, your last order; for EVERY other cog its alias,
  ## slot, cell, distance, whether it is hittable right now and in which
  ## direction, its score, the running youGave/gaveYou/net counts between you
  ## and it, the round it last gave to you, and what it banked last round;
  ## every loose raw token; the global gift ledger and bank tape; your own
  ## per-round history; your private notes; and the rule block.
  ## HIDDEN: every other cog's INVENTORY, its order, its notes, its prompt, its
  ## policy name, the seed, and pad regrow timers you are not standing on.
  var cogs = newJArray()
  for peer in view.peers:
    cogs.add(%*{
      "alias": peer.alias,
      "slot": peer.slot,
      "cell": [peer.x, peer.y],
      "dist": peer.dist,
      "hittable": peer.hittable,
      "dir": (if peer.dir.len > 0: %peer.dir else: newJNull()),
      "score": peer.score,
      "youGave": peer.youGave,
      "gaveYou": peer.gaveYou,
      "net": peer.net,
      "lastGaveYouRound":
        (if peer.lastGaveYouRound >= 0: %peer.lastGaveYouRound else: newJNull()),
      "bankedLastRound": peer.bankedLastRound
    })
  var loose = newJArray()
  for item in view.loose:
    loose.add(%*{"cell": [item.x, item.y], "dist": item.dist})
  var ledger = newJArray()
  for row in view.ledgerTail:
    ledger.add(%*{
      "r": row.r,
      "from": scene.names[row.fromSeat],
      "to": scene.names[row.toSeat],
      "sent": LevelNames[row.sent],
      "got": LevelNames[row.got],
      "n": row.n
    })
  var banks = newJArray()
  for row in view.bankTail:
    banks.add(%*{"r": row.r, "who": scene.names[row.seat], "n": row.n})
  var history = newJArray()
  for row in view.history:
    history.add(%*{
      "round": row.round, "collected": row.collected, "sent": row.sent,
      "received": row.received, "banked": row.banked, "held": row.heldAfter,
      "score": row.score
    })
  var lastOrder = newJNull()
  if view.hasLastOrder:
    lastOrder = %*{
      "job": $view.lastOrder.job,
      "target": (if view.lastOrder.target >= 0:
                   %scene.names[view.lastOrder.target] else: newJNull()),
      "gift": view.lastOrder.gift,
      "consume": $view.lastOrder.consume,
      "source": $view.lastOrder.source
    }
  %*{
    "type": "state",
    "protocol": PlayerProtocol,
    "slot": view.slot,
    "name": view.alias,
    "round": view.round,
    "rounds": view.rounds,
    "roundsLeft": view.roundsLeft,
    "ticksPerRound": view.ticksPerRound,
    "tick": view.tick,
    "board": {
      "cols": scene.cols, "rows": scene.rows, "variant": view.variant,
      "pads": scene.pads.len, "beamRange": scene.beamRange
    },
    "you": {
      "cell": [view.x, view.y],
      "tokens": {"raw": view.tokens[0], "refined": view.tokens[1],
                 "super": view.tokens[2]},
      "held": view.held,
      "rawestLevel": view.rawestLevel,
      "score": view.score,
      "beamsPerRound": view.beamsPerRound,
      "lastOrder": lastOrder
    },
    "cogs": cogs,
    "loose": loose,
    "ledger": ledger,
    "banks": banks,
    "history": history,
    "notes": view.notes,
    "rules": {
      "scoring": "+1 for every token you consume, whatever its refinement; " &
        "higher is better",
      "gift": "a beam spends ONE token of your LOWEST level and gives the " &
        "target THREE of the next level; a super token passes through as one " &
        "super token",
      "rawestFirst": "while you hold any raw token, every beam you fire sends " &
        "a raw token \u2014 bank or spend your raw before you can hand back " &
        "refined stock",
      "beam": "range " & $scene.beamRange & " cells, straight N/E/S/W, " &
        "blocked by walls, pillars and other cogs; a miss costs nothing",
      "cap": $scene.invCap & " tokens per level; anything over is lost",
      "close": "at the last tick of round " & $scene.rounds & " everything " &
        "you still hold is banked automatically",
      "budget": {
        "beamsPerRound": scene.maxBeamsPerRound,
        "giftCooldown": scene.giftCooldown,
        "collectCooldown": scene.collectCooldown,
        "moveCooldown": scene.moveCooldown
      },
      "silence": "there is no talk channel; the only signal you can send is a " &
        "beam and where you stand"
    }
  }

proc systemPrompt*(view: SeatView, scene: Scene): string =
  ## Composed per seat, per round. The gift rule is stated THREE times -- once
  ## as the rule, once as the rawest-first warning, once as the worked ladder --
  ## because that is the one rule everything else in this game hangs off.
  let aliasUpper = view.alias.toUpperAscii()
  var others: seq[string] = @[]
  for peer in view.peers:
    others.add(peer.alias)
  result = """
You are """ & aliasUpper & """, one of six cogs on a foundry floor.

THE BOARD. A fixed """ & $scene.cols & " x " & $scene.rows & """ grid: a solid wall ring around
the outside, """ & $((scene.walls.len - 2 * (scene.cols + scene.rows - 2)) div 4) & """ two-by-two stone pillars inside it, and """ & $scene.pads.len & """ seep pads set into the
floor that slowly grow RAW tokens. Walls and pillars stop you walking and stop your beam.

TOKENS. A token has a level: raw (0), refined (1) or super (""" & $scene.maxLevel & """). You hold at most """ & $scene.invCap & """
of each level; anything over that is lost.

CONSUMING pays you +1 for EVERY token you hold, at every level, and empties your hands.
Refinement buys nothing at the till. It only multiplies HOW MANY tokens exist.

GIFTING is a beam, range """ & $scene.beamRange & """ cells, straight north/east/south/west, blocked by walls,
pillars and other cogs. A beam that finds nobody costs you nothing.
  1. THE RULE: a beam spends ONE token of your LOWEST held level and gives the cog it hits
     """ & $scene.giftMultiplier & """ tokens of the NEXT level up. A super token passes through as ONE super token.
  2. RAWEST FIRST: while you hold ANY raw token, every beam you fire sends a raw token. If you
     are sitting on refined stock and want to hand it back, stop collecting and spend or bank
     your raw first.
  3. THE LADDER: you collect one raw and beam it to a partner - they now hold three refined.
     They beam those three back, one at a time - you now hold nine super. A super beam moves
     one token, which is how the two of you split the pile. One raw token, eight beams, nine
     points. And at every single step the holder can simply consume and walk behind a pillar.

THE CLOSE. At the last tick of round """ & $scene.rounds & """, everything you still hold is banked automatically.

HOW YOU PLAY. You do not steer tick by tick. Once per round you choose ONE standing order for
the next """ & $scene.ticksPerRound & """ ticks and a deterministic kernel walks and beams it for you:
  job "collect" - walk to the nearest loose raw token and pick it up.
  job "meet"    - walk to the nearest cell from which `target` is in beam line, and wait there.
  job "hold"    - stay put. Beams still fire when someone walks into line.
  job "evade"   - walk as far from every other cog as the board allows.
  gift N        - fire up to N beams at `target` this round, whenever it is in line.
  consume       - "now" banks on the round's first tick, "end" on its last, "never" not at all.

THE OTHER FIVE. """ & others.join(", ") & """ are other policies, deciding at the SAME
moment you are. NOBODY CAN HEAR ANYTHING YOU SAY - there is no talk channel in this world. The
only signals you can send are a beam and where you choose to stand. Your `notes` field is
private to you and comes back to you next round; nobody else ever sees it.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no explanation, no
markdown fences, no text before or after the object. Your reply must begin with the character {
and end with }."""

proc userPrompt*(view: SeatView, scene: Scene, operatorPrompt: string): string =
  ## The observation rendered compactly, then the operator block, then a
  ## one-line restatement of the reply shape WITH the legal enum values for
  ## this variant -- precomputing the legal choice set is what halved
  ## formal-output fallbacks in escrow.
  var lines: seq[string] = @[]
  lines.add("ROUND " & $view.round & " / " & $view.rounds & "   (tick " &
    $view.tick & " of " & $(view.rounds * view.ticksPerRound) & ")")
  lines.add("")
  lines.add("YOU  " & view.alias.toUpperAscii() & "  at (" & $view.x & "," &
    $view.y & ")")
  lines.add("  holding: " & $view.tokens[0] & " raw, " & $view.tokens[1] &
    " refined, " & $view.tokens[2] & " super  (" & $view.held & " tokens)")
  lines.add("  your lowest held level: " &
    (if view.rawestLevel < 0: "nothing in hand"
     else: LevelNames[view.rawestLevel] & " \u2014 every beam you fire sends " &
       LevelNames[view.rawestLevel]))
  lines.add("  banked so far: " & $view.score & "   beams per round: " &
    $view.beamsPerRound)
  lines.add("")
  lines.add("COGS  alias | cell | dist | hittable | score | you gave | gave you | net")
  for peer in view.peers:
    lines.add("  " & peer.alias.toUpperAscii() & " | (" & $peer.x & "," &
      $peer.y & ") | " & $peer.dist & " | " &
      (if peer.hittable: "YES " & peer.dir else: "no") & " | " & $peer.score &
      " | " & $peer.youGave & " | " & $peer.gaveYou & " | " & $peer.net)
  lines.add("")
  if view.loose.len == 0:
    lines.add("LOOSE RAW TOKENS  none on the board right now")
  else:
    var cells: seq[string] = @[]
    for item in view.loose:
      cells.add("(" & $item.x & "," & $item.y & ") d" & $item.dist)
    lines.add("LOOSE RAW TOKENS  " & cells.join("  "))
  lines.add("")
  if view.ledgerTail.len == 0:
    lines.add("GIFT LEDGER  nothing has been given yet")
  else:
    lines.add("GIFT LEDGER (whole board, most recent last)")
    for row in view.ledgerTail:
      lines.add("  r" & $row.r & "  " &
        scene.names[row.fromSeat].toUpperAscii() & " \u2192 " &
        scene.names[row.toSeat].toUpperAscii() & "  " & LevelNames[row.sent] &
        " \u2192 " & $row.n & " " & LevelNames[row.got])
  lines.add("")
  if view.bankTail.len > 0:
    lines.add("BANK TAPE")
    for row in view.bankTail:
      lines.add("  r" & $row.r & "  " & scene.names[row.seat].toUpperAscii() &
        " banked " & $row.n)
    lines.add("")
  if view.history.len > 0:
    lines.add("YOUR ROUNDS  round | collected | sent | received | banked | held")
    for row in view.history:
      lines.add("  " & $row.round & " | " & $row.collected & " | " & $row.sent &
        " | " & $row.received & " | " & $row.banked & " | " & $row.heldAfter)
    lines.add("")
  lines.add("YOUR NOTES FROM LAST ROUND")
  lines.add("  " & (if view.notes.len > 0: view.notes else: "(none)"))
  lines.add("")
  var aliasList: seq[string] = @[]
  for peer in view.peers:
    aliasList.add("\"" & peer.alias & "\"")
  result = lines.join("\n") & "\n\n" & operatorBlock(operatorPrompt) &
    "Reply with ONE JSON object: {\"job\":\"collect|meet|hold|evade\"," &
    "\"target\":" & aliasList.join("|") & "|null," &
    "\"gift\":0-" & $view.beamsPerRound & "," &
    "\"consume\":\"now|end|never\"," &
    "\"say\":\"<= " & $MaxSayRunes & " chars, spectators only\"," &
    "\"notes\":\"<= " & $MaxNotesRunes & " chars, private to you\"}"

# ---------------------------------------------------------------------------
#  Fallback + guard records
# ---------------------------------------------------------------------------

proc fallbackRecord*(round, seat, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback", "round": round, "seat": seat, "attempt": attempt,
    "cause": cause, "detail": detail.cleanText(MaxFallbackDetailRunes)
  })

proc budgetGuardRecord*(round, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "round": round, "remaining_s": remainingSeconds})

proc registerRecord*(seat: int, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is never written: only
  ## the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register", "seat": seat,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline
  })

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

const RetryHint = "\n\nYour previous reply was invalid. Respond with ONLY the " &
  "requested JSON object, using one of the listed job values, one of the " &
  "listed target aliases, a gift count between 0 and 10, and one of " &
  "now/end/never."

proc scriptedFor*(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): Order =
  scriptedOrder(kind, sim.seatView(seat), sim.config.maxBeamsPerRound)

proc repairMissingOrders*(engine: DecisionEngine, sim: var SimServer) =
  ## No tick is ever left unactuated: a seat with no order at all plays the
  ## `reciprocator` order rather than standing still.
  for seat in 0 ..< SeatCount:
    if not sim.haveOrder[seat]:
      var order = reciprocatorOrder(sim.seatView(seat),
                                    sim.config.maxBeamsPerRound)
      order.source = osFallback
      sim.orders[seat] = order
      sim.haveOrder[seat] = true

proc installOrder(sim: var SimServer, seat: int, order: Order) =
  sim.orders[seat] = order
  sim.haveOrder[seat] = true

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  roundIndex, elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision round and installs each seat's standing order. Returns
  ## the log records this round produced. NEVER RAISES.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER ROUND: a 429 on round k says nothing about round
  ## k+1 (the sidecar's window may have rolled), so the flag is cleared here
  ## and only suppresses this round's retry.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let roundSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * roundSeconds > sim.config.playDeadlineSeconds():
      engine.llmOff = true
      result.add(budgetGuardRecord(roundIndex,
        max(0, sim.config.playDeadlineSeconds() - elapsedSeconds)))
      echo "gift-refinements: budget guard fired at round ", roundIndex,
        "; the remaining rounds play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int] = @[]
  for seat in 0 ..< SeatCount:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      var order = reciprocatorOrder(sim.seatView(seat),
                                    sim.config.maxBeamsPerRound)
      order.source = osFallback
      sim.installOrder(seat, order)
      engine.fallbacks += 1
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(roundIndex, seat, 1, cause,
        "the LLM is unavailable for this round; playing reciprocator"))
      echo LogPrefix, "seat ", seat, " falling back to scripted order (",
        cause, ") on round ", roundIndex
    else:
      var order = engine.scriptedFor(sim, seat, engine.seats[seat].baseline)
      order.source = osScripted
      sim.installOrder(seat, order)

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE. Holding the START
  # of consecutive batches `minTurnSeconds` apart pins the worst case (6 + 6
  # retries) at 28.8 rpm. The cert fixture sets it to 0, so offline runs pay
  # nothing. It is applied at the TOP of `turn`, which `server.nim` calls before
  # the round's ticks, and it is measured between batch STARTS -- so the ticks
  # of the round just played count against the floor and a round costs
  # `max(minTurnSeconds, batch)`, never their sum (r1 review A1).
  if open.len > 0 and engine.batchStarted and sim.config.minTurnSeconds > 0:
    let
      spacingMs = sim.config.minTurnSeconds * 1000
      since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < spacingMs:
      sleep(spacingMs - since)
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  let scene = sim.scene()

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(roundIndex, seat, attempt + 1, "timeout",
          "per-round budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      let view = sim.seatView(seat)
      var user = userPrompt(view, scene, engine.seats[seat].prompt)
      if attempt > 0:
        user.add(RetryHint)
      let request = engine.client.requestFor(systemPrompt(view, scene), user)
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS. sim_config REJECTS a sub-second
    # value, so the floor below is an identity: 20000 -> 20 s, 12000 -> 12 s,
    # worst case 32 s inside the 34 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int] = @[]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var order = parseOrder(
          extractJsonObject(text), seat, scene.names,
          sim.config.maxBeamsPerRound)
        order.source = if attempt == 0: osLlm else: osRetry
        order.latencyMs = latency
        sim.installOrder(seat, order)
        engine.llmOrders += 1
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is: reporting a 429 as a
          ## `parse_error` is what made the hosted log unreadable.
          cause = "throttled"
        result.add(fallbackRecord(roundIndex, seat, attempt + 1, cause,
          error.msg))
        echo LogPrefix, "seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the round on the scripted
      # layer instead of on a call that cannot land.
      echo LogPrefix, "provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for round ", roundIndex
      break

  # --- anything still open plays the reciprocator order for this round ------
  for seat in open:
    var order = reciprocatorOrder(sim.seatView(seat),
                                  sim.config.maxBeamsPerRound)
    order.source = osFallback
    sim.installOrder(seat, order)
    engine.fallbacks += 1
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(roundIndex, seat, 2, cause,
      "seat fell back to the reciprocator order"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo LogPrefix, "seat ", seat, " falling back to scripted order (", cause,
      ") on round ", roundIndex

  engine.repairMissingOrders(sim)

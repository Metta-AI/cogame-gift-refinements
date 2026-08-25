## The two published scripted baselines, plus one test-only foil.
##
## Forked from `coworld-ctf/src/ctf/baselines.nim`, and it keeps that file's
## load-bearing property: BOTH KINDS EMIT THE SAME OBJECT an LLM does, on the
## same cadence, decided purely from the observation. That is what makes the
## bounded-orders test in `tests/test_baseline.nim` meaningful and what lets a
## failed LLM decision land on `reciprocator` with no special case anywhere.
##
## `reciprocator` is load-bearing in four places: the league's first filler,
## the certification player, the per-round fallback when a seat's LLM call
## fails twice, and the default for a seat that registers with neither
## PLAYER_PROMPT nor PLAYER_SCRIPTED.

import std/strutils

const MeetThreshold* = 8
  ## How much a reciprocator must be holding before it walks off to stand in
  ## its partner's beam line rather than carrying on collecting.
  ##
  ## The design note's step 2 says "if P exists -> meet P". The threshold is
  ## the implementation of "if P exists" for a bot that also has to feed
  ## itself: `meet` parks a cog in line and WAITS there (kernel.nim), so a cog
  ## that walks over holding two tokens spends four ticks beaming and
  ## fifty-six idle. Standing in line is only worth the round once there is a
  ## real delivery to make. Measured over seeds 1..12 on all four variants
  ## (tests/test_feasibility.nim), 8 is where every gate is furthest from its
  ## floor: at 3 the room fires more beams but banks a third less, and at 12
  ## the chains stop reaching level 2 on `long-beam` at all.

import ./sim_types, ./orders, ./sim

type
  Baseline* = enum
    blReciprocator = "reciprocator"
    blHoarder = "hoarder"
    blLeech = "leech"
      ## TEST ONLY. Accepts everything and never gifts; it exists so
      ## `tests/test_feasibility.nim` gate (c) can show that free-riding is
      ## punished. It is never shipped: `parseBaseline` will not return it and
      ## no manifest player or policy names it.

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `reciprocator`: a seat
  ## that says nothing useful still plays the published default rather than
  ## sitting out. `leech` is deliberately NOT reachable from here.
  case text.strip().toLowerAscii()
  of "hoarder", "hoard": blHoarder
  else: blReciprocator

proc seedTarget(view: SeatView): int =
  ## Who to open with. The NEAREST cog you have not already opened with -- and
  ## if you have opened with all five, the one you have given least to. Seeding
  ## the plain nearest cog every time collapses the room onto two hubs: on this
  ## board two cogs are nearest-neighbour to three others, so they collect
  ## every opening and the cogs behind them never get a chain at all.
  result = -1
  var
    bestGiven = high(int)
    bestDist = high(int)
  for peer in view.peers:
    if peer.dist < 0:
      continue
    if peer.youGave < bestGiven or
        (peer.youGave == bestGiven and peer.dist < bestDist) or
        (peer.youGave == bestGiven and peer.dist == bestDist and
         (result < 0 or peer.slot < result)):
      bestGiven = peer.youGave
      bestDist = peer.dist
      result = peer.slot

proc reciprocatorOrder*(view: SeatView, maxBeams: int): Order =
  ## The always-return bot.
  ##
  ##   1. P = the cog with the largest net = gaveYou - youGave, ties by lowest
  ##      slot; P counts only if net > 0.
  ##   2. P exists AND this cog is holding something -> meet P and return
  ##      min(what P sent last round + 1, held, maxBeams) beams. With EMPTY
  ##      HANDS there is nothing to return, so the rule falls through to 4:
  ##      standing in line holding nothing is how a chain stalls, and the
  ##      rawest-first rule means a returner must stop collecting anyway.
  ##   3. Nobody has ever given to it and it holds >= 2 -> the SEED GIFT: open
  ##      with the nearest cog it has not already opened with. Somebody has to
  ##      go first, and spreading the openings is what stops the room
  ##      collapsing onto two hubs.
  ##   4. Otherwise -> collect.
  result = defaultOrder()
  result.source = osScripted
  result.consume =
    if view.held >= 10 or view.roundsLeft <= 1: cwEnd else: cwNever

  var
    partner = -1
    bestNet = 0
    everReceived = false
    lastFrom = 0
  for peer in view.peers:
    if peer.gaveYou > 0:
      everReceived = true
    if peer.net > bestNet:
      bestNet = peer.net
      partner = peer.slot
      lastFrom = peer.gaveYouLastRound
  if partner >= 0 and bestNet > 0:
    result.target = partner
    result.gift = min(min(lastFrom + 1, view.held), maxBeams)
    # Holding enough to be worth the trip, go and stand in its beam line;
    # otherwise keep collecting and fire opportunistically whenever the
    # partner walks into line (the kernel's beam priority runs ahead of the
    # job's movement, so a `collect` order still returns what it can).
    result.job = if view.held >= MeetThreshold: jobMeet else: jobCollect
    for peer in view.peers:
      if peer.slot == partner:
        result.say =
          if result.gift > 0: "returning " & $result.gift & " to " &
            peer.alias.toUpperAscii()
          else: "collecting for " & peer.alias.toUpperAscii()
    return
  if not everReceived and view.held >= 2:
    let near = seedTarget(view)
    if near >= 0:
      result.job = jobMeet
      result.target = near
      result.gift = min(view.held, maxBeams)
      for peer in view.peers:
        if peer.slot == near:
          result.say = "opening with " & peer.alias.toUpperAscii()
      return
  result.job = jobCollect
  result.target = -1
  result.gift = 0
  result.say = "collecting"

proc hoarderOrder*(view: SeatView): Order =
  ## The never-gift bot, and the foil that makes cooperation legible. It walks
  ## away from everyone the moment there is nothing left to pick up, which is
  ## exactly the behaviour the audience should learn to recognise.
  result = defaultOrder()
  result.source = osScripted
  result.job = if view.loose.len > 0: jobCollect else: jobEvade
  result.target = -1
  result.gift = 0
  result.consume =
    if view.held >= 6 or view.roundsLeft <= 1: cwEnd else: cwNever
  result.say = "mine"

proc leechOrder*(view: SeatView): Order =
  ## TEST ONLY (gate (c)). Stands where it can be gifted, never gifts back, and
  ## banks the moment it is holding anything worth banking.
  result = defaultOrder()
  result.source = osScripted
  result.gift = 0
  result.target = -1
  result.consume =
    if view.held >= 4 or view.roundsLeft <= 1: cwEnd else: cwNever
  var richest = -1
  var best = -1
  for peer in view.peers:
    if peer.score > best:
      best = peer.score
      richest = peer.slot
  if richest >= 0:
    result.job = jobMeet
    result.target = richest
  else:
    result.job = jobCollect
  result.say = "thanks"

proc scriptedOrder*(kind: Baseline, view: SeatView, maxBeams: int): Order =
  case kind
  of blReciprocator: reciprocatorOrder(view, maxBeams)
  of blHoarder: hoarderOrder(view)
  of blLeech: leechOrder(view)

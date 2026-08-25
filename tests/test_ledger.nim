## The trust bookkeeping (design note "## Tests" item 3).
##
## youGave / gaveYou / net exact over a scripted beam sequence; `defect` firing
## exactly once per ordered pair and only at a consume; the reciprocity formula
## on hand-built totals including the both-zero case; and -- the one that makes
## the viewer's seek-accurate trust graph correct -- the ledger rebuilt from
## `events[]` ALONE equalling the live ledger at every round boundary.

import std/[json, strutils]

import ./helpers

suite "ledger"

block youGaveGaveYouNetAreExact:
  var sim = initSimServer(variantConfig("refinery"))
  for slot in 0 ..< SeatCount:
    var order = defaultOrder()
    order.job = jobHold
    order.consume = cwNever
    sim.holdOrder(slot, order)
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [2, 0, 0]
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actGiftE
  sim.step(actions)                 # Aro -> Bex, one raw, three refined land
  for i in 0 ..< SeatCount: actions[i] = actWait
  for _ in 0 ..< DefaultGiftCooldown: sim.step(actions)
  actions[1] = actGiftW
  sim.step(actions)                 # Bex -> Aro, one refined, three super land

  check(sim.ledger.youGave(0, 1) == 1, "Aro's given count is wrong")
  check(sim.ledger.gaveYou(0, 1) == 3, "Aro's received count is wrong")
  check(sim.ledger.net(0, 1) == 2, "Aro's net is wrong")
  check(sim.ledger.youGave(1, 0) == 1, "Bex's given count is wrong")
  check(sim.ledger.gaveYou(1, 0) == 3, "Bex's received count is wrong")
  check(sim.ledger.net(1, 0) == 2, "Bex's net is wrong")
  banner "youGave / gaveYou / net are exact over a scripted beam sequence"

block defectFiresOnceAtTheTill:
  var sim = initSimServer(variantConfig("refinery"))
  for slot in 0 ..< SeatCount:
    var order = defaultOrder()
    order.job = jobHold
    order.consume = cwNever
    sim.holdOrder(slot, order)
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [3, 0, 0]
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actGiftE
  sim.step(actions)
  check(sim.countEvents(evDefect) == 0, "a defect fired before any consume")
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[1] = actConsume
  sim.step(actions)
  check(sim.countEvents(evDefect) == 1,
    "Bex banked three tokens it never returned and no defect fired")
  # A second cash-out on the same pair must NOT produce a second row.
  for i in 0 ..< SeatCount: actions[i] = actWait
  for _ in 0 ..< DefaultConsumeCooldown: sim.step(actions)
  sim.cogs[1].tokens = [0, 5, 0]
  actions[1] = actConsume
  sim.step(actions)
  check(sim.countEvents(evDefect) == 1,
    "a second defect row fired for the same ordered pair")
  banner "a defect row fires exactly once per ordered pair, and only at a consume"

block defectNeedsThreeTakenAndNothingReturned:
  var sim = initSimServer(variantConfig("refinery"))
  for slot in 0 ..< SeatCount:
    var order = defaultOrder()
    order.job = jobHold
    order.consume = cwNever
    sim.holdOrder(slot, order)
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  # Bex has taken 3, but has ALSO given one back, so banking is not a defection.
  sim.cogs[0].tokens = [1, 0, 0]
  sim.cogs[1].tokens = [0, 1, 0]
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actGiftE
  actions[1] = actGiftW
  sim.step(actions)
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[1] = actConsume
  sim.step(actions)
  check(sim.countEvents(evDefect) == 0,
    "banking after returning something was recorded as a defection")
  banner "a defect needs gaveYou >= 3 AND youGave == 0"

block reciprocityFormula:
  check(reciprocityX100(0, 0) == 0, "both-zero reciprocity must be 0")
  check(reciprocityX100(10, 10) == 100, "equal flows must be 100")
  check(reciprocityX100(3, 12) == 25, "3 given / 12 received must be 25")
  check(reciprocityX100(12, 3) == 25, "the formula must be symmetric")
  check(reciprocityX100(7, 0) == 0, "one-sided giving must be 0")
  banner "reciprocity_x100 matches its integer formula, both-zero included"

block ledgerRebuiltFromEventsEqualsTheLiveOne:
  ## The whole point of recording every gift: a viewer holding only the bytes
  ## can reconstruct the trust graph exactly as the server had it.
  for variant in VariantIds:
    let sim = playScripted(allOf(blReciprocator), variantConfig(variant))
    var given, got: array[SeatCount, array[SeatCount, int]]
    # A single ordered pass. `spill` is emitted by the gift that caused it, on
    # the same tick and immediately after it, so the most recent gift is the
    # one it belongs to -- which is exactly how a viewer reading the stream
    # would attribute it.
    var lastGift = (fromSeat: -1, toSeat: -1, level: -1, tick: -1)
    for event in sim.events:
      case event.kind
      of evGift:
        given[event.fromSeat][event.toSeat] += 1
        got[event.toSeat][event.fromSeat] += event.n
        lastGift = (event.fromSeat, event.toSeat, event.got, event.t)
      of evSpill:
        if event.cause == "gift" and event.t == lastGift.tick and
            event.seat == lastGift.toSeat and event.lvl == lastGift.level:
          got[lastGift.toSeat][lastGift.fromSeat] -= event.lost
      else:
        discard
    for a in 0 ..< SeatCount:
      for b in 0 ..< SeatCount:
        check(given[a][b] == sim.ledger.given[a][b],
          variant & ": rebuilt given[" & $a & "][" & $b & "] = " &
          $given[a][b] & ", live = " & $sim.ledger.given[a][b])
        check(got[a][b] == sim.ledger.got[a][b],
          variant & ": rebuilt got[" & $a & "][" & $b & "] = " & $got[a][b] &
          ", live = " & $sim.ledger.got[a][b])
  banner "the ledger rebuilt from events[] alone equals the live ledger"

block trackerFoldIsSeekAccurate:
  ## The viewer's tracker is a pure fold over the event stream, so re-folding
  ## it to tick N must land on exactly what playing to tick N produced.
  let sim = playScripted(allOf(blReciprocator), variantConfig("refinery"))
  let events = eventsJson(sim.events)
  var streamed = initBroadcastTracker()
  let checkpoints = [59, 179, 359, 719]
  var cursor = 0
  for target in checkpoints:
    while cursor < events.len and
        int(events[cursor]{"t"}.getBiggestInt()) <= target:
      streamed.ingest(events[cursor])
      inc cursor
    var rebuilt = initBroadcastTracker()
    rebuilt.resync(events, target)
    check(rebuilt.giftsGiven == streamed.giftsGiven and
          rebuilt.minted == streamed.minted and
          rebuilt.tokensBanked == streamed.tokensBanked and
          rebuilt.defections == streamed.defections,
      "the tracker rebuilt at tick " & $target & " differs from the streamed one")
  banner "a seek re-folds the tracker to exactly the streamed state"

echo "test_ledger OK"

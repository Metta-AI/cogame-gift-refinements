## Sim units (design note "## Tests" item 2).
##
## The gift rule in every branch, the cap, the cooldowns, the resolution order,
## the final-tick autobank, and determinism.

import std/[json, strutils]

import ./helpers

suite "sim"

proc quietRoom(variant = "refinery"): SimServer =
  ## A sim with every seat holding still, so a unit test drives exactly the
  ## cogs it places.
  result = initSimServer(variantConfig(variant))
  for slot in 0 ..< SeatCount:
    var order = defaultOrder()
    order.job = jobHold
    order.consume = cwNever
    result.holdOrder(slot, order)

proc beamOnce(sim: var SimServer, slot: int, dir: Dir) =
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount:
    actions[i] = actWait
  actions[slot] =
    case dir
    of dirN: actGiftN
    of dirE: actGiftE
    of dirS: actGiftS
    of dirW: actGiftW
  sim.step(actions)

block giftSpendsTheLowestHeldLevel:
  var sim = quietRoom()
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [1, 5, 0]
  sim.beamOnce(0, dirE)
  check(sim.cogs[0].tokens == [0, 5, 0],
    "the beam spent " & $sim.cogs[0].tokens & ", not the single raw token")
  check(sim.cogs[1].tokens == [0, 3, 0],
    "level 0 -> 3 x level 1 failed: " & $sim.cogs[1].tokens)
  banner "a cog holding {1 raw, 5 refined} sends RAW, and raw mints 3 refined"

block refinedMintsSuperAndSuperPassesThrough:
  var sim = quietRoom()
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [0, 1, 0]
  sim.beamOnce(0, dirE)
  check(sim.cogs[1].tokens == [0, 0, 3],
    "level 1 -> 3 x level 2 failed: " & $sim.cogs[1].tokens)
  sim.cogs[0].tokens = [0, 0, 1]
  sim.cogs[0].giftCd = 0
  sim.beamOnce(0, dirE)
  check(sim.cogs[1].tokens == [0, 0, 4],
    "a maxed token must pass through as ONE super token, got " &
    $sim.cogs[1].tokens)
  banner "refined mints 3 super; a super token passes through as one"

block receiptOverTheCapSpills:
  var sim = quietRoom()
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [0, 1, 0]
  sim.cogs[1].tokens = [0, 0, 14]
  sim.beamOnce(0, dirE)
  check(sim.cogs[1].tokens[2] == 15,
    "the receipt should have filled the cap exactly, got " &
    $sim.cogs[1].tokens[2])
  var spilled = 0
  for event in sim.events:
    if event.kind == evSpill and event.cause == "gift":
      spilled += event.lost
  check(spilled == 2, "expected 2 tokens spilled, got " & $spilled)
  banner "anything over invCap = 15 is lost, with a spill event naming it"

block emptyInventoryDoesNotFire:
  var sim = quietRoom()
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [0, 0, 0]
  sim.beamOnce(0, dirE)
  check(sim.countEvents(evGift) == 0 and sim.countEvents(evGiftMiss) == 0,
    "a shooter holding zero tokens fired anyway")
  check(sim.cogs[0].giftCd == 0, "an unfired beam still took the cooldown")
  banner "a shooter holding zero tokens does not fire at all"

block aMissCostsNoTokenButTakesTheCooldown:
  var sim = quietRoom()
  sim.parkEveryoneElse(0)
  sim.place(0, 8, 6)
  sim.cogs[0].tokens = [3, 0, 0]
  sim.beamOnce(0, dirN)
  check(sim.cogs[0].tokens == [3, 0, 0], "a miss spent a token")
  check(sim.countEvents(evGiftMiss) == 1, "no giftmiss event was emitted")
  check(sim.cogs[0].giftCd == DefaultGiftCooldown - 1,
    "a miss did not set the gift cooldown")
  banner "a beam that finds no cog costs no token, only the cooldown"

block aCogCannotGiftItself:
  var sim = quietRoom()
  sim.parkEveryoneElse(0)
  sim.place(0, 8, 6)
  sim.cogs[0].tokens = [3, 0, 0]
  for dir in [dirN, dirE, dirS, dirW]:
    let trace = sim.board.traceBeam(8, 6, dir, DefaultBeamRange, sim.occupied)
    check(not (trace.hit and trace.seat == 0), "a cog targeted itself")
  banner "the trace starts at the NEXT cell, so a cog cannot gift itself"

block collectAtTheCapRefusesAndSpills:
  var sim = quietRoom()
  sim.parkEveryoneElse(0)
  let pad = sim.board.pads[0]
  sim.place(0, pad.x, pad.y)
  sim.cogs[0].tokens = [DefaultInvCap, 0, 0]
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actCollect
  sim.step(actions)
  check(sim.cogs[0].tokens[0] == DefaultInvCap, "the cap was breached")
  check(sim.countEvents(evCollect) == 0, "the collect was recorded anyway")
  var spilled = 0
  for event in sim.events:
    if event.kind == evSpill and event.cause == "collect":
      spilled += event.lost
  check(spilled == 1, "no collect spill was recorded")
  check(sim.padTimer[0] == 0, "the refused token left the pad")
  banner "collect at t0 == 15 refuses, spills, and leaves the token on the pad"

block consumeScoresEverythingAndZeroes:
  var sim = quietRoom()
  sim.parkEveryoneElse(0)
  sim.cogs[0].tokens = [2, 3, 4]
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actConsume
  sim.step(actions)
  check(sim.cogs[0].score == 9, "consume scored " & $sim.cogs[0].score & ", expected 9")
  check(sim.cogs[0].tokens == [0, 0, 0], "consume left tokens behind")
  check(sim.cogs[0].consumeCd == DefaultConsumeCooldown - 1,
    "consume did not set its cooldown")
  banner "consume scores t0+t1+t2 at +1 each and empties every level"

block consumeResolvesBeforeGifts:
  ## Step 3 runs before step 4, so a token beamed at you on the SAME tick lands
  ## after your cash-out and survives it.
  var sim = quietRoom()
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [0, 1, 0]
  sim.cogs[1].tokens = [4, 0, 0]
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actGiftE
  actions[1] = actConsume
  sim.step(actions)
  check(sim.cogs[1].score == 4, "the receiver banked " & $sim.cogs[1].score)
  check(sim.cogs[1].tokens == [0, 0, 3],
    "the same-tick receipt did not survive the cash-out: " &
    $sim.cogs[1].tokens)
  banner "consume resolves BEFORE gifts on the same tick"

block cooldownsGateExactly:
  var sim = quietRoom()
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  sim.cogs[0].tokens = [9, 0, 0]
  var fired = 0
  for tick in 0 ..< 21:
    var actions: array[SeatCount, Action]
    for i in 0 ..< SeatCount: actions[i] = actWait
    actions[0] = actGiftE
    let before = sim.countEvents(evGift)
    sim.step(actions)
    if sim.countEvents(evGift) > before: inc fired
  # giftCooldown = 4 means four ticks BETWEEN beams, so a cog fires on ticks
  # 0, 4, 8, 12, 16 and 20 -- six beams in twenty-one ticks, and never seven.
  check(fired == 6, "expected 6 beams in 21 ticks at giftCooldown 4, got " & $fired)
  banner "the gift cooldown gates to exactly one beam every 4 ticks"

block twoCogsCannotShareACellAndTheLowerSlotWins:
  var sim = quietRoom()
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actMoveE
  actions[1] = actMoveW
  sim.step(actions)
  check(sim.cogs[0].x == 9, "the lower slot did not take the cell")
  check(sim.cogs[1].x == 10, "the higher slot moved into an occupied cell")
  banner "a cell a lower slot moved into this tick counts as occupied"

block padRegrowsAtExactlySpawnTicks:
  var sim = quietRoom()
  sim.parkEveryoneElse(0)
  let pad = sim.board.pads[0]
  sim.place(0, pad.x, pad.y)
  var actions: array[SeatCount, Action]
  for i in 0 ..< SeatCount: actions[i] = actWait
  actions[0] = actCollect
  sim.step(actions)
  # Regrow is STEP 1 and collect is STEP 5, so the tick that emptied the pad
  # does not also tick its timer down: the pad is bare for a full spawnTicks.
  check(sim.padTimer[0] == DefaultSpawnTicks,
    "the regrow timer started at " & $sim.padTimer[0])
  for i in 0 ..< SeatCount: actions[i] = actWait
  for tick in 0 ..< DefaultSpawnTicks - 1:
    sim.step(actions)
  check(sim.padTimer[0] == 1, "the regrow timer is off by one")
  sim.step(actions)
  check(sim.padTimer[0] == 0, "the pad did not regrow at spawnTicks")
  check(sim.countEvents(evSpawn) == 1, "the regrow emitted no spawn event")
  banner "a pad regrows at exactly spawnTicks = 30"

block finalTickAutobanksEverySeat:
  ## Every seat plays `collect` and NEVER banks, so the close is the only thing
  ## that can put a token in anyone's score.
  var config = variantConfig("refinery")
  config.rounds = 2
  var sim = initSimServer(config)
  for slot in 0 ..< SeatCount:
    var order = defaultOrder()
    order.job = jobCollect
    order.consume = cwNever
    sim.holdOrder(slot, order)
  sim.runTicks(config.totalTicks())
  sim.finish(erComplete)
  check(sim.countEvents(evConsume) == 0,
    "a seat banked mid-episode; the fixture is not testing the close")
  check(sim.countEvents(evAutobank) >= 1, "nobody autobanked at the close")
  for slot in 0 ..< SeatCount:
    check(sim.cogs[slot].held() == 0,
      "seat " & $slot & " still holds tokens after the close")
  var banked = 0
  for event in sim.events:
    if event.kind == evConsume or event.kind == evAutobank:
      banked += event.n
  var total = 0
  for slot in 0 ..< SeatCount:
    total += sim.cogs[slot].score
  check(total == banked,
    "scores (" & $total & ") do not equal consume + autobank (" & $banked & ")")
  banner "the final tick autobanks every cog and it counts into scores"

block determinism:
  let config = variantConfig("refinery")
  let a = playScripted(allOf(blReciprocator), config)
  let b = playScripted(allOf(blReciprocator), config)
  check(a.gameHashHex() == b.gameHashHex(),
    "two runs in one process disagree: " & a.gameHashHex() & " vs " &
    b.gameHashHex())
  check($a.resultsJson() == $b.resultsJson(), "the results documents disagree")
  check(replayBytes(a) == replayBytes(b), "the replay bytes disagree")
  check(a.frames.len == config.totalTicks(),
    "expected " & $config.totalTicks() & " frames, got " & $a.frames.len)
  banner "the same seed and the same orders produce an identical gameHash"

echo "test_sim OK"

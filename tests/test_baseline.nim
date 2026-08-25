## Bounded orders and legality (design note "## Tests" item 4).
##
## Both policy kinds emit the SAME object, so one validator covers both. This
## is the test that makes that property load-bearing: for 12 seeds x 720 ticks
## on all four variants, with all-`reciprocator`, all-`hoarder` and a 3/3 mix,
## every emitted order is inside its schema and every per-tick action leaves
## the world legal.

import std/[algorithm, monotimes, strutils, times]

import ./helpers

suite "baseline"

const Seeds = 12

# Every round of orders this test plays, in MICROSECONDS. The note's item 4
# bound is "no more than 1 ms per round"; measuring in whole milliseconds (as
# this test used to) floors a sub-millisecond figure to 0 and can only compare
# against a bound 50x the note's, which is a bound on the runner's mood rather
# than on the code (r1 review F9). The distribution is checked once, at the
# bottom of the file, and printed.
var
  roundTimesUs: seq[int] = @[]
  worstRoundUs = 0
  worstRoundLabel = ""

proc assertOrderIsLegal(
  order: Order, seat: int, view: SeatView, config: GameConfig, where: string
) =
  check(order.job in {jobCollect, jobMeet, jobHold, jobEvade},
    where & ": job is outside its enum")
  check(order.consume in {cwNow, cwEnd, cwNever},
    where & ": consume is outside its enum")
  check(order.target == -1 or (order.target >= 0 and order.target < SeatCount),
    where & ": target " & $order.target & " is not a slot")
  check(order.target != seat, where & ": a cog targeted itself")
  check(order.gift >= 0 and order.gift <= config.maxBeamsPerRound,
    where & ": gift " & $order.gift & " is outside 0.." &
    $config.maxBeamsPerRound)
  check(order.gift <= view.held,
    where & ": gift " & $order.gift & " exceeds the " & $view.held &
    " tokens held")
  if order.job == jobMeet or order.gift > 0:
    check(order.target >= 0, where & ": meet/gift with no target")
  check(order.say.len <= MaxSayRunes * 4,
    where & ": say is longer than its cap allows")

proc playAndAudit(
  kinds: array[SeatCount, Baseline], config: GameConfig, label: string
): SimServer =
  var sim = initSimServer(config)
  for round in 1 .. config.rounds:
    let started = getMonoTime()
    for slot in 0 ..< SeatCount:
      let view = sim.seatView(slot)
      var order = scriptedOrder(kinds[slot], view, config.maxBeamsPerRound)
      assertOrderIsLegal(order, slot, view, config,
        label & " round " & $round & " seat " & $slot)
      order.source = osScripted
      sim.holdOrder(slot, order)
    let roundUs = (getMonoTime() - started).inMicroseconds.int
    roundTimesUs.add(roundUs)
    if roundUs > worstRoundUs:
      worstRoundUs = roundUs
      worstRoundLabel = label & " round " & $round
    for tick in 0 ..< config.ticksPerRound:
      let actions = sim.kernelActions()
      for slot in 0 ..< SeatCount:
        check(actions[slot] in {actWait, actMoveN, actMoveE, actMoveS, actMoveW,
                                actCollect, actGiftN, actGiftE, actGiftS,
                                actGiftW, actConsume},
          label & ": an action outside the eleven-value vocabulary")
      sim.step(actions)
      for slot in 0 ..< SeatCount:
        let cog = sim.cogs[slot]
        check(sim.board.passable(cog.x, cog.y),
          label & ": seat " & $slot & " is in a wall or off the board at (" &
          $cog.x & "," & $cog.y & ")")
        for other in slot + 1 ..< SeatCount:
          check(not (cog.x == sim.cogs[other].x and cog.y == sim.cogs[other].y),
            label & ": seats " & $slot & " and " & $other & " share a cell")
        for level in 0 .. 2:
          check(cog.tokens[level] >= 0 and cog.tokens[level] <= config.invCap,
            label & ": seat " & $slot & " holds " & $cog.tokens[level] &
            " at level " & $level)
    sim.closeRound()
  sim.finish(erComplete)
  sim

block everyRoomIsLegalOnEveryVariant:
  for variant in VariantIds:
    for seed in 1 .. Seeds:
      let config = variantConfig(variant, seed)
      let label = variant & " seed " & $seed

      let recips = playAndAudit(allOf(blReciprocator), config, label & " recip")
      let hoarders = playAndAudit(allOf(blHoarder), config, label & " hoard")
      let mixed = playAndAudit(
        roomOf(blReciprocator, blReciprocator, blReciprocator,
               blHoarder, blHoarder, blHoarder), config, label & " mix")

      check(hoarders.totalGifts == 0,
        label & ": the hoarder room fired " & $hoarders.totalGifts & " beams")
      check(recips.totalGifts > 0,
        label & ": the reciprocator room never fired a beam")
      for slot in 3 ..< SeatCount:
        check(mixed.cogs[slot].giftsSent == 0,
          label & ": a hoarder in the mixed room fired a beam")
  banner "12 seeds x 4 variants x 3 rooms: every order bounded, every world legal"

block scoresNeverDecrease:
  let config = variantConfig("refinery")
  var sim = initSimServer(config)
  var last: array[SeatCount, int]
  for round in 1 .. config.rounds:
    for slot in 0 ..< SeatCount:
      var order = scriptedOrder(
        blReciprocator, sim.seatView(slot), config.maxBeamsPerRound)
      sim.holdOrder(slot, order)
    for tick in 0 ..< config.ticksPerRound:
      sim.stepWithKernel()
      for slot in 0 ..< SeatCount:
        check(sim.cogs[slot].score >= last[slot],
          "seat " & $slot & "'s score went backwards")
        last[slot] = sim.cogs[slot].score
    sim.closeRound()
  banner "a score never decreases: nothing in this game subtracts"

block reciprocatorsKeepExchanging:
  ## Two cogs that have exchanged once keep exchanging: the always-return bot
  ## must not drop a partner that is in credit with it.
  let sim = playScripted(allOf(blReciprocator), variantConfig("refinery"))
  var pairsWithTraffic = 0
  for a in 0 ..< SeatCount:
    for b in a + 1 ..< SeatCount:
      if sim.ledger.given[a][b] > 0 and sim.ledger.given[b][a] > 0:
        inc pairsWithTraffic
  check(pairsWithTraffic >= 2,
    "only " & $pairsWithTraffic & " pairs ever exchanged in both directions")
  banner "reciprocators that have exchanged once keep exchanging"

block baselineOrdersCostLessThanAMillisecondPerRound:
  ## The note's item 4: "neither baseline raises, and neither takes more than
  ## 1 ms per round" -- six seats' orders, on the critical path of every round
  ## boundary. The MEDIAN round is what the code costs and is held to the
  ## note's figure; the worst single round keeps a wide outlier guard, because
  ## this runs on a shared runner where a scheduler blip lands on whichever
  ## round it likes and a gate that flakes is not a gate. Both figures are
  ## printed, so the real cost is in the log rather than inferred (r1 review
  ## F9).
  check(roundTimesUs.len == VariantIds.len * Seeds * 3 * DefaultRounds,
    "only " & $roundTimesUs.len & " rounds were timed; the measurement moved")
  var ordered = roundTimesUs
  ordered.sort()
  let
    median = ordered[ordered.len div 2]
    p99 = ordered[(ordered.len * 99) div 100]
  echo "  baseline orders per round over ", ordered.len, " rounds: median ",
    median, " us, p99 ", p99, " us, worst ", worstRoundUs, " us (",
    worstRoundLabel, ")"
  check(median <= 1000,
    "the median round of baseline orders took " & $median &
    " us, over the note's 1 ms")
  check(p99 <= 1000,
    "the 99th-percentile round of baseline orders took " & $p99 &
    " us, over the note's 1 ms")
  check(worstRoundUs <= 50_000,
    "the slowest round of baseline orders took " & $worstRoundUs & " us (" &
    worstRoundLabel & ")")
  banner "a round of baseline orders costs under the note's 1 ms at the median and p99"

echo "test_baseline OK"

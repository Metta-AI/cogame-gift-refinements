## Shared helpers for the Gift Refinements test shards.
##
## Every test plays real episodes through the SAME entry point the server uses
## (`stepWithKernel`), so a test can never exercise a code path the game does
## not.

import std/[json, strutils]

import
  gift_refinements/[sim_types, sim_config, sim, board, kernel, orders,
                    scripted, events, ledger, replays, broadcast]

export sim_types, sim_config, sim, board, kernel, orders, scripted, events,
       ledger, replays, broadcast

const VariantIds* = ["refinery", "scarce", "long-beam", "open-floor"]

proc variantConfig*(variant: string, seed = 1): GameConfig =
  ## The four shipped variants, byte-for-byte the `game_config` blocks in
  ## `coworld_manifest_template.json`. `tests/test_manifest.nim` asserts they
  ## agree, so a knob edited in one place fails here rather than in a league
  ## episode.
  result = defaultGameConfig()
  result.seed = seed
  result.variant = variant
  case variant
  of "refinery": discard
  of "scarce": result.spawnTicks = 75
  of "long-beam": result.beamRange = 8
  of "open-floor": result.pillars = 0
  else: raise newException(GiftError, "unknown variant " & variant)

proc playScripted*(
  kinds: array[SeatCount, Baseline], config: GameConfig
): SimServer =
  ## A whole episode on scripted policies: one order per seat per round, the
  ## kernel for every tick, the round close, then the terminal settle.
  var sim = initSimServer(config)
  for round in 1 .. config.rounds:
    for slot in 0 ..< SeatCount:
      var order = scriptedOrder(
        kinds[slot], sim.seatView(slot), config.maxBeamsPerRound)
      order.source = osScripted
      sim.orders[slot] = order
      sim.haveOrder[slot] = true
      sim.events.add(GiftEvent(
        kind: evOrder, t: sim.tick, seat: slot, round: round,
        job: $order.job, target: order.targetAlias(sim.aliases),
        gift: order.gift, consume: $order.consume, clamped: order.clamped,
        source: $order.source, say: order.say, notes: order.notes))
    for tick in 0 ..< config.ticksPerRound:
      sim.stepWithKernel()
    sim.closeRound()
  sim.finish(erComplete)
  sim

proc allOf*(kind: Baseline): array[SeatCount, Baseline] =
  for slot in 0 ..< SeatCount:
    result[slot] = kind

proc roomOf*(kinds: varargs[Baseline]): array[SeatCount, Baseline] =
  doAssert kinds.len == SeatCount
  for slot in 0 ..< SeatCount:
    result[slot] = kinds[slot]

proc holdOrder*(sim: var SimServer, slot: int, order: Order) =
  sim.orders[slot] = order
  sim.haveOrder[slot] = true

proc place*(sim: var SimServer, slot, x, y: int) =
  ## Move one cog for a unit test. The occupancy map is the sim's, so this
  ## keeps it consistent rather than poking `cogs` behind its back.
  sim.occupied[sim.board.index(sim.cogs[slot].x, sim.cogs[slot].y)] = -1
  sim.cogs[slot].x = x
  sim.cogs[slot].y = y
  sim.occupied[sim.board.index(x, y)] = slot

proc parkEveryoneElse*(sim: var SimServer, keep: varargs[int]) =
  ## Park the seats a unit test is not interested in along the bottom row, out
  ## of every beam line the test cares about.
  var kept: seq[int] = @[]
  for slot in keep:
    kept.add(slot)
  var x = 1
  for slot in 0 ..< SeatCount:
    if slot in kept:
      continue
    while sim.board.isBlocked(x, Rows - 2) or
        sim.occupied[sim.board.index(x, Rows - 2)] >= 0:
      inc x
    sim.place(slot, x, Rows - 2)
    inc x

proc runTicks*(sim: var SimServer, ticks: int) =
  for _ in 0 ..< ticks:
    sim.stepWithKernel()

proc countEvents*(sim: SimServer, kind: EventKind): int =
  for event in sim.events:
    if event.kind == kind:
      inc result

proc check*(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc banner*(name: string) =
  echo "  \u2713 ", name

proc suite*(name: string) =
  echo "== ", name

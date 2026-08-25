## The kernel: one standing order in, 60 per-tick grid actions out.
##
## Forked from `coworld-ctf/src/ctf/control.nim`. The sim's policy interface is
## per-tick grid actions, exactly as the idea says; no LLM can emit 720 actions
## per seat, so once per ROUND each seat submits a standing order and this
## deterministic kernel turns it into that round's action stream. 72 LLM calls
## per episode instead of 4 320.
##
## Priority, every tick:
##   1. a SCHEDULED CONSUME (`now` on the round's first tick, `end` on its last)
##   2. a BEAM, if beams remain, the cooldown is clear, the cog holds a token
##      and the target is hittable RIGHT NOW
##   3. the JOB's movement (collect / meet / hold / evade)
##
## Dijkstra is over passable cells at unit cost with N, E, S, W expansion, so
## every path is unique and every tie is broken the same way on every host.

import ./sim_types, ./board, ./orders, ./sim

proc scheduledConsume(sim: SimServer, slot: int): bool =
  let
    order = sim.orders[slot]
    inRound = sim.tick mod max(1, sim.config.ticksPerRound)
  case order.consume
  of cwNow: inRound == 0
  of cwEnd: inRound == sim.config.ticksPerRound - 1
  of cwNever: false

proc beamAction(sim: SimServer, slot: int): tuple[ok: bool, action: Action] =
  result = (false, actWait)
  let order = sim.orders[slot]
  if order.gift <= 0 or order.target < 0:
    return
  if sim.cogs[slot].beamsLeft <= 0 or sim.cogs[slot].giftCd > 0:
    return
  if sim.cogs[slot].held() == 0:
    return
  # The order's beam budget is a per-round cap on SCHEDULED beams; the kernel
  # spends it against the round's remaining allowance.
  let spent = sim.config.maxBeamsPerRound - sim.cogs[slot].beamsLeft
  if spent >= order.gift:
    return
  let shot = sim.board.hittable(
    sim.cogs[slot].x, sim.cogs[slot].y,
    sim.cogs[order.target].x, sim.cogs[order.target].y,
    sim.config.beamRange, sim.occupied)
  if not shot.ok:
    return
  # CONSEQUENCE, recorded because it makes one event unreachable in play
  # (r1 review F6): `hittable` and the resolver's `traceBeam` are the same
  # pair over the same `sim.occupied`, and the only step between this decision
  # (step 2) and step 4 is the consume, which moves nobody. So a beam this
  # kernel schedules ALWAYS connects, and `giftmiss` -- the rule, its
  # `beam_fizzle` art and the feed branch -- can only be produced by driving
  # `sim.step` with a gift action directly, as tests/test_sim.nim does. That
  # is the note's rule 2 for the kernel ("`target` is currently hittable"),
  # not a deviation from it: no cog ever spends a beam on empty air.
  # tests/test_sim.nim pins both halves.
  result.ok = true
  result.action =
    case shot.dir
    of dirN: actGiftN
    of dirE: actGiftE
    of dirS: actGiftS
    of dirW: actGiftW

proc stepTowards(
  sim: SimServer, slot: int, field: openArray[int]
): Action =
  let step = sim.board.firstStepToward(sim.cogs[slot].x, sim.cogs[slot].y, field)
  if not step.ok:
    return actWait
  case step.dir
  of dirN: actMoveN
  of dirE: actMoveE
  of dirS: actMoveS
  of dirW: actMoveW

proc collectAction(sim: SimServer, slot: int): Action =
  ## Walk to the nearest loose raw token and `collect` on arrival. With nothing
  ## loose anywhere, walk to the nearest pad and wait on it.
  let here = cell(sim.cogs[slot].x, sim.cogs[slot].y)
  let loose = sim.looseCells()
  let targets = if loose.len > 0: loose else: sim.board.pads
  for target in targets:
    if target == here:
      return (if loose.len > 0: actCollect else: actWait)
  var best = cell(-1, -1)
  var bestDist = high(int)
  for target in targets:
    let field = sim.board.distanceField(target.x, target.y)
    let d = field[sim.board.index(here.x, here.y)]
    if d < 0 or d >= bestDist:
      continue
    bestDist = d
    best = target
  if best.x < 0:
    return actWait
  sim.stepTowards(slot, sim.board.distanceField(best.x, best.y))

proc meetCells(sim: SimServer, target: int): seq[Cell] =
  ## Every passable cell from which `target` is hittable by the beam predicate.
  ## The SAME predicate the observation reports and the sim enforces.
  let
    tx = sim.cogs[target].x
    ty = sim.cogs[target].y
  const Steps: array[4, tuple[dx, dy: int]] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
  for step in Steps:
    for distance in 1 .. sim.config.beamRange:
      let
        x = tx + step.dx * distance
        y = ty + step.dy * distance
      if not sim.board.passable(x, y):
        break
      let shot = sim.board.hittable(
        x, y, tx, ty, sim.config.beamRange, sim.occupied)
      if shot.ok:
        result.add(cell(x, y))

proc evadeCell(sim: SimServer, slot: int): Cell =
  ## The reachable cell that maximises the Chebyshev distance to the NEAREST
  ## other cog, ties broken by lowest (y, x). "Consume and walk" made
  ## expressible -- and the pillars are what make it work.
  let field = sim.board.distanceField(sim.cogs[slot].x, sim.cogs[slot].y)
  var
    best = cell(sim.cogs[slot].x, sim.cogs[slot].y)
    bestScore = -1
  for y in 0 ..< Rows:
    for x in 0 ..< Cols:
      if not sim.board.passable(x, y):
        continue
      if field[sim.board.index(x, y)] < 0:
        continue
      var nearest = high(int)
      for other in 0 ..< SeatCount:
        if other == slot:
          continue
        nearest = min(nearest,
          max(abs(sim.cogs[other].x - x), abs(sim.cogs[other].y - y)))
      if nearest > bestScore:
        bestScore = nearest
        best = cell(x, y)
  best

proc jobAction(sim: SimServer, slot: int): Action =
  let order = sim.orders[slot]
  case order.job
  of jobCollect:
    sim.collectAction(slot)
  of jobMeet:
    if order.target < 0 or order.target == slot:
      return sim.collectAction(slot)   ## `meet` with no legal target degrades
    let spots = sim.meetCells(order.target)
    if spots.len == 0:
      return sim.collectAction(slot)
    for spot in spots:
      if spot.x == sim.cogs[slot].x and spot.y == sim.cogs[slot].y:
        return actWait                 ## already in line: stay in line
    var
      best = cell(-1, -1)
      bestDist = high(int)
    for spot in spots:
      let field = sim.board.distanceField(spot.x, spot.y)
      let d = field[sim.board.index(sim.cogs[slot].x, sim.cogs[slot].y)]
      if d < 0 or d >= bestDist:
        continue
      bestDist = d
      best = spot
    if best.x < 0:
      return sim.collectAction(slot)
    sim.stepTowards(slot, sim.board.distanceField(best.x, best.y))
  of jobHold:
    actWait
  of jobEvade:
    let goal = sim.evadeCell(slot)
    if goal.x == sim.cogs[slot].x and goal.y == sim.cogs[slot].y:
      return actWait
    sim.stepTowards(slot, sim.board.distanceField(goal.x, goal.y))

proc kernelAction*(sim: SimServer, slot: int): Action =
  ## Step 2 of the tick: this cog's single action for this tick.
  ##
  ## "A cog whose RELEVANT cooldown is still running emits `wait`" -- relevant
  ## is the operative word. The move cooldown gates MOVES and the collect
  ## cooldown gates PICK-UPS; gating everything on the move cooldown would make
  ## a cog standing on a loose token idle two ticks in every three, which is a
  ## third of the episode's throughput thrown away for no rule.
  if sim.scheduledConsume(slot) and sim.cogs[slot].consumeCd == 0 and
      sim.cogs[slot].held() > 0:
    return actConsume
  let beam = sim.beamAction(slot)
  if beam.ok:
    return beam.action
  let action = sim.jobAction(slot)
  case action
  of actMoveN, actMoveE, actMoveS, actMoveW:
    if sim.cogs[slot].moveCd > 0: actWait else: action
  of actCollect:
    if sim.cogs[slot].collectCd > 0: actWait else: action
  else:
    action

proc kernelActions*(sim: SimServer): array[SeatCount, Action] =
  for slot in 0 ..< SeatCount:
    result[slot] = sim.kernelAction(slot)

proc stepWithKernel*(sim: var SimServer) =
  ## One whole tick: derive every cog's action from its standing order, then
  ## resolve. This is the only entry point the server and the tests use.
  let actions = sim.kernelActions()
  sim.step(actions)

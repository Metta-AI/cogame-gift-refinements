## The board: one AUTHORED 24 x 14 grid per variant.
##
## A heavily reduced fork of `coworld-ctf/src/ctf/arena.nim`. What survives is
## the geometry, the beam trace and the unit-cost Dijkstra the kernel walks.
## The terrain GENERATOR, `mapSpec`, symmetry, the validators, the pixel
## queries and `map_pool` are all deleted: Gift Refinements has one authored
## board and four variants that only change constants and the pillar list.
##
## Geometry (design note "## The game" -> "The board"):
##   * a border wall ring at x == 0, x == 23, y == 0, y == 13 -- 72 cells;
##   * five 2x2 interior pillars -- 20 cells -- so that "consume and walk away"
##     is a real move: three steps break every beam line to you;
##   * 18 fixed seep pads, none on a wall, a pillar or a spawn;
##   * six fixed spawn cells, one per slot.
## 264 interior cells minus 20 pillar cells = 244 passable cells.

import std/[algorithm, deques]

import ./sim_types, ./sim_config

const
  PillarBlocks*: array[5, array[4, int]] = [
    [6, 4, 7, 5],       # A (north-west)
    [16, 4, 17, 5],     # B (north-east)
    [6, 8, 7, 9],       # C (south-west)
    [16, 8, 17, 9],     # D (south-east)
    [11, 6, 12, 7]      # E (the centre block)
  ]

  PadCells*: array[18, array[2, int]] = [
    [4, 2], [9, 2], [14, 2], [19, 2],
    [4, 11], [9, 11], [14, 11], [19, 11],
    [3, 6], [9, 6], [14, 6], [20, 6],
    [3, 7], [20, 7],
    [11, 4], [12, 4],
    [11, 9], [12, 9]
  ]

type
  Board* = object
    cols*, rows*: int
    blocked*: seq[bool]        ## wall ring OR pillar: impassable, blocks beams
    pads*: seq[Cell]
    padAt*: seq[int]           ## cell index -> pad index, or -1
    spawns*: seq[Cell]

proc index*(board: Board, x, y: int): int = y * board.cols + x

proc inside*(board: Board, x, y: int): bool =
  x >= 0 and y >= 0 and x < board.cols and y < board.rows

proc isBlocked*(board: Board, x, y: int): bool =
  not board.inside(x, y) or board.blocked[board.index(x, y)]

proc passable*(board: Board, x, y: int): bool =
  board.inside(x, y) and not board.blocked[board.index(x, y)]

proc initBoard*(config: GameConfig): Board =
  ## The authored board for this variant. `pillars` is the only geometry knob:
  ## `open-floor` sets it to 0, which removes exactly 20 cells and changes
  ## nothing else.
  result.cols = Cols
  result.rows = Rows
  result.blocked = newSeq[bool](Cols * Rows)
  for x in 0 ..< Cols:
    result.blocked[result.index(x, 0)] = true
    result.blocked[result.index(x, Rows - 1)] = true
  for y in 0 ..< Rows:
    result.blocked[result.index(0, y)] = true
    result.blocked[result.index(Cols - 1, y)] = true
  for i in 0 ..< min(config.pillars, PillarBlocks.len):
    let block4 = PillarBlocks[i]
    for y in block4[1] .. block4[3]:
      for x in block4[0] .. block4[2]:
        result.blocked[result.index(x, y)] = true
  result.padAt = newSeq[int](Cols * Rows)
  for i in 0 ..< result.padAt.len:
    result.padAt[i] = -1
  for i, pad in PadCells:
    let c = cell(pad[0], pad[1])
    if result.isBlocked(c.x, c.y):
      raise newException(GiftError,
        "seep pad " & $i & " at (" & $c.x & "," & $c.y & ") is not passable")
    result.pads.add(c)
    result.padAt[result.index(c.x, c.y)] = i
  for spawn in SpawnCells:
    let c = cell(spawn[0], spawn[1])
    if result.isBlocked(c.x, c.y):
      raise newException(GiftError,
        "spawn (" & $c.x & "," & $c.y & ") is not passable")
    if result.padAt[result.index(c.x, c.y)] >= 0:
      raise newException(GiftError,
        "spawn (" & $c.x & "," & $c.y & ") sits on a seep pad")
    result.spawns.add(c)

proc wallCells*(board: Board): seq[Cell] =
  ## Every impassable cell, in reading order. The replay records this list so
  ## the viewer never has to re-derive the geometry.
  for y in 0 ..< board.rows:
    for x in 0 ..< board.cols:
      if board.blocked[board.index(x, y)]:
        result.add(cell(x, y))

proc dirDelta*(dir: Dir): tuple[dx, dy: int] =
  case dir
  of dirN: (0, -1)
  of dirE: (1, 0)
  of dirS: (0, 1)
  of dirW: (-1, 0)

proc traceBeam*(
  board: Board, fromX, fromY: int, dir: Dir, beamRange: int,
  occupied: openArray[int]
): tuple[hit: bool, seat: int, x, y: int, dist: int] =
  ## Walks cells 1..`beamRange` straight out from (fromX, fromY). The trace
  ## STOPS at the first wall or pillar; the FIRST cog found in it is the
  ## target. It starts at the NEXT cell, so a cog can never gift itself, and it
  ## cannot pass through a third cog.
  ##
  ## `occupied` is `cols*rows` long: the slot standing on each cell, or -1.
  let delta = dirDelta(dir)
  result = (false, -1, fromX, fromY, 0)
  var
    x = fromX
    y = fromY
  for step in 1 .. beamRange:
    x += delta.dx
    y += delta.dy
    if board.isBlocked(x, y):
      return
    let seat = occupied[board.index(x, y)]
    if seat >= 0:
      return (true, seat, x, y, step)
  return

proc hittable*(
  board: Board, fromX, fromY, toX, toY, beamRange: int,
  occupied: openArray[int]
): tuple[ok: bool, dir: Dir] =
  ## The kernel's targeting predicate, and the SAME one the observation reports
  ## as `hittable` -- precomputing the legal choice set in the observation is
  ## what halved formal-output fallbacks in escrow, and it only works if the
  ## two are literally one function.
  result = (false, dirN)
  if fromX != toX and fromY != toY:
    return
  if fromX == toX and fromY == toY:
    return
  let dir =
    if fromY == toY: (if toX > fromX: dirE else: dirW)
    else: (if toY > fromY: dirS else: dirN)
  let trace = board.traceBeam(fromX, fromY, dir, beamRange, occupied)
  if trace.hit and trace.x == toX and trace.y == toY:
    return (true, dir)

proc distanceField*(board: Board, fromX, fromY: int): seq[int] =
  ## Unit-cost Dijkstra (a BFS at unit cost) over passable cells from one
  ## origin. Neighbours expand in N, E, S, W order and ties resolve by that
  ## order, so a path is unique and deterministic. Other cogs are NOT obstacles
  ## for path PLANNING -- only for the move itself.
  result = newSeq[int](board.cols * board.rows)
  for i in 0 ..< result.len:
    result[i] = -1
  if not board.passable(fromX, fromY):
    return
  var queue = initDeque[int]()
  result[board.index(fromX, fromY)] = 0
  queue.addLast(board.index(fromX, fromY))
  const Order: array[4, tuple[dx, dy: int]] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
  while queue.len > 0:
    let here = queue.popFirst()
    let
      hx = here mod board.cols
      hy = here div board.cols
    for step in Order:
      let
        nx = hx + step.dx
        ny = hy + step.dy
      if not board.passable(nx, ny):
        continue
      let next = board.index(nx, ny)
      if result[next] >= 0:
        continue
      result[next] = result[here] + 1
      queue.addLast(next)

proc firstStepToward*(
  board: Board, fromX, fromY: int, field: openArray[int]
): tuple[ok: bool, dir: Dir] =
  ## One step down a distance field built FROM the destination. N, E, S, W
  ## expansion order breaks every tie, so the walk is deterministic.
  result = (false, dirN)
  let hereDist = field[board.index(fromX, fromY)]
  if hereDist <= 0:
    return
  const Order: array[4, tuple[dir: Dir, dx, dy: int]] =
    [(dirN, 0, -1), (dirE, 1, 0), (dirS, 0, 1), (dirW, -1, 0)]
  for step in Order:
    let
      nx = fromX + step.dx
      ny = fromY + step.dy
    if not board.passable(nx, ny):
      continue
    let d = field[board.index(nx, ny)]
    if d >= 0 and d == hereDist - 1:
      return (true, step.dir)

proc nearestOf*(
  board: Board, field: openArray[int], targets: openArray[Cell]
): tuple[found: bool, cell: Cell, dist: int] =
  ## The reachable target with the smallest distance in `field`, ties broken by
  ## lowest (y, x) so the pick never depends on the caller's ordering.
  result = (false, cell(0, 0), 0)
  var best = high(int)
  var ordered: seq[Cell] = @[]
  for target in targets:
    ordered.add(target)
  ordered.sort(proc (a, b: Cell): int =
    if a.y != b.y: cmp(a.y, b.y) else: cmp(a.x, b.x))
  for target in ordered:
    if not board.inside(target.x, target.y):
      continue
    let d = field[board.index(target.x, target.y)]
    if d < 0 or d >= best:
      continue
    best = d
    result = (true, target, d)

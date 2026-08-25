## The board (design note "## Tests" item 1).
##
## Exactly 72 wall-ring cells and 20 pillar cells; exactly 18 pads at the
## listed cells, none on a wall, a pillar or a spawn, no duplicates; six
## distinct, passable, pad-free spawns; every passable cell reachable from
## every spawn; the beam trace stopping at walls, pillars and the first cog and
## never leaving the board; and `pillars: 0` removing exactly 20 cells and
## changing nothing else.

import std/[sets, strutils]

import ./helpers

suite "board"

block ringAndPillars:
  let board = initBoard(variantConfig("refinery"))
  var ring, pillar = 0
  for y in 0 ..< Rows:
    for x in 0 ..< Cols:
      if not board.blocked[board.index(x, y)]:
        continue
      if x == 0 or y == 0 or x == Cols - 1 or y == Rows - 1:
        inc ring
      else:
        inc pillar
  check(ring == 72, "wall ring is " & $ring & " cells, expected 72")
  check(pillar == 20, "pillars are " & $pillar & " cells, expected 20")
  var passable = 0
  for y in 0 ..< Rows:
    for x in 0 ..< Cols:
      if board.passable(x, y): inc passable
  check(passable == 244, "passable interior is " & $passable & ", expected 244")
  banner "72 wall cells, 20 pillar cells, 244 passable"

block padsAreLegal:
  let board = initBoard(variantConfig("refinery"))
  check(board.pads.len == 18, "expected 18 pads, got " & $board.pads.len)
  var seen = initHashSet[string]()
  for pad in board.pads:
    let key = $pad.x & "," & $pad.y
    check(key notin seen, "duplicate pad at " & key)
    seen.incl(key)
    check(board.passable(pad.x, pad.y), "pad at " & key & " is not passable")
    for spawn in board.spawns:
      check(not (spawn == pad), "pad at " & key & " sits on a spawn")
  banner "18 distinct pads, all passable, none on a spawn"

block spawnsAreLegal:
  let board = initBoard(variantConfig("refinery"))
  check(board.spawns.len == SeatCount, "expected 6 spawns")
  var seen = initHashSet[string]()
  for spawn in board.spawns:
    let key = $spawn.x & "," & $spawn.y
    check(key notin seen, "duplicate spawn at " & key)
    seen.incl(key)
    check(board.passable(spawn.x, spawn.y), "spawn " & key & " is not passable")
    check(board.padAt[board.index(spawn.x, spawn.y)] < 0,
      "spawn " & key & " sits on a pad")
  banner "6 distinct, passable, pad-free spawns"

block everyPassableCellIsReachable:
  for variant in VariantIds:
    let board = initBoard(variantConfig(variant))
    for spawn in board.spawns:
      let field = board.distanceField(spawn.x, spawn.y)
      for y in 0 ..< Rows:
        for x in 0 ..< Cols:
          if not board.passable(x, y):
            continue
          check(field[board.index(x, y)] >= 0,
            variant & ": (" & $x & "," & $y & ") is unreachable from spawn (" &
            $spawn.x & "," & $spawn.y & ")")
  banner "every passable cell is reachable from every spawn, on all four variants"

block beamTraceStops:
  var sim = initSimServer(variantConfig("refinery"))
  sim.parkEveryoneElse(0, 1)
  sim.place(0, 8, 6)
  sim.place(1, 10, 6)
  # A clean line to the next cog.
  let hit = sim.board.traceBeam(8, 6, dirE, 4, sim.occupied)
  check(hit.hit and hit.seat == 1 and hit.dist == 2,
    "the beam did not find the cog two cells east")
  # A pillar in the way stops it. Pillar E covers (11..12, 6..7).
  sim.place(1, 14, 6)
  let blocked = sim.board.traceBeam(9, 6, dirE, 4, sim.occupied)
  check(not blocked.hit, "the beam passed through pillar E")
  # It never leaves the board: firing west from x = 1 walks into the ring.
  sim.place(0, 1, 6)
  let wall = sim.board.traceBeam(1, 6, dirW, 4, sim.occupied)
  check(not wall.hit, "the beam left the board through the west wall")
  # A third cog in between takes the beam.
  sim.place(0, 2, 2)
  sim.place(1, 5, 2)
  sim.place(2, 4, 2)
  let third = sim.board.traceBeam(2, 2, dirE, 4, sim.occupied)
  check(third.hit and third.seat == 2,
    "the beam passed through the third cog instead of hitting it")
  banner "the beam stops at walls, pillars and the first cog"

block openFloorRemovesExactlyTwentyCells:
  let
    withPillars = initBoard(variantConfig("refinery"))
    without = initBoard(variantConfig("open-floor"))
  var removed = 0
  for i in 0 ..< withPillars.blocked.len:
    if withPillars.blocked[i] and not without.blocked[i]:
      inc removed
    check(not (without.blocked[i] and not withPillars.blocked[i]),
      "open-floor blocked a cell the default board leaves open")
  check(removed == 20, "open-floor removed " & $removed & " cells, expected 20")
  check(without.pads == withPillars.pads, "open-floor moved the pads")
  check(without.spawns == withPillars.spawns, "open-floor moved the spawns")
  banner "pillars: 0 removes exactly 20 cells and changes nothing else"

echo "test_board OK"

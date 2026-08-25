## The public gift ledger: who gave whom how much, who defected, and the
## reciprocity index.
##
## New in this coworld (there is no `coworld-ctf` counterpart). It is a
## separate module because it is read by four different consumers -- the
## observation, the results document, the viewer's trust graph, and
## `tests/test_ledger.nim`'s "rebuilt from events[] alone equals the live
## ledger" check -- and every one of them must agree to the token.

import ./sim_types

type
  Ledger* = object
    ## `given[a][b]` is the number of TOKENS seat a has spent gifting seat b
    ## (one per connected beam); `got[a][b]` is the number that LANDED in b's
    ## inventory from a, after any invCap loss. `beams[a][b]` counts connected
    ## beams. `lastRound[a][b]` is the round a last gave to b, or -1.
    given*: array[SeatCount, array[SeatCount, int]]
    got*: array[SeatCount, array[SeatCount, int]]
    beams*: array[SeatCount, array[SeatCount, int]]
    lastRound*: array[SeatCount, array[SeatCount, int]]
    roundGot*: array[SeatCount, array[SeatCount, int]]
      ## TOKENS that landed on a from b during the round that just closed.
      ## This is the design note's `gaveYouLastRound(P)`, and it is TOKENS, not
      ## beams: the worked ladder ("B beams those three back, one at a time")
      ## only comes out right if a cog that received three refined from one
      ## beam returns three beams.
    pendingGot*: array[SeatCount, array[SeatCount, int]]
      ## tokens a has received from b during the round in progress
    defected*: array[SeatCount, array[SeatCount, bool]]
      ## a `defect` row has already fired for this ordered pair

proc initLedger*(): Ledger =
  for a in 0 ..< SeatCount:
    for b in 0 ..< SeatCount:
      result.lastRound[a][b] = -1

proc recordGift*(
  ledger: var Ledger, fromSeat, toSeat, tokensSpent, tokensLanded, round: int
) =
  ledger.given[fromSeat][toSeat] += tokensSpent
  ledger.got[toSeat][fromSeat] += tokensLanded
  ledger.beams[fromSeat][toSeat] += 1
  ledger.pendingGot[toSeat][fromSeat] += tokensLanded
  ledger.lastRound[fromSeat][toSeat] = round

proc closeRound*(ledger: var Ledger) =
  ## Rolls the in-progress receipts into "last round" and clears them. The
  ## `reciprocator` baseline returns exactly what it was sent LAST round, so
  ## this boundary is load-bearing.
  for a in 0 ..< SeatCount:
    for b in 0 ..< SeatCount:
      ledger.roundGot[a][b] = ledger.pendingGot[a][b]
      ledger.pendingGot[a][b] = 0

proc youGave*(ledger: Ledger, seat, other: int): int =
  ledger.given[seat][other]

proc gaveYou*(ledger: Ledger, seat, other: int): int =
  ledger.got[seat][other]

proc net*(ledger: Ledger, seat, other: int): int =
  ledger.got[seat][other] - ledger.given[seat][other]

proc defectionsAt*(
  ledger: var Ledger, seat: int
): seq[int] =
  ## The ordered pairs (seat -> other) that become a `defect` the moment `seat`
  ## consumes: it has taken at least 3 tokens from `other` and returned none,
  ## and no row has fired for this pair yet. At most one row per ordered pair
  ## per episode.
  for other in 0 ..< SeatCount:
    if other == seat or ledger.defected[seat][other]:
      continue
    if ledger.got[seat][other] >= 3 and ledger.given[seat][other] == 0:
      ledger.defected[seat][other] = true
      result.add(other)

proc reciprocityX100*(givenTotal, receivedTotal: int): int =
  ## `100 * min(given, received) div max(given, received, 1)`. Both-zero is 0,
  ## which is the honest reading: a seat that never traded has no reciprocity
  ## to report, not a perfect one.
  100 * min(givenTotal, receivedTotal) div max(max(givenTotal, receivedTotal), 1)

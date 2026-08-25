## The event vocabulary and its ONE serializer.
##
## Forked from `coworld-ctf/src/ctf/events.nim`, and it keeps that file's
## contract: live emission and any re-derivation must produce BYTE-IDENTICAL
## rows. A consumer cannot be asked to tell them apart, and a second serializer
## would drift the moment a field is added.
##
## Every gift, every consume and every defection being an event is what
## discharges the idea's integrity clause: the trust graph is reconstructible
## from the bytes alone.

import std/json

import ./sim_types

type
  EventKind* = enum
    evSpawn = "spawn"
    evConsume = "consume"
    evGift = "gift"
    evGiftMiss = "giftmiss"
    evSpill = "spill"
    evCollect = "collect"
    evDefect = "defect"
    evAutobank = "autobank"
    evOrder = "order"
    evRound = "round"
    evEnd = "end"

  GiftEvent* = object
    ## One row of the replay's `events[]`. `t` is the tick and `seat` the slot;
    ## levels are integers 0 | 1 | 2.
    kind*: EventKind
    t*: int
    seat*: int
    x*, y*: int
    n*: int
    l0*, l1*, l2*: int
    score*: int
    fromSeat*, toSeat*: int
    sent*, got*: int
    fx*, fy*, tx*, ty*, dist*: int
    dir*: string
    lvl*, lost*: int
    cause*: string
    onSeat*: int
    round*: int
    job*, target*, consume*: string
    gift*: int
    clamped*: bool
    source*: string
    say*, notes*: string
    latencyMs*: int
    scores*: seq[int]
    heldPer*: seq[int]
    gifts*, minted*, banked*: int
    reason*, ending*: string

proc jsonRow*(event: GiftEvent): JsonNode =
  ## One JSON row for one event. Only the fields the kind declares are emitted,
  ## so a consumer can switch on `k` and know exactly what it has.
  result = %*{"k": $event.kind, "t": event.t}
  case event.kind
  of evSpawn:
    result["x"] = %event.x
    result["y"] = %event.y
  of evConsume:
    result["seat"] = %event.seat
    result["n"] = %event.n
    result["l0"] = %event.l0
    result["l1"] = %event.l1
    result["l2"] = %event.l2
    result["score"] = %event.score
  of evGift:
    result["from"] = %event.fromSeat
    result["to"] = %event.toSeat
    result["sent"] = %event.sent
    result["got"] = %event.got
    result["n"] = %event.n
    result["fx"] = %event.fx
    result["fy"] = %event.fy
    result["tx"] = %event.tx
    result["ty"] = %event.ty
    result["dist"] = %event.dist
  of evGiftMiss:
    result["seat"] = %event.seat
    result["dir"] = %event.dir
  of evSpill:
    result["seat"] = %event.seat
    result["lvl"] = %event.lvl
    result["lost"] = %event.lost
    result["cause"] = %event.cause
  of evCollect:
    result["seat"] = %event.seat
    result["x"] = %event.x
    result["y"] = %event.y
  of evDefect:
    result["seat"] = %event.seat
    result["on"] = %event.onSeat
  of evAutobank:
    result["seat"] = %event.seat
    result["n"] = %event.n
    result["score"] = %event.score
  of evOrder:
    result["seat"] = %event.seat
    result["round"] = %event.round
    result["job"] = %event.job
    result["target"] =
      if event.target.len == 0: newJNull() else: %event.target
    result["gift"] = %event.gift
    result["consume"] = %event.consume
    result["clamped"] = %event.clamped
    result["source"] = %event.source
    result["say"] = %event.say
    result["notes"] = %event.notes
    result["latencyMs"] = %event.latencyMs
  of evRound:
    result["round"] = %event.round
    result["scores"] = %event.scores
    result["held"] = %event.heldPer
    result["gifts"] = %event.gifts
    result["minted"] = %event.minted
    result["banked"] = %event.banked
  of evEnd:
    result["reason"] = %event.reason
    result["ending"] = %event.ending
    result["scores"] = %event.scores

proc eventsJson*(events: openArray[GiftEvent]): JsonNode =
  result = newJArray()
  for event in events:
    result.add(event.jsonRow())

proc spawnEvent*(t, x, y: int): GiftEvent =
  GiftEvent(kind: evSpawn, t: t, x: x, y: y)

proc collectEvent*(t, seat, x, y: int): GiftEvent =
  GiftEvent(kind: evCollect, t: t, seat: seat, x: x, y: y)

proc consumeEvent*(t, seat, l0, l1, l2, score: int): GiftEvent =
  GiftEvent(kind: evConsume, t: t, seat: seat, n: l0 + l1 + l2,
            l0: l0, l1: l1, l2: l2, score: score)

proc autobankEvent*(t, seat, n, score: int): GiftEvent =
  GiftEvent(kind: evAutobank, t: t, seat: seat, n: n, score: score)

proc giftEvent*(
  t, fromSeat, toSeat, sent, got, n, fx, fy, tx, ty, dist: int
): GiftEvent =
  GiftEvent(kind: evGift, t: t, fromSeat: fromSeat, toSeat: toSeat,
            sent: sent, got: got, n: n, fx: fx, fy: fy, tx: tx, ty: ty,
            dist: dist)

proc giftMissEvent*(t, seat: int, dir: string): GiftEvent =
  GiftEvent(kind: evGiftMiss, t: t, seat: seat, dir: dir)

proc spillEvent*(t, seat, lvl, lost: int, cause: string): GiftEvent =
  GiftEvent(kind: evSpill, t: t, seat: seat, lvl: lvl, lost: lost, cause: cause)

proc defectEvent*(t, seat, onSeat: int): GiftEvent =
  GiftEvent(kind: evDefect, t: t, seat: seat, onSeat: onSeat)

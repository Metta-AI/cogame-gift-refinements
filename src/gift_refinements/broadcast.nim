## The broadcast chrome frame: `BroadcastTracker` + `buildStateJson`.
##
## Forked from `coworld-ctf/src/ctf/broadcast.nim` -- same shape, same job.
## `teams` becomes the two headline plates (`gifts` and `banked`), `roster` the
## six cogs, `lead` the tokens-in-play series, plus the appended `gr` block that
## carries the trust graph and the round clock.
##
## The tracker accumulates ONLY from `events[]`, and `resync` rebuilds it from
## the event stream up to any tick. That is what makes the viewer's trust graph
## seek-accurate: scrubbing back un-draws a defection, because the graph is
## rebuilt from the rows up to the playhead rather than remembered.

import std/[json, strutils]

import ./sim_types, ./ledger

type
  TrustEdge* = object
    a*, b*: int                ## a < b
    aToB*, bToA*: int          ## tokens moved each way
    defectedA*, defectedB*: bool

  BroadcastTracker* = object
    giftsGiven*: int
    tokensBanked*: int
    minted*: int
    defections*: int
    sent*: array[SeatCount, int]
    received*: array[SeatCount, int]
    banked*: array[SeatCount, int]
    seatDefections*: array[SeatCount, int]
    edges*: array[SeatCount, array[SeatCount, int]]  ## tokens a landed on b
    defectedPair*: array[SeatCount, array[SeatCount, bool]]

proc initBroadcastTracker*(): BroadcastTracker = BroadcastTracker()

proc ingest*(tracker: var BroadcastTracker, event: JsonNode) =
  ## One event row. Idempotence is the CALLER's job (`resync` clears first):
  ## the tracker is a pure fold over the stream, which is what lets a seek
  ## replay it from zero and land on exactly the same numbers.
  case event{"k"}.getStr()
  of "gift":
    let
      fromSeat = int(event{"from"}.getBiggestInt())
      toSeat = int(event{"to"}.getBiggestInt())
      n = int(event{"n"}.getBiggestInt())
    if fromSeat notin 0 ..< SeatCount or toSeat notin 0 ..< SeatCount:
      return
    tracker.giftsGiven += 1
    tracker.minted += n
    tracker.sent[fromSeat] += 1
    tracker.received[toSeat] += n
    tracker.edges[fromSeat][toSeat] += n
  of "consume", "autobank":
    let
      seat = int(event{"seat"}.getBiggestInt())
      n = int(event{"n"}.getBiggestInt())
    if seat notin 0 ..< SeatCount:
      return
    tracker.tokensBanked += n
    tracker.banked[seat] += n
  of "defect":
    let
      seat = int(event{"seat"}.getBiggestInt())
      onSeat = int(event{"on"}.getBiggestInt())
    if seat notin 0 ..< SeatCount or onSeat notin 0 ..< SeatCount:
      return
    tracker.defections += 1
    tracker.seatDefections[seat] += 1
    tracker.defectedPair[seat][onSeat] = true
  else:
    discard

proc resync*(tracker: var BroadcastTracker, events: JsonNode, throughTick: int) =
  ## Rebuild from the whole stream up to and including `throughTick`.
  tracker = initBroadcastTracker()
  if events.isNil:
    return
  for event in events:
    if int(event{"t"}.getBiggestInt()) > throughTick:
      break
    tracker.ingest(event)

proc trustEdges*(tracker: BroadcastTracker): seq[TrustEdge] =
  ## Every pair that has ever gifted, heaviest first. Both directions ride one
  ## edge so the viewer can colour it: green when the two are within 2x of each
  ## other, amber when one-sided but young, red once a defection fired on it.
  for a in 0 ..< SeatCount:
    for b in a + 1 ..< SeatCount:
      let
        ab = tracker.edges[a][b]
        ba = tracker.edges[b][a]
      if ab == 0 and ba == 0:
        continue
      result.add(TrustEdge(a: a, b: b, aToB: ab, bToA: ba,
        defectedA: tracker.defectedPair[a][b],
        defectedB: tracker.defectedPair[b][a]))
  for i in 1 ..< result.len:
    let key = result[i]
    var j = i - 1
    while j >= 0 and result[j].aToB + result[j].bToA < key.aToB + key.bToA:
      result[j + 1] = result[j]
      dec j
    result[j + 1] = key

proc rosterJson*(
  scene: Scene, frame: ViewFrame, tracker: BroadcastTracker
): JsonNode =
  ## Six chips. `name` carries the in-game ALIAS and `pol` the POLICY name --
  ## both name spaces, on the one surface that is allowed to show the second.
  result = newJArray()
  for slot in 0 ..< SeatCount:
    let cog = frame.cogs[slot]
    result.add(%*{
      "s": slot,
      # `team` is deliberately empty: the two plates are TOTALS, not sides, so
      # no cog belongs to one. The inherited squad-pip strip therefore renders
      # nothing and the appended roster strip owns the per-cog readout.
      "team": "",
      "name": scene.names[slot],
      "alias": scene.names[slot],
      "pol": scene.policyNames[slot],
      "col": scene.colors[slot],
      "alive": true,
      "lives": 0,
      "score": cog.score,
      "t0": cog.tokens[0],
      "t1": cog.tokens[1],
      "t2": cog.tokens[2],
      "sent": tracker.sent[slot],
      "recv": tracker.received[slot],
      "def": tracker.seatDefections[slot],
      "recip": reciprocityX100(tracker.sent[slot], tracker.received[slot])
    })

proc trustJson*(tracker: BroadcastTracker): JsonNode =
  result = newJArray()
  for edge in tracker.trustEdges():
    result.add(%*{
      "a": edge.a, "b": edge.b, "ab": edge.aToB, "ba": edge.bToA,
      "da": edge.defectedA, "db": edge.defectedB
    })

proc buildStateJson*(
  scene: Scene,
  frame: ViewFrame,
  tracker: BroadcastTracker,
  events: JsonNode,
  playing: bool,
  speed: float,
  maxTick: int,
  looping, transportEnabled: bool,
  over: JsonNode = nil,
  leadSeries: seq[array[2, int]] = @[],
  beats: JsonNode = nil
): string =
  ## The chrome frame. Board-derived STATE (the plates, the roster, the trust
  ## graph, the verdict) is always present, so a frame reached by a SEEK still
  ## hydrates the whole HUD with no events at all.
  let
    ticksPerRound = max(1, scene.ticksPerRound)
    roundNow = min(scene.rounds, frame.tick div ticksPerRound + 1)
  var state = %*{
    "t": frame.tick,
    "mt": scene.rounds * ticksPerRound,
    "ph": (if over.isNil: "playing" else: "gameover"),
    "lob": 0,
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": 0,
    "lp": looping,
    "sk": false,
    "ff": false,
    "en": transportEnabled,
    "mm": -1,
    "bs": 1,
    "pov": -1,
    "teams": {
      "gifts": {
        "policies": ["GIFTS GIVEN"],
        "lives": tracker.giftsGiven,
        "minted": tracker.minted,
        "def": tracker.defections
      },
      "banked": {
        "policies": ["TOKENS BANKED"],
        "lives": tracker.tokensBanked,
        "minted": tracker.minted,
        "def": tracker.defections
      }
    },
    "roster": rosterJson(scene, frame, tracker),
    "events": (if events.isNil: newJArray() else: events),
    "gr": {
      "round": roundNow,
      "rounds": scene.rounds,
      "ticksPerRound": ticksPerRound,
      "variant": scene.variant,
      "minted": tracker.minted,
      "gifts": tracker.giftsGiven,
      "banked": tracker.tokensBanked,
      "defections": tracker.defections,
      "invCap": scene.invCap,
      "trust": trustJson(tracker)
    }
  }
  if leadSeries.len > 0:
    var pts = newJArray()
    for row in leadSeries:
      pts.add(%[row[0], row[1]])
    state["lead"] = %*{"teams": ["pool"], "pts": pts}
  if not beats.isNil and beats.len > 0:
    state["beats"] = beats
  if not over.isNil:
    state["over"] = over
  $state

proc overJson*(
  scene: Scene, results: JsonNode, tracker: BroadcastTracker, tick: int
): JsonNode =
  ## The end-card is STATE, not an event, so a viewer who seeks straight to the
  ## end still sees the verdict.
  var
    winner = ""
    winnerPolicy = ""
    best = -1
    draws = 0
  let scores = results{"scores"}
  if not scores.isNil and scores.kind == JArray:
    for slot in 0 ..< min(SeatCount, scores.len):
      let value = int(scores[slot].getBiggestInt())
      if value > best:
        best = value
        winner = scene.names[slot]
        winnerPolicy = scene.policyNames[slot]
        draws = 1
      elif value == best:
        inc draws
  var rows = newJArray()
  if not scores.isNil and scores.kind == JArray:
    for slot in 0 ..< min(SeatCount, scores.len):
      rows.add(%*{
        "alias": scene.names[slot],
        "pol": scene.policyNames[slot],
        "score": int(scores[slot].getBiggestInt())
      })
  %*{
    "winner": winner,
    "winnerPol": winnerPolicy,
    "draw": draws > 1,
    "timeLimit": results{"reason"}.getStr() == "deadline",
    "reason": results{"reason"}.getStr(),
    "ending": results{"ending"}.getStr(),
    "endingText":
      (if results{"ending"}.getStr() == "round_limit": "ROUND LIMIT"
       elif results{"ending"}.getStr() == "deadline": "TIME"
       else: results{"ending"}.getStr().toUpperAscii()),
    "scores": rows,
    "gifts": tracker.giftsGiven,
    "minted": tracker.minted,
    "banked": tracker.tokensBanked,
    "defections": tracker.defections,
    "collected": results{"collected"},
    "teams": {"gifts": {"lives": tracker.giftsGiven},
              "banked": {"lives": tracker.tokensBanked}},
    "t": tick
  }

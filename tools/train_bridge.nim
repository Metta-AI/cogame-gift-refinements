## Persistent JSONL bridge for Metta RL and native PufferLib training.
## nim c -d:release --path:src -o:gift-train-bridge tools/train_bridge.nim

import std/[json, os]
import gift_refinements/[sim_types, sim_config, sim, orders, scripted, decide,
  events, kernel]

const OperatorPrompt = "Choose legal standing orders to maximize your score over the complete game."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: SimServer, seat, id: int): JsonNode =
  let view = game.seatView(seat)
  let scene = game.scene()
  %*{
    "kind": "decision", "game": "gift-refinements",
    "decision_id": id, "seat": seat, "engine_seat": seat,
    "turn": game.round,
    "semantic_view": observationJson(view, scene),
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(view, scene)},
      {"role": "user", "content": userPrompt(view, scene, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object",
      "required": ["job", "target", "gift", "consume"],
      "properties": {
        "job": {"type": "string", "enum": ["collect", "meet", "hold", "evade"]},
        "target": {"type": "string"},
        "gift": {"type": "integer"},
        "consume": {"type": "string", "enum": ["now", "end", "never"]}
      }},
    "typed_question": newJNull()
  }

proc encoding(game: SimServer, seat, id: int): JsonNode =
  let view = game.seatView(seat)
  var values = newJArray()
  for variant in ["refinery", "scarce", "long-beam", "open-floor"]:
    values.add(%(if game.config.variant == variant: 1 else: 0))
  for slot in 0 ..< SeatCount:
    values.add(%(if seat == slot: 1 else: 0))
  for value in [view.round, view.rounds, view.roundsLeft,
      view.x, view.y, view.tokens[0], view.tokens[1], view.tokens[2],
      view.held, view.rawestLevel, view.score, view.beamsPerRound,
      view.invCap, view.giftMultiplier, view.maxLevel, game.config.beamRange]:
    values.add(%value)
  values.add(%(if view.hasLastOrder: 1 else: 0))
  values.add(%ord(view.lastOrder.job))
  values.add(%view.lastOrder.target)
  values.add(%view.lastOrder.gift)
  values.add(%ord(view.lastOrder.consume))
  for peer in view.peers:
    for value in [peer.slot, peer.x, peer.y, peer.dist,
        (if peer.hittable: 1 else: 0), peer.score, peer.youGave,
        peer.gaveYou, peer.net, peer.lastGaveYouRound,
        peer.bankedLastRound]:
      values.add(%value)
  for blocked in game.board.blocked:
    values.add(%(if blocked: 1 else: 0))
  for pad in game.board.pads:
    var loose = false
    for item in view.loose:
      if item.x == pad.x and item.y == pad.y:
        loose = true
    values.add(%pad.x)
    values.add(%pad.y)
    values.add(%(if loose: 1 else: 0))
  for row in view.ledgerTail:
    for value in [row.r, row.fromSeat, row.toSeat, row.sent, row.got, row.n]:
      values.add(%value)
  for missing in view.ledgerTail.len ..< 16:
    for field in 0 ..< 6:
      values.add(%0)
  for row in view.bankTail:
    for value in [row.r, row.seat, row.n]:
      values.add(%value)
  for missing in view.bankTail.len ..< 8:
    for field in 0 ..< 3:
      values.add(%0)
  for row in view.history:
    for value in [row.round, row.collected, row.sent, row.received,
        row.banked, row.heldAfter, row.score]:
      values.add(%value)
  for missing in view.history.len ..< 24:
    for field in 0 ..< 7:
      values.add(%0)
  var targetChoices = newJArray()
  for other in 0 ..< SeatCount:
    if other != seat:
      targetChoices.add(%game.aliases[other])
  var gifts = newJArray()
  for gift in 0 .. game.config.maxBeamsPerRound:
    gifts.add(%gift)
  %*{"decision_id": id, "values": values, "action_heads": [
    {"name": "job", "choices": ["collect", "meet", "hold", "evade"]},
    {"name": "target", "choices": targetChoices},
    {"name": "gift", "choices": gifts},
    {"name": "consume", "choices": ["now", "end", "never"]}
  ]}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: gift-train-bridge MANIFEST [variant]", 1)
  let variant = if args.len == 2: args[1] else: "refinery"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: SimServer
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == SeatCount
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3", "t4", "t5"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = initSimServer(config)
      seat = 0
      id = 0
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.finished
      response = game.encoding(seat, id)
    of "teacher":
      doAssert not game.finished
      let view = game.seatView(seat)
      let order = scriptedOrder(
        if seat mod 2 == 0: blReciprocator else: blHoarder,
        view, game.config.maxBeamsPerRound)
      let target = if order.target < 0:
        (if seat == 0: 1 else: 0) else: order.target
      response = %*{"response": $(%*{
        "job": $order.job, "target": game.aliases[target],
        "gift": order.gift, "consume": $order.consume})}
    of "step":
      doAssert not game.finished and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      var completion = copy(action)
      completion["say"] = %""
      completion["notes"] = %""
      var parsed = parseOrder(completion, seat, game.aliases,
        game.config.maxBeamsPerRound)
      doAssert not parsed.clamped
      if parsed.gift == 0 and parsed.job != jobMeet:
        parsed.target = -1
      parsed.source = osScripted
      game.orders[seat] = parsed
      game.haveOrder[seat] = true
      game.events.add(GiftEvent(
        kind: evOrder, t: game.tick, seat: seat, round: game.round + 1,
        job: $parsed.job, target: parsed.targetAlias(game.aliases),
        gift: parsed.gift, consume: $parsed.consume, clamped: parsed.clamped,
        source: $parsed.source, say: "", notes: ""))
      inc seat
      if seat == SeatCount:
        for tick in 0 ..< game.config.ticksPerRound:
          game.stepWithKernel()
        game.closeRound()
        seat = 0
        if game.round == game.config.rounds:
          game.finish(erComplete)
      inc id
      var observation: JsonNode
      if game.finished:
        let outcome = game.resultsJson()
        var scores = newJObject()
        for slot in 0 ..< SeatCount:
          scores[$slot] = outcome["scores"][slot]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()

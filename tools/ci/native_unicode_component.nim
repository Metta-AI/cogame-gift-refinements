## Partial real central-engine/kernel/writer system probe; never a full game.
import std/[base64, json, monotimes, os, times]
import gift_refinements/[decide, events, kernel, orders, prompts, sim, sim_config, sim_types, training_capture]
let outDir = commandLineParams()[0]
let root = commandLineParams()[1]
var node: JsonNode
for task in parseFile(root / "coworld_manifest_template.json")["variants"]:
  if task["id"].getStr() == "open-floor": node = copy(task["game_config"])
doAssert node != nil
node["seed"] = %1
node["tokens"] = %*["local0", "local1", "local2", "local3", "local4", "local5"]
var config = defaultGameConfig()
config.update($node)
var game = initSimServer(config)
var engine = initDecisionEngine(game, promptSelection(node), true)
for seat in 0 ..< SeatCount:
  engine.seats[seat].isLlm = true
  engine.seats[seat].registered = true
  engine.seats[seat].label = "local Unicode sentinel"
  engine.seats[seat].prompt = "Local encoding system test only."
let capture = newMatchCapture(config)
var snapshots = newJArray()
let started = getMonoTime()
for round in 0 .. 1:
  discard engine.turn(game, round, (getMonoTime() - started).inSeconds.int)
  capture.beginRound(engine, game, round)
  for seat in 0 ..< SeatCount:
    let order = game.orders[seat]
    game.events.add(GiftEvent(kind: evOrder, t: game.tick, seat: seat, round: round,
      job: $order.job, target: order.targetAlias(game.aliases), gift: order.gift,
      consume: $order.consume, clamped: order.clamped, source: $order.source,
      say: order.say, notes: order.notes, latencyMs: order.latencyMs))
    snapshots.add(%*{"round":round, "seat":seat,
      "installed_action_json_b64":encode($order.orderJson(game.aliases))})
  for tick in 0 ..< config.ticksPerRound:
    let actions = game.kernelActions()
    game.step(actions)
    capture.recordTick(actions, game)
  game.closeRound()
  capture.finishRound(game)
game.settleEarly()
game.finish(erDeadline)
capture.finishMatch(game, getEnv("COGAME_SAVE_TRAJECTORY_URI"))
writeFile(outDir / "native-summary.json", pretty(%*{"partial":true,"complete_game":false,
  "configured_rounds":config.rounds,"rounds_applied":game.round,"ticks":game.tick,
  "reason": $game.reason,"fallbacks":engine.fallbacks,"notes":snapshots}))

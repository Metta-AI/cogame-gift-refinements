## Independently re-run a complete native game with reciprocator filler seats.
## Usage: check_native_capture CONFIG TRAJECTORY REPLAY OPERATOR_PROMPT [VIEWER_PACKETS...]
import std/[base64, json, os, strutils]
import bitworld/spriteprotocol
import gift_refinements/[sim_types, sim_config, sim, orders, scripted, decide, kernel,
  prompts, replays, global]

let args = commandLineParams()
proc checkViewerPacket(path: string, requireLead: bool) =
  let raw = readFile(path)
  doAssert raw.len > 0 and raw.len < 1024 * 1024
  var packet: seq[uint8]
  raw.blobToBytes(packet)
  var sprites, objects, chrome = 0
  for message in parseSpritePacket(packet):
    case message.kind
    of spkSprite:
      inc sprites
      if message.sprite.id == BroadcastChromeSpriteId:
        let state = parseJson(message.sprite.label)
        if requireLead:
          doAssert state.hasKey("lead") and state["lead"]["pts"].len > 0,
            "early viewer never received the first physical frame's lead series"
        inc chrome
    of spkObject: inc objects
    else: discard
  doAssert sprites > 0 and objects > 0 and chrome == 1,
    "initial/current live packet must contain a complete sprite scene and chrome"

if args.len == 2 and args[0] == "--viewer-first-frame":
  checkViewerPacket(args[1], true)
  echo "first physical viewer frame contains its lead history"
  quit(0)
doAssert args.len >= 4
for path in args[4 ..< args.len]:
  checkViewerPacket(path, path.endsWith("global-first-physical.bin"))
var config = defaultGameConfig()
config.update(readFile(args[0]))
var game = initSimServer(config)
let replay = parseFile(args[2])
for seat in 0 ..< SeatCount: game.policyNames[seat] = replay["policyNames"][seat].getStr()
var rows: seq[JsonNode]
var summary: JsonNode
for line in lines(args[1]):
  let row = parseJson(line)
  if row["event_type"].getStr() == "decision": rows.add(row)
  else: summary = row
let selection = promptSelection(parseJson(readFile(args[0])))
doAssert rows.len == config.rounds * SeatCount
var promptsChecked = 0
for round in 1 .. config.rounds:
  var executions: array[SeatCount, JsonNode]
  var controls: array[SeatCount, string]
  var decisions: array[SeatCount, JsonNode]
  # Freeze every native private view before any of the simultaneous orders.
  for seat in 0 ..< SeatCount:
    let row = rows[(round - 1) * SeatCount + seat]
    decisions[seat] = row
    doAssert row["seat"].getStr() == $seat
    var view = copy(row["observation"])
    for field in ["execution", "prompt_template", "scenario_family"]: view.delete(field)
    let actual = observationJson(game.seatView(seat), game.scene())
    doAssert view == actual, "private view differs at " & row["decision_id"].getStr()
    doAssert row["observation"]["scenario_family"].getStr() == scenarioFamily(config)
    let system = systemPrompt(game.seatView(seat), game.scene(), selection)
    var selected: JsonNode
    for attempt in row["attempts"]:
      var user = userPrompt(game.seatView(seat), game.scene(), args[3])
      if attempt["attempt_id"].getStr().endsWith("-2"):
        user.add("\n\nYour previous reply was invalid. Respond with ONLY the requested JSON object, using one of the listed job values, one of the listed target aliases, a gift count between 0 and 10, and one of now/end/never.")
      doAssert attempt["request"]["system"].getStr() == system
      doAssert attempt["request"]["messages"] == %*[{"role": "user", "content": user}]
      doAssert attempt["request"]["max_tokens"].getInt() == config.maxOutputTokens
      inc promptsChecked
      if attempt["attempt_id"] == row["selected_attempt_id"] or
          (row["action_status"].getStr() == "rejected" and
            attempt["parsed_action"] == row["executed_action"]):
        selected = attempt
    var order: Order
    if selected != nil:
      order = parseOrder(extractJsonObject(selected["response"].getStr()), seat,
        game.aliases, config.maxBeamsPerRound)
      order.source = if selected["attempt_id"].getStr().endsWith("-2"): osRetry else: osLlm
    else:
      order = scriptedOrder(blReciprocator, game.seatView(seat), config.maxBeamsPerRound)
      if row["action_status"].getStr() == "fallback": order.source = osFallback
    doAssert order.orderJson(game.aliases) == row["executed_action"]
    game.orders[seat] = order
    game.haveOrder[seat] = true
    executions[seat] = row["observation"]["execution"]
    controls[seat] = decode(executions[seat]["seat_controls_b64"].getStr())
    doAssert $game.hash == executions[seat]["observation_hash"].getStr()
  for offset in 0 ..< config.ticksPerRound:
    let actions = game.kernelActions()
    game.step(actions)
    for seat in 0 ..< SeatCount:
      doAssert ord(actions[seat]) == int(uint8(controls[seat][offset]))
      doAssert $game.hash == executions[seat]["post_tick_hashes"][offset].getStr()
  game.closeRound()
game.finish(erComplete)
let reproduced = game.buildReplayJson()
doAssert reproduced["frames"] == replay["frames"], "native physics frames differ"
doAssert game.resultsJson() == summary["outcome"], "native outcomes differ"
echo pretty(%*{"ticks": game.tick, "decisions": rows.len, "prompt_requests": promptsChecked,
  "all_views_controls_hashes_frames_outcomes_verified": true, "scenario_family": scenarioFamily(config)})

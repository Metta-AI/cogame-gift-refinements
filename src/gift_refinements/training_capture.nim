## Private authoritative native decisions, written after their actual kernel ticks.
import std/[base64, json, options, os]
import ./decision_trajectory, ./decide, ./sim_types, ./sim_config, ./sim, ./orders
import ./prompts

type
  MatchCapture* = ref object
    trajectory*: DecisionTrajectory
    decisions: array[SeatCount, RoundDecision]
    issued: array[SeatCount, JsonNode]
    controls: array[SeatCount, string]
    hashes: seq[string]
    startTick, round: int
    startHash: uint64

proc newMatchCapture*(config: GameConfig): MatchCapture =
  MatchCapture(trajectory: newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
    scenarioFamily(config), GameName, getEnv("COWORLD_GAME_VERSION"),
    getEnv("COWORLD_SOURCE_REVISION")))

proc beginRound*(capture: MatchCapture, engine: DecisionEngine, sim: SimServer,
    round: int) =
  capture.decisions = engine.decisions
  capture.startTick = sim.tick
  capture.round = round
  capture.startHash = sim.hash
  capture.hashes = @[]
  for seat in 0 ..< SeatCount:
    capture.issued[seat] = sim.orders[seat].orderJson(sim.aliases)
    capture.controls[seat] = ""

proc recordTick*(capture: MatchCapture, actions: array[SeatCount, Action], sim: SimServer) =
  ## These are the exact simultaneous actions just passed to sim.step, not re-derived controls.
  for seat in 0 ..< SeatCount:
    capture.controls[seat].add(char(ord(actions[seat])))
  capture.hashes.add($sim.hash)

proc finishRound*(capture: MatchCapture, sim: SimServer) =
  doAssert sim.tick > capture.startTick
  doAssert capture.hashes.len == sim.tick - capture.startTick
  for seat in 0 ..< SeatCount:
    let actual = sim.orders[seat].orderJson(sim.aliases)
    doAssert actual == capture.issued[seat], "applied standing order changed during native ticks"
    let decision = capture.decisions[seat]
    var observation = copy(decision.observation)
    observation["execution"] = %*{"start_tick": capture.startTick, "end_tick": sim.tick,
      "tick_hz": TargetFps, "control_encoding": "gift-action-enum-u8-v1",
      "seat_controls_b64": encode(capture.controls[seat]),
      "observation_hash": $capture.startHash, "post_tick_hashes": capture.hashes}
    var names = newJArray()
    for action in Action: names.add(%($action))
    observation["execution"]["action_names"] = names
    capture.trajectory.recordDecision($capture.round & "-" & $seat, $seat, observation,
      decision.attempts, decision.selectedAttemptId, actual, decision.status,
      sim.round >= sim.config.rounds,
      if decision.status == asFallback: some("engine-reciprocator") else: none(string))

proc finishMatch*(capture: MatchCapture, sim: SimServer, destination: string) =
  let outcome = sim.resultsJson()
  var participants = newJArray()
  for seat in 0 ..< SeatCount:
    participants.add(%*{"seat": $seat, "score": outcome["scores"][seat], "win": outcome["win"][seat]})
  let status = case sim.reason
    of erComplete: esCompleted
    of erDeadline: esTruncated
    else: esFailed
  capture.trajectory.finish(status, outcome, participants)
  capture.trajectory.writeEventsToUri(destination)

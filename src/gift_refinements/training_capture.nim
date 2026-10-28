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
    failed: bool
    errors: seq[string]

proc newMatchCapture*(config: GameConfig): MatchCapture =
  for key in ["COWORLD_EPISODE_ID", "COWORLD_GAME_VERSION", "COWORLD_SOURCE_REVISION", "COWORLD_GAME_NAME"]:
    if not scalarUtf8(getEnv(key)):
      raise newException(ValueError, "non-Unicode private trajectory identity: " & key)
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
    var actual = sim.orders[seat].orderJson(sim.aliases)
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
    var attempts = decision.attempts
    var selected = decision.selectedAttemptId
    var status = decision.status
    var originalAttempts = newJArray()
    for evidence in attempts: originalAttempts.add(attemptEvidenceJson(evidence))
    let original = %*{"observation": observation, "attempts": originalAttempts,
      "executed_action": actual, "actual_scripted": sim.orders[seat].source in {osScripted, osFallback}}
    if not scalarJson(original):
      # Keep exact native bytes. Quarantine evidence, never repair a completion or action.
      let detail = "non-Unicode native evidence; original JSON bytes retained as base64; target excluded"
      observation = %*{"capture_errors": [detail],
        "actual_scripted": sim.orders[seat].source in {osScripted, osFallback},
        "invalid_native_evidence_json_b64": encode($original)}
      attempts = @[]
      selected = none(string)
      actual = newJNull()
      if status != asFallback: status = asRejected
      capture.failed = true
      if capture.errors.len < 16: capture.errors.add(detail)
    capture.trajectory.recordDecision($capture.round & "-" & $seat, $seat, observation,
      attempts, selected, actual, status, sim.round >= sim.config.rounds,
      if status == asFallback: some("engine-reciprocator") else: none(string))

proc finishMatch*(capture: MatchCapture, sim: SimServer, destination: string) =
  let outcome = sim.resultsJson()
  var privateOutcome = copy(outcome)
  var participants = newJArray()
  for seat in 0 ..< SeatCount:
    participants.add(%*{"seat": $seat, "score": outcome["scores"][seat], "win": outcome["win"][seat]})
  if not scalarJson(outcome):
    capture.failed = true
    capture.errors.add("non-Unicode native outcome; original JSON bytes retained as base64")
    privateOutcome = %*{"invalid_native_outcome_json_b64": encode($outcome)}
  if not scalarJson(participants): participants = newJNull()
  if capture.failed: privateOutcome["capture_errors"] = %capture.errors
  let status = if capture.failed: esFailed
    else:
      case sim.reason
      of erComplete: esCompleted
      of erDeadline: esTruncated
      else: esFailed
  capture.trajectory.finish(status, privateOutcome, participants)
  capture.trajectory.writeEventsToUri(destination)

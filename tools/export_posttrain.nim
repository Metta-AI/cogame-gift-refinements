## Stream complete private candidates; shared review owns training admission.
import std/[json, os, osproc, strutils]
import gift_refinements/[sim_types, sim_config, sim, orders, scripted, decide, events, kernel, prompts, evidence]

const OperatorPrompt = "Choose legal standing orders to maximize your score over the complete game."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "refinery"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert games >= 1 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + games:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = newJArray()
      for seat in 0 ..< SeatCount: runtimeConfig["tokens"].add(%("t" & $seat))
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      var sim = initSimServer(config)
      let family = scenarioFamily(config)
      let episode = family & "-seed-" & $seed & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var count = 0
      while not sim.finished:
        let turn = sim.round + 1
        let eventStart = sim.events.len
        let scene = sim.scene()
        let snapshot = sim
        var orders: array[SeatCount, Order]
        var records: array[SeatCount, JsonNode]
        for seat in 0 ..< SeatCount:
          let system = systemPrompt(snapshot.seatView(seat), scene, selection)
          let user = userPrompt(snapshot.seatView(seat), scene, OperatorPrompt)
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          var view = observationJson(snapshot.seatView(seat), scene)
          view["scenario_family"] = %family
          view["prompt_template"] = selection.promptMetadata(system, user)
          let kind = if seat mod 2 == 0: blReciprocator else: blHoarder
          let proposal = orderJson(scriptedOrder(kind, snapshot.seatView(seat), config.maxBeamsPerRound), snapshot.aliases)
          var parsed = parseOrder(proposal, seat, snapshot.aliases, config.maxBeamsPerRound)
          parsed.source = osScripted
          orders[seat] = parsed
          let installed = orderJson(parsed, snapshot.aliases)
          let accepted = proposal == installed
          let id = count + seat
          let attemptId = $id & "-teacher"
          let attempt = %*{
            "attempt_id": attemptId, "policy": "scripted-" & $kind, "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages,
            "response": $proposal, "parsed_action": proposal, "accepted": accepted,
            "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
            "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")
          }
          records[seat] = %*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $id, "decision_index": id,
            "game": "gift-refinements", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": view, "prompt": (if accepted: messages else: newJNull()),
            "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
            "executed_action": installed, "action_status": (if accepted: "accepted" else: "fallback"),
            "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
            "terminal": false
          }
        for seat, order in orders:
          sim.installOrder(seat, order)
          sim.events.add(GiftEvent(
            kind: evOrder, t: sim.tick, seat: seat, round: turn,
            job: $order.job, target: order.targetAlias(sim.aliases), gift: order.gift,
            consume: $order.consume, clamped: order.clamped, source: $order.source,
            say: order.say, notes: order.notes))
        let startTick = sim.tick
        var actions = newJArray()
        for tick in 0 ..< config.ticksPerRound:
          let applied = sim.stepWithKernel()
          var row = newJArray()
          for action in applied: row.add(%($action))
          actions.add(row)
        sim.closeRound()
        if sim.round == config.rounds: sim.finish(erComplete)
        var frames, events, decisionIds = newJArray()
        for tick in startTick ..< sim.tick: frames.add(%sim.frames[tick])
        for index in eventStart ..< sim.events.len: events.add(sim.events[index].jsonRow())
        for seat in 0 ..< SeatCount:
          decisionIds.add(%($(count + seat)))
          records[seat]["terminal"] = %(sim.finished and seat == SeatCount - 1)
        execution.writeLine($(%*{
          "schema_version": 1, "event_type": "turn_execution", "episode_id": episode,
          "decision_ids": decisionIds, "source_revision": revision,
          "visibility": "private", "turn": turn, "start_tick": startTick, "end_tick": sim.tick,
          "event_start": eventStart, "event_end": sim.events.len, "events": events,
          "kernel_actions": actions, "frames": frames, "terminal": sim.finished}))
        for record in records: stream.writeLine($record)
        count += SeatCount
      doAssert sim.reason == erComplete
      let outcome = sim.resultsJson()
      var participants = newJObject()
      for seat in 0 ..< SeatCount: participants[$seat] = %*{"score": sim.cogs[seat].score}
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "gift-refinements", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": outcome,
        "participant_outcomes": participants
      }))
      runs.add(%*{"seed": seed, "decisions": count, "scores": outcome["scores"],
        "rounds_played": sim.round, "ticks_played": sim.tick, "ending": sim.ending})
  finally:
    execution.close()
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "gift-refinements", "variant": variant,
    "source_revision": revision, "teacher": "scripted-reciprocator-and-hoarder",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "independent review and physical scenario family; seed labels are not independent scenarios",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete games=", games

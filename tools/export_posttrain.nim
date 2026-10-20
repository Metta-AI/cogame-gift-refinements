## Export complete Gift Refinements games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import gift_refinements/[sim_types, sim_config, sim, orders, scripted, decide,
  events, kernel, prompts]

const OperatorPrompt = "Choose legal standing orders to maximize your score over the complete game."
const Variants = ["refinery", "scarce", "long-beam", "open-floor"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6, 7]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED [SPLIT]]]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let configured = promptSelection(if args.len >= 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if configured.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  let split = if args.len == 7: args[6] else: "train"
  doAssert split in ["train", "validation"]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var selection = configured
    if selection.variant == pvMixed: selection.seed += seed - firstSeed
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< SeatCount:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    let family = scenarioFamily(config)
    var sim = initSimServer(config)
    var rows: seq[string]
    for round in 1 .. config.rounds:
      let scene = sim.scene()
      let snapshot = sim
      for seat in 0 ..< SeatCount:
        let view = snapshot.seatView(seat)
        let teacher = scriptedOrder(
          if seat mod 2 == 0: blReciprocator else: blHoarder,
          view, config.maxBeamsPerRound)
        let completion = %*{
          "job": $teacher.job,
          "target": (if teacher.target < 0: newJNull()
            else: %sim.aliases[teacher.target]),
          "gift": teacher.gift,
          "consume": $teacher.consume,
          "say": teacher.say,
          "notes": teacher.notes
        }
        var parsed = parseOrder(completion, seat, sim.aliases,
          config.maxBeamsPerRound)
        parsed.source = osScripted
        doAssert parsed == teacher
        let system = systemPrompt(view, scene, selection)
        let user = userPrompt(view, scene, OperatorPrompt)
        rows.add($(%*{
          "episode_id": "gift-refinements-" & variant & "-" & $seed &
            "-" & $selection.variant & "-" & $selection.selectedVariant & "-" & $selection.seed,
          "seed": family,
          "prompt_template": selection.promptMetadata(system, user),
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "gift-refinements",
          "action_schema_revision": "gift-standing-order-v1"
        }))
        sim.orders[seat] = parsed
        sim.haveOrder[seat] = true
        sim.events.add(GiftEvent(
          kind: evOrder, t: sim.tick, seat: seat, round: round,
          job: $parsed.job, target: parsed.targetAlias(sim.aliases),
          gift: parsed.gift, consume: $parsed.consume, clamped: parsed.clamped,
          source: $parsed.source, say: parsed.say, notes: parsed.notes))
      for tick in 0 ..< config.ticksPerRound:
        sim.stepWithKernel()
      sim.closeRound()
    sim.finish(erComplete)
    doAssert rows.len > 0
    let outcome = sim.resultsJson()
    if split == "validation":
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "scenario_family": family,
      "prompt_selection": selection.selectionMetadata(), "decisions": rows.len,
      "scores": outcome["scores"], "rounds": config.rounds})
  writeFile(output / "train.jsonl", trainRows.join("\n") & (if trainRows.len > 0: "\n" else: ""))
  writeFile(output / "validation.jsonl", validationRows.join("\n") & (if validationRows.len > 0: "\n" else: ""))
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "gift-refinements",
    "variant": variant,
    "split": split,
    "source_revision": sourceRevision,
    "teacher": "scripted-reciprocator-and-hoarder",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len

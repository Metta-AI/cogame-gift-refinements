## Packaging (design note "## Tests" item 8).
##
## Every one of these has cost a real release somewhere in the fleet, so each
## assertion names the failure it prevents.

import std/[json, os, strutils, tables]

import ./helpers

suite "manifest"

let
  repoRoot = currentSourcePath().parentDir().parentDir()
  manifest = parseFile(repoRoot / "coworld_manifest_template.json")
  composeText = readFile(repoRoot / "compose.yaml")

proc composeService(): string =
  ## The first key under `services:` -- the SAME derivation `coworld build`
  ## does. `{{GAME_IMAGE}}` is not a thing (lantern, 2026-08-23).
  var inServices = false
  for line in composeText.splitLines():
    if line.startsWith("services:"):
      inServices = true
      continue
    if not inServices:
      continue
    if line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ' and
        line.strip().endsWith(":"):
      return line.strip().strip(chars = {':'})
  ""

block imagePlaceholderIsDerivedFromCompose:
  let service = composeService()
  check(service == "gift_refinements",
    "the compose service is " & service & ", not gift_refinements")
  let expected = "{{" & service.toUpperAscii() & "_IMAGE}}"
  check(manifest["game"]["runnable"]["image"].getStr() == expected,
    "game.runnable.image is " &
    manifest["game"]["runnable"]["image"].getStr() & ", expected " & expected)
  for entry in manifest["player"]:
    check(entry["image"].getStr() == expected,
      "player[" & entry["id"].getStr() & "].image is not " & expected)
  check("image: coworld-gift-refinements:latest" in composeText,
    "compose.yaml does not build coworld-gift-refinements:latest")
  check("platform: linux/amd64" in composeText,
    "compose.yaml does not pin linux/amd64")
  banner "the image placeholder is derived from the compose service name"

block numAgentsEverywhere:
  ## Zero episodes are scheduled without it.
  var variants = 0
  for variant in manifest["variants"]:
    inc variants
    check(variant["game_config"]["num_agents"].getInt() == SeatCount,
      "variant " & variant["id"].getStr() & " does not declare num_agents 6")
    check(variant["game_config"]["players"].len == SeatCount,
      "variant " & variant["id"].getStr() & " does not seat six players")
    check(variant.hasKey("description") and
          variant["description"].getStr().len > 0,
      "variant " & variant["id"].getStr() & " has no description")
  check(variants == 4, "expected four variants, got " & $variants)
  let cert = manifest["certification"]["game_config"]
  check(cert["num_agents"].getInt() == SeatCount,
    "certification.game_config.num_agents is not 6")
  check(cert["players"].len == SeatCount,
    "the certification fixture does not seat six players")
  check(manifest["certification"]["players"].len == SeatCount,
    "certification.players is not six entries")
  banner "num_agents == 6 in all four variants and in the certification fixture"

block variantKnobsMatchTheEngine:
  ## A knob edited in the manifest and not in `tests/helpers.variantConfig`
  ## (or the other way round) would make every test lie about what the league
  ## actually plays.
  for variant in manifest["variants"]:
    let
      id = variant["id"].getStr()
      declared = variant["game_config"]
      config = variantConfig(id)
    check(declared{"rounds"}.getInt() == config.rounds, id & ": rounds differ")
    check(declared{"ticksPerRound"}.getInt() == config.ticksPerRound,
      id & ": ticksPerRound differ")
    if declared.hasKey("spawnTicks"):
      check(declared["spawnTicks"].getInt() == config.spawnTicks,
        id & ": spawnTicks differ")
    else:
      check(config.spawnTicks == DefaultSpawnTicks, id & ": spawnTicks drifted")
    if declared.hasKey("beamRange"):
      check(declared["beamRange"].getInt() == config.beamRange,
        id & ": beamRange differ")
    else:
      check(config.beamRange == DefaultBeamRange, id & ": beamRange drifted")
    if declared.hasKey("pillars"):
      check(declared["pillars"].getInt() == config.pillars,
        id & ": pillars differ")
    else:
      check(config.pillars == DefaultPillars, id & ": pillars drifted")
  banner "every variant's knobs match the engine's own variantConfig"

block certificationFixtureIsValid:
  let cert = manifest["certification"]
  check(not cert["game_config"].hasKey("tokens"),
    "the certification fixture declares runner-managed `tokens`, which the " &
    "platform rejects as manifest_invalid (collab-cooking, 2026-08-25)")
  # EVERY declared player entry must occupy a slot: `players-run` seats the
  # whole roster and a `baseline x N` fixture fails players_missing (raid).
  var seated = initTable[string, int]()
  for entry in cert["players"]:
    let id = entry["player_id"].getStr()
    seated[id] = seated.getOrDefault(id) + 1
  for entry in manifest["player"]:
    let id = entry["id"].getStr()
    check(id in seated,
      "player[" & id & "] is declared but never seated in certification.players")
  check(cert["game_config"]["minTurnSeconds"].getInt() == 0,
    "the fixture must set minTurnSeconds 0 so an offline run costs nothing")
  # Size check: rounds x ticks / fps + the shutdown grace must clear the
  # certify timeout the release workflow passes (--timeout-seconds 300).
  let seconds = cert["game_config"]["rounds"].getInt() *
    cert["game_config"]["ticksPerRound"].getInt() div TargetFps +
    DefaultShutdownGraceSeconds
  check(seconds < 300,
    "the cert fixture needs " & $seconds & " s against a 300 s timeout")
  # …and it must OUTLAST the 10 s viewer soak.
  let videoSeconds = cert["game_config"]["rounds"].getInt() *
    cert["game_config"]["ticksPerRound"].getInt() div TargetFps
  check(videoSeconds > 10,
    "the cert replay is only " & $videoSeconds & " s of video; the viewer " &
    "soak is 10 s and would report a finished replay as frozen (ecos)")
  banner "the cert fixture seats every declared player, declares no tokens, " &
    "and is " & $videoSeconds & " s of video"

block secretsAndNamespaces:
  let game = manifest["game"]
  check(game["name"].getStr() == GameName,
    "game.name is " & game["name"].getStr() & ", expected " & GameName)
  let uri = game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr()
  check(uri == "secret://coworld/" & GameName & "/anthropic_api_key",
    "the secret URI is " & uri &
    "; without game.name as the namespace upload-coworld 400s and every " &
    "league episode silently plays scripted (hive / cooperative-hunting)")
  check(game["runnable"]["type"].getStr() == "game",
    "game.runnable.type must be \"game\" for the 0.1.42 upload contract")
  check(game.hasKey("owner"), "game.owner is required")
  check(not manifest.hasKey("version"), "a top-level version is rejected")
  check(not manifest.hasKey("replay_viewer"),
    "replay_viewer must live under game, not at the top level")
  check(not game.hasKey("display_name"), "game.display_name is rejected")
  check(manifest.hasKey("episode_timeout_minutes"),
    "episode_timeout_minutes must be top-level")
  check(manifest["tags"].len >= 3, "at least three tags are required")
  check(manifest.hasKey("$schema"), "$schema is required")
  banner "game.name, the secret namespace and the 0.1.42 upload contract"

block replayViewerIsTheStaticBundle:
  check(manifest["game"]["replay_viewer"]["bundle"].getStr() ==
        "static-replay-viewer",
    "the replay viewer must be the static bundle, never a /client/replay pod")
  check(fileExists(repoRoot / "tools" / "build_replay_viewer.sh"),
    "tools/build_replay_viewer.sh is the coworld build hook and is missing")
  banner "replay_viewer.bundle == static-replay-viewer, with its build hook"

block docsAndProtocols:
  let docs = manifest["game"]["docs"]
  check(docs["readme"]["type"].getStr() == "text" and
        docs["readme"]["value"].getStr().len > 200,
    "game.docs.readme must be a {type:text,value} object with real content")
  check(docs["pages"].len >= 2, "game.docs.pages must carry real pages")
  for page in docs["pages"]:
    check(page["content"]["type"].getStr() == "text" and
          page["content"]["value"].getStr().len > 200,
      "docs page " & page["id"].getStr() & " has no content")
  let protocols = manifest["game"]["protocols"]
  for key in ["player", "global"]:
    check(protocols.hasKey(key), "game.protocols is missing " & key)
    check(protocols[key].kind == JObject and
          protocols[key]["type"].getStr() == "text" and
          protocols[key]["value"].getStr().len > 200,
      "game.protocols." & key & " must be a {type:text,value} object, not a " &
      "bare string (the platform validator rejects it; repo CI used not to)")
  banner "docs.readme + pages and BOTH protocols are {type:text,value} objects"

block configSchemaBoundsEveryArray:
  let schema = manifest["game"]["config_schema"]
  check(schema["additionalProperties"].getBool() == false,
    "config_schema must not allow additional properties")
  var required: seq[string] = @[]
  for item in schema["required"]:
    required.add(item.getStr())
  check("tokens" in required, "config_schema.required must include tokens")
  for name, prop in schema["properties"]:
    if prop{"type"}.getStr() == "array":
      check(prop.hasKey("minItems") and prop.hasKey("maxItems"),
        "config_schema.properties." & name &
        " is an array without minItems/maxItems (tandem, 2026-08-23)")
  for name, prop in manifest["game"]["results_schema"]["properties"]:
    if prop{"type"}.getStr() == "array":
      check(prop.hasKey("minItems") and prop.hasKey("maxItems"),
        "results_schema.properties." & name & " is an unbounded array")
  banner "every array property in both schemas carries minItems and maxItems"

block schemaDefaultsMatchTheEngine:
  let props = manifest["game"]["config_schema"]["properties"]
  let config = defaultGameConfig()
  proc want(key: string, value: int) =
    check(props[key]["default"].getInt() == value,
      "config_schema default for " & key & " is " &
      $props[key]["default"].getInt() & ", the engine uses " & $value)
  want("num_agents", config.numAgents)
  want("rounds", config.rounds)
  want("ticksPerRound", config.ticksPerRound)
  want("pillars", config.pillars)
  want("spawnTicks", config.spawnTicks)
  want("beamRange", config.beamRange)
  want("giftCooldown", config.giftCooldown)
  want("maxBeamsPerRound", config.maxBeamsPerRound)
  want("giftMultiplier", config.giftMultiplier)
  want("maxLevel", config.maxLevel)
  want("invCap", config.invCap)
  want("collectCooldown", config.collectCooldown)
  want("moveCooldown", config.moveCooldown)
  want("consumeCooldown", config.consumeCooldown)
  want("attempt1Ms", config.attempt1Ms)
  want("retryMs", config.retryMs)
  want("turnBudgetMs", config.turnBudgetMs)
  want("minTurnSeconds", config.minTurnSeconds)
  want("maxOutputTokens", config.maxOutputTokens)
  want("episodeTimeoutSeconds", config.episodeTimeoutSeconds)
  want("playerConnectTimeoutSeconds", config.playerConnectTimeoutSeconds)
  want("shutdownGraceSeconds", config.shutdownGraceSeconds)
  banner "every config_schema default equals the engine's own default"

block everyVariantConstructs:
  ## cogame-collab-cooking 0.1.1: league episodes all failed `game_unhealthy`
  ## because only the smaller cert fixture had ever been constructed. Every
  ## variant's game_config is built here, and one round of it is played.
  for variant in manifest["variants"]:
    var config = defaultGameConfig()
    config.update($variant["game_config"])
    config.validate()
    var sim = initSimServer(config)
    for slot in 0 ..< SeatCount:
      sim.holdOrder(slot, scriptedOrder(
        blReciprocator, sim.seatView(slot), config.maxBeamsPerRound))
    sim.runTicks(config.ticksPerRound)
    sim.closeRound()
    check(sim.round == 1, variant["id"].getStr() & ": a round did not close")
  var certConfig = defaultGameConfig()
  certConfig.update($manifest["certification"]["game_config"])
  certConfig.validate()
  banner "every variant's game_config constructs and plays a round"

block policiesJsonNamesThisGame:
  let policies = parseFile(repoRoot / "tools" / "ci" / "policies.json")
  check(policies.len == 4, "expected four policies, got " & $policies.len)
  var prompts, scripted = 0
  var championTwo = ""
  for policy in policies:
    check(policy["name"].getStr().startsWith(GameName & "-"),
      "policy " & policy["name"].getStr() & " is not named for this game")
    check(policy["run"].getStr() == "/bin/" & GameName & "-player",
      "policy " & policy["name"].getStr() & " does not run the player binary")
    let env = policy["env"]
    if env.hasKey("PLAYER_PROMPT"):
      inc prompts
      check(env["PLAYER_PROMPT"].getStr().len > 200,
        "a champion prompt is too short to be a strategy")
      check(env{"USE_BEDROCK"}.getStr() == "true",
        "policy " & policy["name"].getStr() &
        " has no USE_BEDROCK: the platform gates the player pod's Bedrock " &
        "sidecar on it and the seat silently plays scripted (cogolf)")
      # League round 4, 2026-08-26: the mirror prompt's "spend or bank"
      # vocabulary led the model to answer job "consume" -- consume is a
      # FIELD, not a job -- and the seat fell back to the scripted order.
      let prompt = env["PLAYER_PROMPT"].getStr()
      check("collect, meet, hold or evade" in prompt,
        "champion prompt " & policy["name"].getStr() &
        " does not state the job enum")
      check("Consuming is NOT a job" in prompt,
        "champion prompt " & policy["name"].getStr() &
        " does not say that consume is a field rather than a job")
    else:
      inc scripted
      check(env["PLAYER_SCRIPTED"].getStr() in ["reciprocator", "hoarder"],
        "an unknown baseline is named")
    if policy.hasKey("player"):
      championTwo = policy["player"].getStr()
  check(prompts == 2, "there must be exactly two prompt champions")
  check(scripted == 2, "there must be exactly two scripted fillers")
  check(championTwo == "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
    "champion #2 must be uploaded while daveey-1 is the active player")
  banner "policies.json: two prompt champions (one owned by daveey-1) and two fillers"

echo "test_manifest OK"

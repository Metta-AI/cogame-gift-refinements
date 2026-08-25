## `GameConfig` lifecycle: the defaults, `config.update(json)` and the guards.
##
## Forked from `coworld-ctf/src/ctf/sim_config.nim`. The two LLM-deadline
## guards are KEPT VERBATIM in spirit and are load-bearing:
##
##   * `attempt1Ms mod 1000 != 0` is rejected. curly hands the deadline to
##     CURLOPT_TIMEOUT, whose granularity is WHOLE SECONDS, so a sub-second
##     value FLOORS and is not the deadline it claims to be (paintball,
##     2026-08-25: a 4500 ms config really ran with 4 s).
##   * `attempt1Ms + retryMs <= turnBudgetMs` is asserted, so the two attempts
##     can always both fit inside the per-turn wall-clock cap.

import std/[json, strutils]

import ./sim_types

type
  PlayerSlot* = object
    name*: string

  GameConfig* = object
    ## Every field here is a `game.config_schema` property in
    ## `coworld_manifest_template.json`, and every variant differs only in
    ## these numbers.
    numAgents*: int
    seed*: int
    variant*: string
    rounds*: int
    ticksPerRound*: int
    pillars*: int
    spawnTicks*: int
    beamRange*: int
    giftCooldown*: int
    maxBeamsPerRound*: int
    giftMultiplier*: int
    maxLevel*: int
    invCap*: int
    collectCooldown*: int
    moveCooldown*: int
    consumeCooldown*: int
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    minTurnSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int
    showPlayerLabels*: bool
    tokens*: seq[string]
    players*: seq[PlayerSlot]

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    numAgents: SeatCount,
    seed: 0,
    variant: "refinery",
    rounds: DefaultRounds,
    ticksPerRound: DefaultTicksPerRound,
    pillars: DefaultPillars,
    spawnTicks: DefaultSpawnTicks,
    beamRange: DefaultBeamRange,
    giftCooldown: DefaultGiftCooldown,
    maxBeamsPerRound: DefaultMaxBeamsPerRound,
    giftMultiplier: DefaultGiftMultiplier,
    maxLevel: DefaultMaxLevel,
    invCap: DefaultInvCap,
    collectCooldown: DefaultCollectCooldown,
    moveCooldown: DefaultMoveCooldown,
    consumeCooldown: DefaultConsumeCooldown,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    turnBudgetMs: DefaultTurnBudgetMs,
    minTurnSeconds: DefaultMinTurnSeconds,
    maxOutputTokens: DefaultMaxOutputTokens,
    model: "",
    episodeTimeoutSeconds: DefaultEpisodeTimeoutSeconds,
    playerConnectTimeoutSeconds: DefaultPlayerConnectTimeoutSeconds,
    shutdownGraceSeconds: DefaultShutdownGraceSeconds,
    showPlayerLabels: true,
    tokens: @[],
    players: @[]
  )

proc readInt(node: JsonNode, key: string, current: int): int =
  let value = node{key}
  if value.isNil:
    return current
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: value.getStr().strip().parseInt() except CatchableError: current
  else: current

proc readBool(node: JsonNode, key: string, current: bool): bool =
  let value = node{key}
  if value.isNil: current
  elif value.kind == JBool: value.getBool()
  else: current

proc readStr(node: JsonNode, key, current: string): string =
  let value = node{key}
  if value.isNil or value.kind != JString: current else: value.getStr()

proc validate*(config: GameConfig) =
  ## Every bound the manifest's `config_schema` declares, re-checked in the
  ## engine so a hand-written config or a hosted variant can never open an
  ## episode the rules do not cover.
  if config.numAgents < 1 or config.numAgents > SeatCount:
    raise newException(GiftError,
      "num_agents must be 1.." & $SeatCount & ", got " & $config.numAgents)
  if config.rounds < 1 or config.rounds > 24:
    raise newException(GiftError, "rounds must be 1..24")
  if config.ticksPerRound < 10 or config.ticksPerRound > 120:
    raise newException(GiftError, "ticksPerRound must be 10..120")
  if config.pillars < 0 or config.pillars > 5:
    raise newException(GiftError, "pillars must be 0..5")
  if config.maxLevel < 1 or config.maxLevel > 4:
    raise newException(GiftError, "maxLevel must be 1..4")
  if config.invCap < 1 or config.invCap > 64:
    raise newException(GiftError, "invCap must be 1..64")
  if config.beamRange < 1 or config.beamRange > 16:
    raise newException(GiftError, "beamRange must be 1..16")
  if config.giftMultiplier < 1 or config.giftMultiplier > 6:
    raise newException(GiftError, "giftMultiplier must be 1..6")
  if config.maxBeamsPerRound < 0 or config.maxBeamsPerRound > 30:
    raise newException(GiftError, "maxBeamsPerRound must be 0..30")
  if config.spawnTicks < 5 or config.spawnTicks > 240:
    raise newException(GiftError, "spawnTicks must be 5..240")
  if config.maxOutputTokens < 200 or config.maxOutputTokens > 2000:
    raise newException(GiftError, "maxOutputTokens must be 200..2000")
  # --- the two LLM-deadline guards, kept from the starter -------------------
  if config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    raise newException(GiftError,
      "attempt1Ms and retryMs must be WHOLE SECONDS: curly floors " &
      "CURLOPT_TIMEOUT to seconds, so " & $config.attempt1Ms & "/" &
      $config.retryMs & " would not be the deadline it claims to be")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(GiftError,
      "attempt1Ms + retryMs (" & $(config.attempt1Ms + config.retryMs) &
      ") must fit inside turnBudgetMs (" & $config.turnBudgetMs & ")")

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime config document. Unknown keys are ignored; every known
  ## key is bounds-checked by `validate` afterwards.
  if configJson.len == 0:
    config.validate()
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(GiftError, "config is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(GiftError, "config must be a JSON object")

  config.numAgents = node.readInt("num_agents", config.numAgents)
  config.seed = node.readInt("seed", config.seed)
  config.variant = node.readStr("variant", config.variant)
  config.rounds = node.readInt("rounds", config.rounds)
  config.ticksPerRound = node.readInt("ticksPerRound", config.ticksPerRound)
  config.pillars = node.readInt("pillars", config.pillars)
  config.spawnTicks = node.readInt("spawnTicks", config.spawnTicks)
  config.beamRange = node.readInt("beamRange", config.beamRange)
  config.giftCooldown = node.readInt("giftCooldown", config.giftCooldown)
  config.maxBeamsPerRound =
    node.readInt("maxBeamsPerRound", config.maxBeamsPerRound)
  config.giftMultiplier = node.readInt("giftMultiplier", config.giftMultiplier)
  config.maxLevel = node.readInt("maxLevel", config.maxLevel)
  config.invCap = node.readInt("invCap", config.invCap)
  config.collectCooldown = node.readInt("collectCooldown", config.collectCooldown)
  config.moveCooldown = node.readInt("moveCooldown", config.moveCooldown)
  config.consumeCooldown = node.readInt("consumeCooldown", config.consumeCooldown)
  config.attempt1Ms = node.readInt("attempt1Ms", config.attempt1Ms)
  config.retryMs = node.readInt("retryMs", config.retryMs)
  config.turnBudgetMs = node.readInt("turnBudgetMs", config.turnBudgetMs)
  config.minTurnSeconds = node.readInt("minTurnSeconds", config.minTurnSeconds)
  config.maxOutputTokens = node.readInt("maxOutputTokens", config.maxOutputTokens)
  config.model = node.readStr("model", config.model)
  config.episodeTimeoutSeconds =
    node.readInt("episodeTimeoutSeconds", config.episodeTimeoutSeconds)
  config.playerConnectTimeoutSeconds =
    node.readInt("playerConnectTimeoutSeconds", config.playerConnectTimeoutSeconds)
  config.shutdownGraceSeconds =
    node.readInt("shutdownGraceSeconds", config.shutdownGraceSeconds)
  config.showPlayerLabels =
    node.readBool("showPlayerLabels", config.showPlayerLabels)

  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      if item.kind == JString:
        config.tokens.add(item.getStr())
  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.players = @[]
    for item in players:
      if item.kind == JObject:
        config.players.add(PlayerSlot(name: item{"name"}.getStr()))
      elif item.kind == JString:
        config.players.add(PlayerSlot(name: item.getStr()))

  config.validate()

proc totalTicks*(config: GameConfig): int =
  config.rounds * config.ticksPerRound

proc playDeadlineSeconds*(config: GameConfig): int =
  ## 60% of the episode budget: the wall clock the round loop settles inside.
  config.episodeTimeoutSeconds * PlayDeadlinePermille div 1000

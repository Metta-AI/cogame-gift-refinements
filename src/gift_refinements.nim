## The game entrypoint (`/bin/gift-refinements`).
##
## Forked from `coworld-ctf/src/ctf.nim`: the seed is randomised BEFORE
## `config.update`, because every seed-derived draw must follow the FINAL seed,
## and the legacy sentinel doubles as the "nobody chose a seed" marker.

import std/[json, os, sysrand]

import bitworld/runtime

import gift_refinements/[sim_types, sim_config, server]

const LegacySentinelSeed = 0
  ## A config that carries no seed -- or an explicit 0 -- gets a fresh random
  ## one. A public fixed seed would make the episode's opening pre-computable.

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacySentinelSeed
  except CatchableError:
    false                       ## config.update reports the real parse error

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(GiftError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(runtimeConfig.config))
    echo "gift-refinements: seed not pinned; randomized"
  echo "gift-refinements config: seed=", config.seed,
    " variant=", config.variant,
    " num_agents=", config.numAgents,
    " rounds=", config.rounds,
    " ticksPerRound=", config.ticksPerRound,
    " pillars=", config.pillars,
    " spawnTicks=", config.spawnTicks,
    " beamRange=", config.beamRange,
    " minTurnSeconds=", config.minTurnSeconds
  runEpisode(runtimeConfig.host, runtimeConfig.port, config, runtimeConfig)

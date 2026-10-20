## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy
import ./sim_config

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "gift-refinements-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", one of six cogs on a foundry floor."
  of pvPlain: "You play " & alias & ". You are one of six cogs on a foundry floor."
  of pvNumbered: "1. Your identity: " & alias & ". 2. Participants: six cogs, including you. 3. Setting: a foundry floor."
  of pvQuestions: "Who are you? " & alias & ". Where are you? On a foundry floor with five other cogs."
  of pvReordered: "On a foundry floor with five other cogs, you play " & alias & "."
  of pvHeldoutBriefing: "Take the role of " & alias & ", a cog sharing a foundry floor with five other cogs."
  of pvHeldoutReference: "Identity: " & alias & ". Group: six cogs including you. Location: a foundry floor."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")

proc scenarioFamily*(config: GameConfig): string =
  ## Seeds affect only the replay checksum. Group actual scenarios, not seed labels.
  let physical = %*{
    "rounds": config.rounds, "ticksPerRound": config.ticksPerRound,
    "pillars": config.pillars, "spawnTicks": config.spawnTicks,
    "beamRange": config.beamRange, "giftCooldown": config.giftCooldown,
    "maxBeamsPerRound": config.maxBeamsPerRound,
    "giftMultiplier": config.giftMultiplier, "maxLevel": config.maxLevel,
    "invCap": config.invCap, "collectCooldown": config.collectCooldown,
    "moveCooldown": config.moveCooldown, "consumeCooldown": config.consumeCooldown
  }
  "gift-refinements-scenario-" & sha256($physical).toHex.toLowerAscii()

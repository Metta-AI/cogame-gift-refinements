## Types, constants and the flatty-free wire shapes for Gift Refinements.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`: the same split (consts +
## types + the wire shapes the renderer reads), the same rule that FIELD ORDER
## IS SACRED, and the same rune-cap discipline for every string that can reach
## the replay.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary. Slicing a recorded string by
## BYTE index is forbidden anywhere on the path to the replay: a byte-truncated
## multi-byte character renders fine in a browser and then fails a strict UTF-8
## parser, which is the class of bug that makes a replay unreadable to
## everything except the one viewer that happened to be lenient (bullwhip,
## 2026-08-22).

import std/[os, strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (gift refinements): the first rules. Bumped whenever a rule that
    ## changes a recorded frame changes; the replay pins it so a consumer never
    ## has to infer which rules produced the bytes.

  GameName* = "gift-refinements"
  ReplayProtocol* = "gift-refinements.replay.v1"
  PlayerProtocol* = "gift-refinements.player.v1"

  # ---- the board (design note "## The game" -> "The board") ---------------
  Cols* = 24
  Rows* = 14
  CellPx* = 48                 ## board pixels per cell: a 1152 x 672 board.
  BoardW* = Cols * CellPx
  BoardH* = Rows * CellPx
  SeatCount* = 6

  # ---- the constants table (design note "## The game" -> "Constants") -----
  DefaultRounds* = 12
  DefaultTicksPerRound* = 60
  DefaultMaxLevel* = 2
  DefaultGiftMultiplier* = 3
  DefaultInvCap* = 15
  DefaultBeamRange* = 4
  DefaultGiftCooldown* = 4
  DefaultMaxBeamsPerRound* = 10
  DefaultCollectCooldown* = 3
  DefaultMoveCooldown* = 2
  DefaultConsumeCooldown* = 10
  DefaultSpawnTicks* = 30
  DefaultPillars* = 5

  DefaultAttempt1Ms* = 20_000
  DefaultRetryMs* = 12_000
  DefaultTurnBudgetMs* = 34_000
  DefaultMinTurnSeconds* = 25
  DefaultMaxOutputTokens* = 1000
    ## hanabi, 2026-08-24: a budget under 1000 truncates mid-JSON and shows up
    ## as the misleading "unbalanced JSON object" signature.
  DefaultEpisodeTimeoutSeconds* = 1200
  DefaultPlayerConnectTimeoutSeconds* = 180
  DefaultShutdownGraceSeconds* = 20
  PlayDeadlinePermille* = 600
    ## Play inside 60% of `episodeTimeoutSeconds`; the game container is NOT
    ## given COWORLD_TIMEOUT_SECONDS, so 1200 is assumed unless it is present.

  # ---- string caps, in runes ----------------------------------------------
  MaxSayRunes* = 80
  MaxNotesRunes* = 320
  MaxPromptRunes* = 4000
  MaxPolicyLabelRunes* = 64
  MaxFallbackDetailRunes* = 200

  TargetFps* = 24
    ## Replay playback rate. 720 ticks is 30 s of video, comfortably past the
    ## viewer soak gate.
  PlaybackSpeeds*: array[6, int] = [1, 2, 3, 4, 8, 16]

  # ---- seats (design note "## The game" -> "Seats, aliases, names") -------
  Aliases*: array[SeatCount, string] = ["Aro", "Bex", "Cyr", "Dov", "Eno", "Fay"]
  SeatColors*: array[SeatCount, string] =
    ["red", "orange", "yellow", "lime", "blue", "pink"]
  SpawnCells*: array[SeatCount, array[2, int]] =
    [[2, 2], [21, 2], [2, 11], [21, 11], [2, 6], [21, 7]]

  LevelNames*: array[3, string] = ["raw", "refined", "super"]

type
  GiftError* = object of CatchableError

  Cell* = object
    x*, y*: int

  Action* = enum
    ## The eleven per-tick grid actions. This IS the policy interface the idea
    ## names; a standing order is compiled into a stream of these by the
    ## kernel.
    actWait = "wait"
    actMoveN = "move_n"
    actMoveE = "move_e"
    actMoveS = "move_s"
    actMoveW = "move_w"
    actCollect = "collect"
    actGiftN = "gift_n"
    actGiftE = "gift_e"
    actGiftS = "gift_s"
    actGiftW = "gift_w"
    actConsume = "consume"

  Dir* = enum
    dirN = "north"
    dirE = "east"
    dirS = "south"
    dirW = "west"

  Cog* = object
    ## One seat's whole live state. Field order is sacred: `## The replay file`
    ## records the first six as a septet per frame, in this order.
    x*, y*: int
    tokens*: array[3, int]     ## t0 raw, t1 refined, t2 super
    score*: int                ## banked tokens, higher is better
    moveCd*, collectCd*, giftCd*, consumeCd*: int
    beamsLeft*: int            ## beams remaining in this round
    consumedThisTick*: bool
    firedThisTick*: bool
    collectedThisTick*: bool
    collected*: int
    giftsSent*, giftsReceived*: int
    tokensGiven*, tokensReceived*: int
    banked*: array[3, int]     ## banked per level, so results can break it out

  ViewCog* = object
    ## What the renderer needs about one cog for one tick. Both the live server
    ## and the wasm replayer fill this, which is what lets ONE renderer serve
    ## both without a second code path.
    x*, y*: int
    tokens*: array[3, int]
    score*: int
    flags*: int                ## bit 0 consumed, 1 fired, 2 collected

  ViewFrame* = object
    tick*: int
    cogs*: array[SeatCount, ViewCog]
    pads*: seq[bool]           ## per pad: a loose raw token is sitting on it

  Scene* = object
    ## Everything about the episode that never changes, shared by the live
    ## broadcast and the static replay bundle. The wasm viewer builds this from
    ## the replay bytes alone -- no server is contacted.
    cols*, rows*, cell*: int
    variant*: string
    walls*: seq[Cell]          ## the border ring AND the pillars
    pads*: seq[Cell]
    spawns*: seq[Cell]
    names*: seq[string]        ## in-game aliases
    policyNames*: seq[string]  ## spectator side only, never sent to a seat
    colors*: seq[string]
    rounds*, ticksPerRound*: int
    maxLevel*, giftMultiplier*, invCap*, beamRange*: int
    giftCooldown*, maxBeamsPerRound*, collectCooldown*: int
    moveCooldown*, consumeCooldown*, spawnTicks*: int

proc cell*(x, y: int): Cell = Cell(x: x, y: y)

proc `==`*(a, b: Cell): bool = a.x == b.x and a.y == b.y

proc held*(cog: Cog): int = cog.tokens[0] + cog.tokens[1] + cog.tokens[2]

proc lowestLevel*(cog: Cog): int =
  ## "One of your rawest tokens": the lowest level this cog holds, or -1 when
  ## it holds nothing. This one line is the whole specialisation mechanic.
  for level in 0 .. 2:
    if cog.tokens[level] > 0:
      return level
  -1

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single place
  ## any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc cleanText*(text: string, limit: int): string =
  ## The recorded form of a model-supplied string: strip, collapse newlines to
  ## spaces, and -- only if it is genuinely over the cap -- cut to `limit - 1`
  ## runes and mark the cut with a single ellipsis rune, so the reader can see
  ## that something was dropped. Rune boundaries throughout.
  let flat = text.replace("\r", " ").replace("\n", " ").strip()
  if flat.runeLen <= limit:
    return flat
  flat.truncateRunes(max(0, limit - 1)) & "\u2026"

proc gameDir*(): string =
  ## The directory `data/` sits under.
  ##
  ## The WORKING DIRECTORY is tried first and the app-dir probe is compiled out
  ## of the wasm build entirely: emscripten has no `getAppDir` implementation
  ## and dies with "value out of range: -1" BEFORE any fallback can run
  ## (chemistry, 2026-08-25). Under emscripten `data/` is the preloaded
  ## `--preload-file data@data` mount, which is exactly where this lands.
  if dirExists("data"):
    return getCurrentDir()
  when not defined(emscripten):
    let appDir = getAppDir()
    if dirExists(appDir / "data"):
      return appDir
  getCurrentDir()

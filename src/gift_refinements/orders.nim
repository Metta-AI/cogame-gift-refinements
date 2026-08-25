## The standing-order schema: what a policy (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and which fields are repaired rather than
## rejected.
##
## Forked from `coworld-ctf/src/ctf/directives.nim`. Both policy kinds emit the
## SAME object, so one validator covers both -- that is what makes the
## bounded-orders test in `tests/test_baseline.nim` meaningful.
##
## RUNE DISCIPLINE (see sim_types.cleanText): every cap here is in runes and
## every cut lands on a rune boundary.

import std/[json, strutils, unicode]

import ./sim_types

type
  Job* = enum
    jobCollect = "collect"
    jobMeet = "meet"
    jobHold = "hold"
    jobEvade = "evade"

  ConsumeWhen* = enum
    cwNow = "now"
    cwEnd = "end"
    cwNever = "never"

  OrderSource* = enum
    osLlm = "llm"
    osRetry = "retry"
    osFallback = "fallback"
    osScripted = "scripted"

  Order* = object
    ## One seat's whole decision for one round (60 ticks). A deterministic
    ## kernel turns this into that round's per-tick action stream.
    job*: Job
    target*: int               ## slot, or -1 for none
    gift*: int                 ## 0 .. maxBeamsPerRound
    consume*: ConsumeWhen
    say*: string               ## <= MaxSayRunes; SPECTATOR-ONLY, never
                               ## delivered to another seat
    notes*: string             ## <= MaxNotesRunes; private to this seat
    clamped*: bool
    source*: OrderSource
    latencyMs*: int

  OrderError* = object of ValueError
    ## An INVALID REPLY in the design note's table: the retry batch and then
    ## the scripted fallback are what this exists for.

proc defaultOrder*(): Order =
  Order(job: jobCollect, target: -1, gift: 0, consume: cwEnd, source: osScripted)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "\u2026"
    raise newException(
      OrderError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc parseJob(text: string): tuple[ok: bool, job: Job] =
  ## Tolerant only in CASE and separators. An unrecognised job is an INVALID
  ## REPLY, not a repair: the design note's table says so, and a silently
  ## defaulted job would hide a model that never understood the schema.
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
  for job in Job:
    if $job == key:
      return (true, job)
  (false, jobCollect)

proc parseConsumeWhen(text: string): tuple[ok: bool, value: ConsumeWhen] =
  let key = text.strip().toLowerAscii()
  for value in ConsumeWhen:
    if $value == key:
      return (true, value)
  (false, cwEnd)

proc aliasSlot*(aliases: openArray[string], text: string): int =
  ## Case-insensitive alias lookup. Returns -1 when nothing matches.
  let wanted = text.strip().toLowerAscii()
  if wanted.len == 0:
    return -1
  for slot, alias in aliases:
    if alias.toLowerAscii() == wanted:
      return slot
  -1

proc parseOrder*(
  payload: JsonNode, seat: int, aliases: openArray[string], maxBeams: int
): Order =
  ## Turns one parsed reply into a legal order.
  ##
  ## REPAIRED (the reply still counts):
  ##   * `gift` outside 0..maxBeams is CLAMPED and `clamped: true` is recorded;
  ##   * `say` / `notes` over their caps are truncated on rune boundaries;
  ##   * an absent `gift` is 0 and an absent `consume` is `end`.
  ##
  ## INVALID REPLY (raises OrderError -> retry, then the scripted fallback):
  ##   * `job` missing or not in the enum;
  ##   * `target` that is this seat's OWN alias, an unknown alias, or a
  ##     non-string;
  ##   * `target` required (job == meet, or gift > 0) and absent or null;
  ##   * a non-integer `gift`.
  result = defaultOrder()
  result.source = osLlm
  if payload.isNil or payload.kind != JObject:
    raise newException(OrderError, "reply is not a JSON object")

  let jobNode = payload{"job"}
  if jobNode.isNil or jobNode.kind != JString:
    raise newException(OrderError, "reply has no \"job\" string")
  let job = parseJob(jobNode.getStr())
  if not job.ok:
    raise newException(OrderError,
      "unknown job " & jobNode.getStr().cleanText(40) &
      " (expected collect|meet|hold|evade)")
  result.job = job.job

  # --- gift -----------------------------------------------------------------
  let giftNode = payload{"gift"}
  var gift = 0
  if not giftNode.isNil and giftNode.kind != JNull:
    case giftNode.kind
    of JInt: gift = int(giftNode.getBiggestInt())
    of JFloat:
      let f = giftNode.getFloat()
      if f != f or f > 1.0e6 or f < -1.0e6:
        raise newException(OrderError, "gift is not an integer")
      if f != f.int.float:
        raise newException(OrderError, "gift is not an integer")
      gift = f.int
    of JString:
      try:
        gift = giftNode.getStr().strip().parseInt()
      except CatchableError:
        raise newException(OrderError, "gift is not an integer")
    else:
      raise newException(OrderError, "gift is not an integer")
  if gift < 0 or gift > maxBeams:
    result.clamped = true
    gift = clamp(gift, 0, maxBeams)
  result.gift = gift

  # --- target ---------------------------------------------------------------
  let targetNode = payload{"target"}
  var target = -1
  if not targetNode.isNil and targetNode.kind != JNull:
    if targetNode.kind != JString:
      raise newException(OrderError, "target must be an alias string or null")
    target = aliasSlot(aliases, targetNode.getStr())
    if target < 0:
      raise newException(OrderError,
        "unknown target alias " & targetNode.getStr().cleanText(40))
    if target == seat:
      raise newException(OrderError, "a cog cannot target itself")
  if target < 0 and (result.job == jobMeet or result.gift > 0):
    raise newException(OrderError,
      "target is required when job is meet or gift > 0")
  result.target = target

  # --- consume --------------------------------------------------------------
  let consumeNode = payload{"consume"}
  if not consumeNode.isNil and consumeNode.kind != JNull:
    if consumeNode.kind != JString:
      raise newException(OrderError, "consume must be now|end|never")
    let parsed = parseConsumeWhen(consumeNode.getStr())
    if not parsed.ok:
      raise newException(OrderError,
        "unknown consume " & consumeNode.getStr().cleanText(40) &
        " (expected now|end|never)")
    result.consume = parsed.value

  result.say = payload{"say"}.getStr().cleanText(MaxSayRunes)
  result.notes = payload{"notes"}.getStr().cleanText(MaxNotesRunes)

proc targetAlias*(order: Order, aliases: openArray[string]): string =
  if order.target < 0 or order.target >= aliases.len: "" else: aliases[order.target]

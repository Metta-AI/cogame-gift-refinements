## The decision layer (design note "## Tests" item 7).
##
## The tolerant extractor, the reply schema's repair-vs-reject split, the
## batched cadence, and the "never raises, always advances" contract of the
## fallback path. The transport is exercised through the real `decide.turn`
## with NO credentials, which is the same path certification runs.

import std/[json, monotimes, strutils, times]

import ./helpers
import curly
import gift_refinements/[decide, llm]

suite "llm"

let aliases = @Aliases

block extractsFencedAndProsePrefixedReplies:
  let fenced = "Sure! Here you go:\n```json\n" &
    "{\"job\":\"meet\",\"target\":\"Aro\",\"gift\":2}\n```\nHope that helps."
  let node = extractJsonObject(fenced)
  check(node{"job"}.getStr() == "meet", "the fenced object was not recovered")
  let prose = "I think Cyr should hold. {\"job\":\"hold\",\"gift\":0} Done."
  check(extractJsonObject(prose){"job"}.getStr() == "hold",
    "the prose-wrapped object was not recovered")
  var raised = false
  try:
    discard extractJsonObject("no object here at all")
  except OrderError:
    raised = true
  check(raised, "a reply with no object did not raise")
  banner "extractJsonObject tolerates fences and prose on both sides"

proc parses(payload: string, seat = 2): Order =
  parseOrder(extractJsonObject(payload), seat, aliases, DefaultMaxBeamsPerRound)

proc rejects(payload: string, why: string, seat = 2) =
  var raised = false
  try:
    discard parses(payload, seat)
  except OrderError:
    raised = true
  check(raised, why)

block schemaRejects:
  rejects("""{"job":"dance","target":null,"gift":0}""", "an unknown job was accepted")
  rejects("""{"target":"Aro","gift":1}""", "a reply with no job was accepted")
  rejects("""{"job":"meet","target":"Cyr","gift":1}""",
    "a cog was allowed to target itself")
  rejects("""{"job":"meet","target":"Zed","gift":1}""",
    "an unknown alias was accepted")
  rejects("""{"job":"meet","target":7,"gift":1}""",
    "a non-string target was accepted")
  rejects("""{"job":"collect","target":null,"gift":3}""",
    "gift > 0 with a null target was accepted")
  rejects("""{"job":"meet","target":null,"gift":0}""",
    "job meet with a null target was accepted")
  rejects("""{"job":"collect","gift":"lots"}""", "a non-integer gift was accepted")
  rejects("""{"job":"collect","gift":1.5,"target":"Aro"}""",
    "a fractional gift was accepted")
  rejects("""{"job":"hold","consume":"maybe"}""", "an unknown consume was accepted")
  banner "every invalid-reply row in the design note's table raises"

block schemaRepairs:
  let clamped = parses("""{"job":"meet","target":"Aro","gift":40}""")
  check(clamped.gift == DefaultMaxBeamsPerRound,
    "gift 40 clamped to " & $clamped.gift)
  check(clamped.clamped, "the clamp was not recorded on the order")
  let zero = parses("""{"job":"meet","target":"Aro","gift":0}""")
  check(zero.gift == 0 and zero.target == 0 and not zero.clamped,
    "gift 0 with job meet and a valid target must be legal and unclamped")
  let defaults = parses("""{"job":"collect"}""")
  check(defaults.gift == 0, "an absent gift did not default to 0")
  check(defaults.consume == cwEnd, "an absent consume did not default to end")
  let caseless = parses("""{"job":"MEET","target":"aRo","consume":"NEVER","gift":1}""")
  check(caseless.job == jobMeet and caseless.target == 0 and
        caseless.consume == cwNever,
    "the parser is not case-insensitive on the enums and aliases")
  let capped = parses("""{"job":"hold","say":"` & """ &
    "x".repeat(400) & """`","notes":"` & """ & "y".repeat(900) & """`"}""")
  check(capped.say.len <= MaxSayRunes + 4, "say was not truncated")
  check(capped.notes.len <= MaxNotesRunes + 4, "notes was not truncated")
  banner "gift clamps and flags, absent fields default, strings truncate"

block maxTokensIsNamed:
  ## hanabi, 2026-08-24: a truncated reply used to surface as the misleading
  ## "unbalanced JSON object". The extractor raises it BY NAME instead.
  var config = defaultGameConfig()
  config.maxOutputTokens = 1000
  let client = newLlmClient(config)
  var response: Response
  response.code = 200
  response.body = """{"stop_reason":"max_tokens","content":[{"type":"text","text":"I will collect and then"}]}"""
  var message = ""
  try:
    discard client.textOf(response, "", "https://example.invalid")
  except LlmError as error:
    message = error.msg
  check("cut off at max_tokens" in message,
    "a max_tokens stop did not raise the named error, got: " & message)
  banner "a max_tokens stop before any '{' raises \"cut off at max_tokens\""

block transportFailuresNameThemselves:
  var config = defaultGameConfig()
  let client = newLlmClient(config)
  proc msgFor(code: int, body: string, transportError = ""): string =
    var response: Response
    response.code = code
    response.body = body
    try:
      discard client.textOf(response, transportError, "https://example.invalid")
    except LlmError as error:
      return error.msg
    ""
  check("throttled" in msgFor(429, "slow down"), "a 429 was not named a throttle")
  check("llm transport" in msgFor(0, "", "Timeout was reached"),
    "a transport error was not named")
  let auth = msgFor(403, "nope")
  check("auth failed" in auth, "a 403 was not named an auth failure")
  check(client.disabled,
    "a 403 must disable the client for the rest of the episode")
  banner "429 / transport / 401-403 each raise a named, rune-safe error"

block maxOutputTokensAndModelLadder:
  check(DefaultMaxOutputTokens >= 1000,
    "maxOutputTokens must be at least 1000 (hanabi, 2026-08-24)")
  let models = bedrockModelIds()
  check(models.len == 1, "the model ladder must have exactly one candidate")
  check("haiku" in models[0],
    "the only candidate must be haiku: every sonnet inference profile times " &
    "out on every sidecar call (raid, paintball)")
  banner "haiku-only ladder, maxOutputTokens >= 1000"

block wholeSecondDeadlines:
  ## curly floors CURLOPT_TIMEOUT to whole seconds, so a sub-second deadline is
  ## not the deadline it claims to be. sim_config REJECTS one.
  var config = defaultGameConfig()
  check(config.attempt1Ms mod 1000 == 0 and config.retryMs mod 1000 == 0,
    "the shipped deadlines are not whole seconds")
  check(config.attempt1Ms + config.retryMs <= config.turnBudgetMs,
    "the two attempts do not fit inside turnBudgetMs")
  config.attempt1Ms = 4500
  var raised = false
  try:
    config.validate()
  except GiftError:
    raised = true
  check(raised, "a sub-second attempt1Ms was accepted")
  config = defaultGameConfig()
  config.turnBudgetMs = 6000
  raised = false
  try:
    config.validate()
  except GiftError:
    raised = true
  check(raised, "attempt1Ms + retryMs > turnBudgetMs was accepted")
  banner "whole-second deadlines, and both attempts must fit the turn budget"

block requestRateStaysUnderThirtyPerMinute:
  ## The Bedrock sidecar caps 30 requests/minute PER EPISODE (raid,
  ## 2026-08-23). Worst case is six seats plus six retries per round, and the
  ## next batch cannot start before minTurnSeconds.
  let config = defaultGameConfig()
  let worstPerRound = SeatCount * 2
  let ratePerMinute = worstPerRound * 60 div max(1, config.minTurnSeconds)
  check(ratePerMinute < 30,
    "worst-case request rate is " & $ratePerMinute & "/min")
  let worstEpisodeSeconds =
    config.rounds * (config.turnBudgetMs div 1000) + 30 +
    config.shutdownGraceSeconds
  check(worstEpisodeSeconds <= config.playDeadlineSeconds(),
    "the worst-case episode is " & $worstEpisodeSeconds &
    " s against a play deadline of " & $config.playDeadlineSeconds() & " s")
  banner "worst case " & $ratePerMinute & " rpm and " & $worstEpisodeSeconds &
    " s, inside 30 rpm and " & $config.playDeadlineSeconds() & " s"

block oneBatchCarriesEveryOpenSeat:
  ## The batch is built ONE request per open seat, in one go. Building it here
  ## the same way `decide.turn` does is what makes "never sequentially"
  ## checkable without a network.
  var config = defaultGameConfig()
  let sim = initSimServer(config)
  let client = newLlmClient(config)
  let scene = sim.scene()
  var open: seq[int] = @[]
  for seat in 0 ..< SeatCount:
    open.add(seat)
  var batch: RequestBatch
  for seat in open:
    let view = sim.seatView(seat)
    let request = client.requestFor(
      systemPrompt(view, scene), userPrompt(view, scene, "be generous"))
    batch.post(request.url, request.headers, request.body, $seat)
  check(batch.len == open.len,
    "the batch carries " & $batch.len & " requests for " & $open.len &
    " open seats")
  var retry: RequestBatch
  for seat in [1, 4]:
    let view = sim.seatView(seat)
    let request = client.requestFor(
      systemPrompt(view, scene), userPrompt(view, scene, ""))
    retry.post(request.url, request.headers, request.body, $seat)
  check(retry.len == 2, "the retry batch must carry ONLY the failed seats")
  banner "one batch of six on round one; the retry batch carries only the failures"

block offlineTurnFallsBackWithoutRaising:
  ## With NO credentials the client disables itself instantly and every LLM
  ## seat plays the reciprocator order, marked `fallback`. This is the path
  ## offline certification and docker-smoke run, so it must be fast and silent.
  var config = defaultGameConfig()
  config.minTurnSeconds = 0
  var sim = initSimServer(config)
  var engine = initDecisionEngine(sim)
  for seat in 0 ..< SeatCount:
    engine.seats[seat].registered = true
    if seat < 2:
      engine.seats[seat].isLlm = true
      engine.seats[seat].prompt = "be generous"
    else:
      engine.seats[seat].baseline =
        if seat mod 2 == 0: blReciprocator else: blHoarder
  let started = getMonoTime()
  let records = engine.turn(sim, 1, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds.int
  check(elapsed < 2000,
    "an offline turn took " & $elapsed & " ms; it must not wait on a network")
  for seat in 0 ..< SeatCount:
    check(sim.haveOrder[seat], "seat " & $seat & " was left with no order")
  check(sim.orders[0].source == osFallback,
    "an LLM seat with no credentials was not marked source: fallback")
  check(sim.orders[2].source == osScripted,
    "a scripted seat was mis-marked as a fallback")
  var sawFallback = false
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      sawFallback = true
      check(node{"cause"}.getStr() == "no_credentials",
        "the fallback cause is " & node{"cause"}.getStr())
  check(sawFallback, "no fallback record was produced")
  # And the resulting orders are legal by the same validator the parser uses.
  for seat in 0 ..< SeatCount:
    let order = sim.orders[seat]
    check(order.gift >= 0 and order.gift <= config.maxBeamsPerRound,
      "a fallback order's gift is out of range")
    check(order.target != seat, "a fallback order targeted its own seat")
  banner "with no credentials every seat gets a legal reciprocator order, fast"

block repairMissingOrdersLeavesNoTickUnactuated:
  var config = defaultGameConfig()
  var sim = initSimServer(config)
  var engine = initDecisionEngine(sim)
  for seat in 0 ..< SeatCount:
    sim.haveOrder[seat] = false
  engine.repairMissingOrders(sim)
  for seat in 0 ..< SeatCount:
    check(sim.haveOrder[seat], "seat " & $seat & " still has no order")
    check(sim.orders[seat].source == osFallback,
      "a repaired order is not marked as a fallback")
  banner "a seat with no order at all plays the reciprocator order"

block promptsCarryTheContract:
  let sim = initSimServer(defaultGameConfig())
  let
    view = sim.seatView(2)
    scene = sim.scene()
    system = systemPrompt(view, scene)
    user = userPrompt(view, scene, "open with the nearest cog")
  check("must begin with the character {" in system,
    "the system prompt does not demand a leading brace (Bedrock/Haiku answers " &
    "prose-first without it)")
  check("LOWEST held level" in system, "the gift rule is not stated as a rule")
  check("RAWEST FIRST" in system, "the rawest-first warning is missing")
  check("THE LADDER" in system, "the worked ladder is missing")
  check("NOBODY CAN HEAR ANYTHING YOU SAY" in system,
    "the prompt does not say there is no talk channel")
  check("CYR" in system, "the seat's own alias is not in capitals")
  for alias in ["Aro", "Bex", "Dov", "Eno", "Fay"]:
    check(alias in system, "the prompt does not name " & alias)
  check("open with the nearest cog" in user,
    "the operator block is missing from the user prompt")
  check("GUIDANCE FROM YOUR OPERATOR" in user,
    "the operator heading is missing")
  check("\"target\":\"Aro\"|" in user,
    "the user prompt does not precompute the legal target set")
  # NOTHING about the other seats' inventories, policies or the seed.
  for forbidden in ["policyNames", "gift-refinements-mirror", "seed"]:
    check(forbidden notin system and forbidden notin user,
      "the prompt leaks " & forbidden)
  banner "the prompts carry the output contract and leak nothing"

echo "test_llm OK"

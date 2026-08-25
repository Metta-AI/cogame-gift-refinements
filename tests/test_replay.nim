## End-to-end plus strict UTF-8 (design note "## Tests" item 6).
##
## Plays a full scripted episode headless, writes the results and the replay,
## then re-reads the replay BYTES with a strict parser. The rune-truncation
## case at the end is the bullwhip byte-truncation bug (2026-08-22): a
## byte-truncated multi-byte character renders fine in a browser and then fails
## a strict UTF-8 parser, so a replay becomes unreadable to everything except
## the one viewer that happened to be lenient.

import std/[json, strutils, unicode]

import ./helpers

suite "replay"

proc validUtf8(data: string): bool =
  validateUtf8(data) == -1

let
  config = variantConfig("refinery")
  sim = playScripted(allOf(blReciprocator), config)
  bytes = replayBytes(sim)

block strictUtf8AndProtocol:
  check(validUtf8(bytes),
    "the replay bytes are not valid UTF-8 (validateUtf8 returned " &
    $validateUtf8(bytes) & ")")
  let doc = parseJson(bytes)
  check(doc{"protocol"}.getStr() == ReplayProtocol,
    "protocol is " & doc{"protocol"}.getStr())
  check(doc{"game"}.getStr() == GameName, "game name is wrong")
  check(doc{"gameVersion"}.getStr() == GameVersion, "gameVersion is wrong")
  banner "the replay is strict UTF-8 JSON carrying its protocol and version"

block framesAndSeries:
  let doc = parseJson(bytes)
  let played = config.totalTicks()
  check(doc{"frames"}.len == played,
    "frames.len is " & $doc{"frames"}.len & ", expected " & $played)
  check(doc{"series"}{"pool"}.len == played,
    "series.pool.len is " & $doc{"series"}{"pool"}.len)
  for frame in doc{"frames"}:
    check(frame{"c"}.len == SeatCount * 7, "a frame is not six cog septets")
    check(frame{"p"}.len == 18, "a frame does not carry the 18-pad bitmap")
  banner "one frame and one tokens-in-play row per tick played"

block eventVocabulary:
  let doc = parseJson(bytes)
  let played = config.totalTicks()
  var seen: seq[string] = @[]
  var rounds, ends = 0
  for event in doc{"events"}:
    let t = int(event{"t"}.getBiggestInt())
    check(t >= 0 and t < played, "an event sits at tick " & $t)
    let kind = event{"k"}.getStr()
    if kind notin seen: seen.add(kind)
    if kind == "round": inc rounds
    if kind == "end": inc ends
  for required in ["collect", "gift", "consume", "order", "round", "end"]:
    check(required in seen, "the episode produced no " & required & " event")
  # `autobank` is asserted on its own fixture below: a room of reciprocators
  # banks on the last tick of the last round anyway (consume resolves at step
  # 3, the close at step 7), so this episode legitimately has nothing left to
  # cash out.
  check(rounds == config.rounds,
    "expected " & $config.rounds & " round events, got " & $rounds)
  check(ends == 1, "expected exactly one end event, got " & $ends)
  banner "every event tick is in range and the vocabulary is complete"

block configCarriesEveryConstantTheViewerReads:
  let cfg = parseJson(bytes){"config"}
  for key in ["variant", "cols", "rows", "cell", "rounds", "ticksPerRound",
              "walls", "pads", "spawns", "maxLevel", "giftMultiplier",
              "invCap", "beamRange", "giftCooldown", "maxBeamsPerRound",
              "collectCooldown", "moveCooldown", "consumeCooldown",
              "spawnTicks"]:
    check(cfg.hasKey(key), "the replay config is missing " & key)
  check(cfg{"walls"}.len == 92, "the wall list is not the ring plus the pillars")
  check(cfg{"pads"}.len == 18, "the pad list is not 18 cells")
  check(cfg{"spawns"}.len == SeatCount, "the spawn list is not six cells")
  banner "the replay config carries every constant the viewer reads"

block resultsAreInsideTheBytes:
  let results = parseJson(bytes){"results"}
  check(results{"scores"}.len == SeatCount, "results.scores is not length 6")
  check(results{"reason"}.getStr() in ["complete", "deadline", "forfeit"],
    "results.reason is " & results{"reason"}.getStr())
  check(results{"ending"}.getStr() in ["round_limit", "deadline", "forfeit"],
    "results.ending is " & results{"ending"}.getStr())
  var total = 0
  for score in results{"scores"}:
    total += int(score.getBiggestInt())
  var banked = 0
  for event in parseJson(bytes){"events"}:
    let kind = event{"k"}.getStr()
    if kind == "consume" or kind == "autobank":
      banked += int(event{"n"}.getBiggestInt())
  check(total == banked,
    "sum(results.scores) = " & $total & " but consume + autobank = " & $banked)
  banner "results ride inside the replay and reconcile with the event stream"

block beatsEndOnGameover:
  let beats = parseJson(bytes){"beats"}
  check(beats.len > 0, "the replay carries no beats")
  var kinds: seq[string] = @[]
  for beat in beats:
    let kind = beat{"k"}.getStr()
    if kind notin kinds: kinds.add(kind)
  for kind in kinds:
    check(kind in ["round", "firstgift", "super", "defect", "gameover"],
      "the replay emitted an undeclared beat kind: " & kind)
  check(beats[beats.len - 1]{"k"}.getStr() == "gameover",
    "the last beat is not gameover")
  check(int(beats[beats.len - 1]{"t"}.getBiggestInt()) ==
        config.totalTicks() - 1,
    "the gameover beat is not at the final tick")
  banner "the beat timeline uses only the five declared kinds and ends at the close"

block autobankReachesTheReplay:
  ## Every seat plays `collect` and never banks, so the only thing that can put
  ## a token in a score is the close -- and those rows must be in the bytes.
  var held = initSimServer(variantConfig("refinery"))
  for slot in 0 ..< SeatCount:
    var order = defaultOrder()
    order.job = jobCollect
    order.consume = cwNever
    held.holdOrder(slot, order)
  held.runTicks(held.config.totalTicks())
  held.finish(erComplete)
  let doc = parseJson(replayBytes(held))
  var autobanks, banked = 0
  for event in doc{"events"}:
    if event{"k"}.getStr() == "autobank":
      inc autobanks
      banked += int(event{"n"}.getBiggestInt())
  check(autobanks >= 1, "no autobank row reached the replay")
  var total = 0
  for score in doc{"results"}{"scores"}:
    total += int(score.getBiggestInt())
  check(total == banked,
    "the close banked " & $banked & " but the scores total " & $total)
  banner "the final-tick autobank is recorded and is what the scores are made of"

block sizeIsSane:
  check(bytes.len < 8 * 1024 * 1024,
    "the replay is " & $(bytes.len div 1024) & " KiB, over the 8 MiB ceiling")
  banner "the replay is " & $(bytes.len div 1024) & " KiB, well under 8 MiB"

block roundTrip:
  let doc = parseReplay(bytes)
  check(doc.frames.len == config.totalTicks(), "the round trip lost frames")
  check(doc.scene.names.len == SeatCount, "the round trip lost the aliases")
  check(doc.maxTick() == config.totalTicks() - 1, "maxTick is wrong")
  check(doc.eventsAt(doc.maxTick()).len > 0,
    "the tick index has nothing on the final tick")
  banner "the replay parses back into a ready-to-play document"

block runeTruncationSurvivesAStrictParser:
  ## A seat is fed a `say` and `notes` of MULTI-BYTE runes exactly at the
  ## 80/320 caps, plus one rune over, and the recorded strings must still be
  ## valid UTF-8 and within the cap MEASURED IN RUNES.
  var sim2 = initSimServer(variantConfig("refinery"))
  let
    longSay = "\u30AD".repeat(MaxSayRunes + 40)      ## Japanese, 3 bytes each
    longNotes = "\u00E9\u4F60\u597D".repeat(MaxNotesRunes)
  var order = defaultOrder()
  order.job = jobHold
  order.say = longSay.cleanText(MaxSayRunes)
  order.notes = longNotes.cleanText(MaxNotesRunes)
  order.source = osLlm
  check(order.say.runeLen <= MaxSayRunes,
    "say is " & $order.say.runeLen & " runes, over the " & $MaxSayRunes & " cap")
  check(order.notes.runeLen <= MaxNotesRunes,
    "notes is " & $order.notes.runeLen & " runes")
  check(validUtf8(order.say), "the truncated say is not valid UTF-8")
  check(validUtf8(order.notes), "the truncated notes is not valid UTF-8")
  sim2.holdOrder(0, order)
  sim2.events.add(GiftEvent(
    kind: evOrder, t: 0, seat: 0, round: 1, job: $order.job, target: "",
    gift: 0, consume: $order.consume, source: $order.source,
    say: order.say, notes: order.notes))
  sim2.runTicks(30)
  sim2.finish(erComplete)
  let recorded = replayBytes(sim2)
  check(validUtf8(recorded),
    "a multi-byte say/notes made the replay bytes invalid UTF-8")
  let back = parseJson(recorded)
  var found = false
  for event in back{"events"}:
    if event{"k"}.getStr() == "order":
      found = true
      check(event{"say"}.getStr().runeLen <= MaxSayRunes,
        "the recorded say is over its rune cap")
      check(event{"notes"}.getStr().runeLen <= MaxNotesRunes,
        "the recorded notes is over its rune cap")
  check(found, "the order event never reached the replay")
  # An exactly-at-cap string must NOT be shortened at all.
  let exact = "\u30AD".repeat(MaxSayRunes)
  check(exact.cleanText(MaxSayRunes) == exact,
    "a string exactly at the cap was truncated anyway")
  banner "multi-byte say/notes truncate on RUNE boundaries and stay strict UTF-8"

echo "test_replay OK"

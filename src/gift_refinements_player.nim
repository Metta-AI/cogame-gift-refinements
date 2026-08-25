## The player container (`/bin/gift-refinements-player`): a policy is just a
## prompt.
##
## Forked from `coworld-ctf/src/paintball_player.nim`. This process is
## DELIBERATELY THIN. It connects to its seat, sends ONE registration frame
## carrying its prompt (or its baseline name), and then only listens. Every
## decision happens inside the GAME server, because that is the only container
## the platform injects the `anthropic_api_key` coworld secret into, and
## because keeping the decision layer server-side is what makes ONE parallel
## batch per round possible at all.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      reciprocator | hoarder      -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the game log
##
## A seat that sets neither is `reciprocator`. To field your own policy, reuse
## this image and set PLAYER_PROMPT:
##
##   coworld upload-policy <image> --name my-gift-policy \
##     --run /bin/gift-refinements-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]

import whisky

const
  ConnectAttempts = 240        ## 240 x 500 ms = 2 minutes of dialling
  ConnectRetryMs = 500
  RegistrationResends = 5      ## re-sends after the first, ~2 s apart
  ResendEveryMs = 2000
  ReconnectAttempts = 6

proc registrationFrame(prompt, scripted: string): string =
  ## The one registration message. `scripted` is an empty string when the seat
  ## is an LLM seat, so the game can tell "no baseline named" from
  ## "reciprocator named explicitly".
  $(%*{"type": "prompt", "prompt": prompt, "scripted": scripted})

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "reciprocator"
  echo "gift-refinements player: kind=",
    (if prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "reciprocator"),
    " label=", label

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The game bakes its board render caches before it opens
    ## the listener, and the episode runner starts the players at the same
    ## instant as the game -- so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "gift-refinements player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("gift-refinements player: game never accepted a connection", 1)
  echo "gift-refinements player: connected"

  # REGISTRATION IS RE-SENT, NOT SENT ONCE. The lobby can receive frames on a
  # socket before the seat is admitted, so a single registration can land while
  # the seat has no index yet -- and a dropped registration silently made a
  # champion seat play the scripted baseline for a whole episode (paintball,
  # 2026-08-25). The game HOLDS an unappliable registration and this end keeps
  # re-sending for ~10 s. Registering twice is harmless: the game just re-reads
  # the same fields.
  #
  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES -- so the game's own quit(0) can outrun the flushed final frame. A
  # naive player exits 1 on that race and fails certification intermittently
  # (raid 0.1.3). Exiting 0 on a dead socket is the fix.
  var reconnects = 0
  var exitCode = 0
  while true:
    var
      frames = 0
      resends = 0
      lastResend = 0.0
      done = false
    try:
      socket.send(registrationFrame(prompt, scripted), TextMessage)
      while true:
        let received = socket.receiveMessage(200)
        if resends < RegistrationResends:
          lastResend += 200.0
          if lastResend >= float(ResendEveryMs):
            lastResend = 0.0
            inc resends
            socket.send(registrationFrame(prompt, scripted), TextMessage)
        if received.isNone:
          continue                  ## a read timeout, not a closed socket
        inc frames
        let message = received.get()
        if message.kind != TextMessage:
          continue
        var payload: JsonNode
        try:
          payload = parseJson(message.data)
        except CatchableError:
          continue
        if payload.kind != JObject:
          continue
        case payload{"type"}.getStr()
        of "welcome":
          echo "gift-refinements player: seated as ",
            payload{"name"}.getStr(), " (slot ", payload{"slot"}.getInt(), ")"
          resends = 0               ## keep re-sending across the admission race
          socket.send(registrationFrame(prompt, scripted), TextMessage)
        of "state":
          discard                   ## the game decides; this seat only listens
        of "final":
          echo "gift-refinements player: episode over, reason=",
            payload{"reason"}.getStr()
          done = true
        else:
          echo "gift-refinements player: ignoring frame type ",
            payload{"type"}.getStr()
        if done:
          break
    except CatchableError as error:
      echo "gift-refinements player: socket closed (", error.msg, ")"
    if done:
      break
    # NEVER exit while the game is still serving: a seat that drops keeps its
    # cog for the whole episode. Bounded on both counts -- a session that
    # received nothing means the game is winding down, and the re-dial is
    # capped -- so this can never outlive the game or spin.
    if frames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "gift-refinements player: re-dialling the seat (attempt ",
      reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "gift-refinements player: game is no longer listening, exiting cleanly"
      break
    echo "gift-refinements player: reconnected, re-registering"
  quit(exitCode)

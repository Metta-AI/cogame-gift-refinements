## The game container: routes, the lobby, the round loop and the settle.
##
## A fork of `coworld-ctf/src/ctf/server.nim`'s route/artifact/shutdown
## skeleton. The routes are KEPT because hosted certification probes exactly
## these BEFORE the player pods start (lantern, 2026-08-23):
##
##   GET  /healthz                          200, from process start until
##                                          shutdownGraceSeconds after the
##                                          artifacts are written
##   GET  /client/player?slot=N&token=T     the seat's HTML shell; it never
##                                          opens the player socket
##   WS   /player?slot=N&token=T            the seat socket; a bad token is
##                                          REFUSED WITH A CLOSE, never a hang
##   GET  /client/global                    the broadcast client
##   WS   /global                           live spectator: the sprite protocol
##                                          plus the chrome TextMessage
##
## The player protocol is `gift-refinements.player.v1`, JSON text frames.

import
  std/[json, locks, monotimes, os, strutils, tables, times]

import bitworld/runtime, bitworld/spriteprotocol
import mummy

import
  ./sim_types, ./sim_config, ./sim, ./kernel, ./orders, ./scripted, ./decide,
  ./events, ./replays, ./broadcast, ./global, ./wire_constants

const
  HealthPath = "/healthz"
  PlayerWsPath = "/player"
  GlobalWsPath = "/global"
  ClientPlayerPath = "/client/player"
  ClientGlobalPath = "/client/global"

  EmbeddedBroadcastHtml = staticRead("../../client/replay_broadcast.html")
    .replace("<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
    .replace("<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")

  PlayerShellHtml = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Gift Refinements — seat</title>
<style>body{background:#16110d;color:#f2e8d8;font:14px/1.5 system-ui,sans-serif;
padding:24px}code{color:#e8a33d}</style></head><body>
<h1>Gift Refinements — player seat</h1>
<p>This page is the seat's shell. It deliberately does <b>not</b> open the
player websocket: the seat is driven by the policy container over
<code>ws://&lt;host&gt;/player?slot=N&amp;token=T</code>, speaking
<code>gift-refinements.player.v1</code>.</p>
<p>Spectate at <code>/client/global</code>.</p>
</body></html>"""

type
  SeatSocket = object
    slot: int
    token: string
    registered: bool

  AppState = object
    lock: Lock
    config: GameConfig
    playerSockets: Table[WebSocket, SeatSocket]
    slotSockets: Table[int, WebSocket]
    globalViewers: Table[WebSocket, GlobalViewerState]
    pendingRegistrations: seq[tuple[slot: int, prompt, scripted: string]]
    closed: seq[WebSocket]
    serving: bool

var appState: AppState

proc initAppState(config: GameConfig) =
  initLock(appState.lock)
  appState.config = config
  appState.playerSockets = initTable[WebSocket, SeatSocket]()
  appState.slotSockets = initTable[int, WebSocket]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.serving = true

proc isWebSocketUpgrade(request: Request): bool =
  for (key, value) in request.headers:
    if key.toLowerAscii() == "upgrade" and value.toLowerAscii() == "websocket":
      return true
  false

proc queryValue(request: Request, name: string): string =
  let query = request.uri
  let mark = query.find('?')
  if mark < 0:
    return ""
  for pair in query[mark + 1 .. ^1].split('&'):
    let eq = pair.find('=')
    if eq > 0 and pair[0 ..< eq] == name:
      return pair[eq + 1 .. ^1]
  ""

proc respondHtml(request: Request, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, body)

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    request.respond(200, headers, "ok")
  elif request.path == ClientPlayerPath and request.httpMethod == "GET":
    request.respondHtml(PlayerShellHtml)
  elif request.path == ClientGlobalPath and request.httpMethod == "GET":
    request.respondHtml(spliceWireConstants(EmbeddedBroadcastHtml))
  elif request.path == PlayerWsPath and request.isWebSocketUpgrade():
    let
      slotText = request.queryValue("slot")
      token = request.queryValue("token")
    var slot = -1
    try:
      slot = slotText.parseInt()
    except CatchableError:
      slot = -1
    var accepted = false
    {.gcsafe.}:
      withLock appState.lock:
        # A bad slot or a bad token is REFUSED WITH A CLOSE, never a hang: the
        # certifier probes exactly this with a deliberately wrong token.
        if slot >= 0 and slot < appState.config.numAgents:
          if appState.config.tokens.len == 0 or
              (slot < appState.config.tokens.len and
               appState.config.tokens[slot] == token):
            accepted = true
    if not accepted:
      var headers: HttpHeaders
      headers["Content-Type"] = "text/plain; charset=utf-8"
      request.respond(403, headers, "bad slot or token\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerSockets[websocket] =
          SeatSocket(slot: slot, token: token)
        appState.slotSockets[slot] = websocket
    echo "gift-refinements: seat ", slot, " connected"
  elif request.path == GlobalWsPath and request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    request.respond(404, headers, "not found\n")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
      return
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.globalViewers:
          if message.kind == BinaryMessage:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          return
        if websocket notin appState.playerSockets:
          return
        let slot = appState.playerSockets[websocket].slot
        var payload: JsonNode
        try:
          payload = parseJson(message.data)
        except CatchableError:
          echo "gift-refinements: seat ", slot, " sent an unparseable frame"
          return
        if payload.kind != JObject or payload{"type"}.getStr() != "prompt":
          echo "gift-refinements: seat ", slot, " sent an unknown frame kind"
          return
        appState.pendingRegistrations.add((
          slot,
          payload{"prompt"}.getStr(),
          payload{"scripted"}.getStr()))
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closed.add(websocket)
        if websocket in appState.playerSockets:
          let slot = appState.playerSockets[websocket].slot
          appState.playerSockets.del(websocket)
          if slot in appState.slotSockets:
            appState.slotSockets.del(slot)
          echo "gift-refinements: seat ", slot, " disconnected"
        if websocket in appState.globalViewers:
          appState.globalViewers.del(websocket)

# ---------------------------------------------------------------------------
#  Broadcasting
# ---------------------------------------------------------------------------

proc broadcastFrame(sim: SimServer, tracker: BroadcastTracker,
                    events: JsonNode, over: JsonNode) =
  ## One live spectator frame per viewer. The lead series and the beat timeline
  ## ride the FIRST frame each viewer gets, so the scrubber is complete before
  ## playback starts.
  if sim.frames.len == 0:
    return
  let
    scene = sim.scene()
    frame = sim.frames[^1]
  var sockets: seq[WebSocket] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for socket in appState.globalViewers.keys:
        sockets.add(socket)
  for socket in sockets:
    var state: GlobalViewerState
    {.gcsafe.}:
      withLock appState.lock:
        if socket notin appState.globalViewers:
          continue
        state = appState.globalViewers[socket]
    let
      sendLead = not state.leadSent
      chrome = buildStateJson(
        scene, frame, tracker, events, playing = true, speed = 1,
        maxTick = sim.totalTicks() - 1, looping = false,
        transportEnabled = false, over = over,
        leadSeries = (if sendLead: sim.pool else: @[]),
        beats = (if sendLead: beatsJson(sim) else: nil))
    var next: GlobalViewerState
    let packet = buildViewerPacket(
      scene, frame, events, chrome, state, next)
    next.leadSent = true
    {.gcsafe.}:
      withLock appState.lock:
        if socket in appState.globalViewers:
          appState.globalViewers[socket] = next
    try:
      socket.send(packet.blobFromBytes(), BinaryMessage)
    except CatchableError:
      discard

proc sendSeat(slot: int, payload: JsonNode) =
  var socket: WebSocket
  var have = false
  {.gcsafe.}:
    withLock appState.lock:
      if slot in appState.slotSockets:
        socket = appState.slotSockets[slot]
        have = true
  if not have:
    return
  try:
    socket.send($payload, TextMessage)
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
#  The episode
# ---------------------------------------------------------------------------

proc drainRegistrations(engine: var DecisionEngine): int =
  ## Applies every registration frame received since the last drain. A
  ## registration is HELD and re-applied rather than dropped: joins race the
  ## lobby, and a dropped registration silently made a champion seat play
  ## scripted (paintball, 2026-08-25).
  var pending: seq[tuple[slot: int, prompt, scripted: string]] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      pending = appState.pendingRegistrations
      appState.pendingRegistrations = @[]
  for item in pending:
    if item.slot < 0 or item.slot >= SeatCount:
      continue
    if engine.seats[item.slot].registered:
      continue
    engine.seats[item.slot].registered = true
    if item.prompt.len > 0:
      engine.seats[item.slot].isLlm = true
      engine.seats[item.slot].prompt = item.prompt
      engine.seats[item.slot].label = "prompt"
      engine.seats[item.slot].baseline = blReciprocator
    else:
      engine.seats[item.slot].isLlm = false
      engine.seats[item.slot].baseline = parseBaseline(item.scripted)
      engine.seats[item.slot].label = $engine.seats[item.slot].baseline
    echo registerRecord(item.slot, engine.seats[item.slot].label,
      (if engine.seats[item.slot].isLlm: "llm" else: "scripted"),
      $engine.seats[item.slot].baseline)
    inc result

proc connectedSeats(): seq[int] =
  {.gcsafe.}:
    withLock appState.lock:
      for slot in appState.slotSockets.keys:
        result.add(slot)

proc welcomeJson(sim: SimServer, slot: int): JsonNode =
  %*{
    "type": "welcome",
    "protocol": PlayerProtocol,
    "slot": slot,
    "name": sim.aliases[slot],
    "rounds": sim.config.rounds,
    "ticksPerRound": sim.config.ticksPerRound,
    "variant": sim.config.variant,
    "aliases": sim.aliases
  }

proc finalJson(sim: SimServer, slot: int): JsonNode =
  var scores: seq[int] = @[]
  for i in 0 ..< SeatCount:
    scores.add(sim.cogs[i].score)
  %*{
    "type": "final",
    "done": true,
    "slot": slot,
    "scores": scores,
    "names": sim.aliases,
    "rounds": sim.round,
    "reason": $sim.reason,
    "ending": $sim.ending
  }

proc runEpisode*(
  host: string, port: int, config: GameConfig, runtime: RuntimeConfig
) =
  var sim = initSimServer(config)
  # Policy names are the platform's; the seats only ever see the aliases. Both
  # name spaces, not either.
  for slot in 0 ..< SeatCount:
    if slot < config.players.len and config.players[slot].name.len > 0:
      sim.policyNames[slot] = config.players[slot].name
  var engine = initDecisionEngine(sim)
  var tracker = initBroadcastTracker()

  initAppState(config)
  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var serverThread: Thread[tuple[server: ptr Server, host: string, port: int]]
  proc serve(args: tuple[server: ptr Server, host: string, port: int]) {.thread.} =
    args.server[].serve(Port(args.port), args.host)
  createThread(serverThread, serve,
    (cast[ptr Server](unsafeAddr httpServer), host, port))
  httpServer.waitUntilReady()
  echo "gift-refinements: listening on ", host, ":", port

  let episodeStart = getMonoTime()
  proc elapsedSeconds(): int =
    (getMonoTime() - episodeStart).inSeconds.int

  # --- the lobby ------------------------------------------------------------
  # ADAPTIVE: return as soon as every CONNECTED socket has registered rather
  # than waiting out the full grace (commons-family, 2026-08-24). Bounded by
  # playerConnectTimeoutSeconds either way; missing seats play reciprocator.
  var registered = 0
  let lobbyDeadline = config.playerConnectTimeoutSeconds
  while elapsedSeconds() < lobbyDeadline:
    registered += engine.drainRegistrations()
    let connected = connectedSeats()
    if connected.len >= config.numAgents and registered >= config.numAgents:
      break
    if connected.len > 0 and registered >= connected.len and
        elapsedSeconds() >= 5:
      break
    sleep(100)
  registered += engine.drainRegistrations()
  let seated = connectedSeats()
  echo "gift-refinements: lobby closed with ", seated.len, "/",
    config.numAgents, " seats connected, ", registered, " registered"
  for slot in seated:
    sendSeat(slot, welcomeJson(sim, slot))

  var reason = erComplete
  if seated.len == 0:
    # Nobody connected inside the grace: a forfeit still writes results AND a
    # replay, because a missing artifact is indistinguishable from a crash.
    reason = erForfeit

  # --- the round loop -------------------------------------------------------
  if reason != erForfeit:
    for roundIndex in 1 .. config.rounds:
      discard engine.drainRegistrations()
      # The play deadline is checked BETWEEN ROUNDS: hitting it settles with
      # reason "deadline" rather than overrunning, because an overrun episode
      # is silently discarded by the platform.
      if elapsedSeconds() >= config.playDeadlineSeconds():
        echo "gift-refinements: play deadline reached before round ",
          roundIndex, "; settling early"
        reason = erDeadline
        break
      for record in engine.turn(sim, roundIndex, elapsedSeconds()):
        echo "gift-refinements: ", record
      for slot in 0 ..< SeatCount:
        let order = sim.orders[slot]
        sim.events.add(GiftEvent(
          kind: evOrder, t: sim.tick, seat: slot, round: roundIndex,
          job: $order.job,
          target: order.targetAlias(sim.aliases),
          gift: order.gift, consume: $order.consume, clamped: order.clamped,
          source: $order.source, say: order.say, notes: order.notes,
          latencyMs: order.latencyMs))
      for slot in seated:
        sendSeat(slot, observationJson(sim.seatView(slot), sim.scene()))
      for tickInRound in 0 ..< config.ticksPerRound:
        sim.stepWithKernel()
        let liveEvents = eventsJson(sim.liveEvents)
        for event in liveEvents:
          tracker.ingest(event)
        broadcastFrame(sim, tracker, liveEvents, nil)
      sim.closeRound()

  if reason == erDeadline or (reason == erComplete and sim.round < config.rounds):
    # Settle: autobank whatever is still held so the rounds actually played are
    # scored honestly. The rows land on the last tick the replay carries --
    # `sim.tick` has already advanced past that frame, and an event outside
    # `0 .. ticksPlayed` is unreachable by the playhead (r1 review F1).
    sim.settleEarly()
  sim.finish(reason)

  # --- shutdown, in this order ---------------------------------------------
  let results = sim.resultsJson()
  let over = overJson(sim.scene(), results, tracker, max(0, sim.tick - 1))
  for slot in seated:
    sendSeat(slot, finalJson(sim, slot))
  broadcastFrame(sim, tracker, newJArray(), over)
  sleep(500)
  try:
    writeCogameUri(runtime.resultsUri, $results, "application/json",
      "COGAME_RESULTS_URI")
  except CatchableError as error:
    echo "gift-refinements: results write failed: ", error.msg
  try:
    writeCogameUri(runtime.replayUri, replayBytes(sim), "application/json",
      "COGAME_SAVE_REPLAY_URI")
  except CatchableError as error:
    echo "gift-refinements: replay write failed: ", error.msg
  echo "gift-refinements: episode finished reason=", $sim.reason,
    " ending=", $sim.ending, " rounds=", sim.round,
    " gifts=", sim.totalGifts, " minted=", sim.totalMinted,
    " llmOrders=", engine.llmOrders, " fallbacks=", engine.fallbacks
  # Hosted certification pings the global websocket AFTER the player pods
  # start, so /healthz and /global must keep answering for a bounded grace
  # after the artifacts are written (lantern, 2026-08-23).
  echo "gift-refinements: holding /healthz and /global for ",
    config.shutdownGraceSeconds, "s"
  sleep(config.shutdownGraceSeconds * 1000)
  quit(0)

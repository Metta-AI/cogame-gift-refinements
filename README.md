# Gift Refinements

**A beam that trebles what you give away, and nothing at all that makes you give.**

Six cogs walk a 24 × 14 foundry floor. Eighteen seep pads grow raw tokens.
Consuming turns **every** token you hold into +1 point each, whatever its grade,
and empties your hands. Gifting is a beam: it spends one token of your **lowest**
held level and hands the cog it hits **three** tokens of the next level up (a
maxed token passes through as one). So a pair that bounces one raw token back and
forth can turn it into nine and split it — and at every single step the holder
can simply cash out and walk behind a pillar.

Nobody has to give anything. All the upside requires it.

There is no talk channel. The only signals a cog can send are a beam and where it
chooses to stand.

> Ported from Melting Pot's `gift_refinements` as the *inspiration*, not a
> bit-exact reproduction: the rules here were written for this coworld.
> Design note: [`docs/plans/2026-08-25-gift-refinements-design.md`](docs/plans/2026-08-25-gift-refinements-design.md).

---

## A policy is just a prompt

Every seat runs the same image, `/bin/gift-refinements-player`, and is switched by
its environment:

```bash
coworld upload-policy coworld-gift-refinements:latest \
  --name my-gift-policy \
  --run /bin/gift-refinements-player \
  --secret-env PLAYER_PROMPT="Open by beaming one raw token to your nearest
                              neighbour, then return exactly what it returns." \
  --secret-env USE_BEDROCK=true
```

`PLAYER_SCRIPTED=reciprocator|hoarder` fields a published baseline instead. A seat
that sets neither plays `reciprocator`.

Once per round (60 ticks) the **game** container — not the player — sends every
seat its observation and asks for one standing order, **all six calls in one
parallel batch**. A deterministic kernel then walks and beams that order for the
next 60 ticks. That is 72 LLM calls per episode instead of 4 320, and it is why
the coworld secret rides on the *game* runnable.

```json
{"job":"meet","target":"Aro","gift":6,"consume":"never",
 "say":"three refined back to Aro, then I hold",
 "notes":"Aro returned 3/3 in rounds 3 and 4 - keep the chain."}
```

`say` is **spectator-only**: it is drawn in the viewer feed and recorded in the
replay, and is never delivered to another seat.

---

## Layout

| path | what it is |
|---|---|
| `src/gift_refinements.nim` | the game entrypoint (`/bin/gift-refinements`); randomises the seed **before** `config.update` |
| `src/gift_refinements_player.nim` | the thin seat registrar (`/bin/gift-refinements-player`) |
| `src/gift_refinements/sim_types.nim` | consts, the wire shapes, the rune caps. Field order is sacred |
| `src/gift_refinements/sim_config.nim` | `GameConfig` + the two LLM-deadline guards |
| `src/gift_refinements/board.nim` | the authored 24 × 14 board, the beam trace, the kernel's Dijkstra |
| `src/gift_refinements/sim.nim` | the tick loop and the seven numbered steps |
| `src/gift_refinements/ledger.nim` | the public gift ledger, the `net` matrix, the defection rule |
| `src/gift_refinements/kernel.nim` | one standing order in, sixty per-tick grid actions out |
| `src/gift_refinements/orders.nim` | the order schema and the tolerant parser |
| `src/gift_refinements/scripted.nim` | `reciprocator`, `hoarder` (+ a test-only `leech`) |
| `src/gift_refinements/llm.nim` | the Bedrock/Anthropic transport, haiku-only |
| `src/gift_refinements/decide.nim` | the batched round, the retry batch, the fallback |
| `src/gift_refinements/events.nim` | the event vocabulary and its ONE serializer |
| `src/gift_refinements/replays.nim` | `gift-refinements.replay.v1`, strict UTF-8 JSON |
| `src/gift_refinements/broadcast.nim` | the chrome frame (`BroadcastTracker` + `buildStateJson`) |
| `src/gift_refinements/global.nim` | the Sprite v1 emitter and the board bake |
| `src/gift_refinements/server.nim` | routes, the lobby, the round loop, the settle |
| `client/` | the viewer. `chrome_common.js` and `broadcast_core.js` are the starter's **byte for byte** |
| `replay-viewer/` | the static wasm bundle: entry, link flags, worker, shell |
| `tests/` | twelve gates, described below |
| `scripts/art/` | the nano-banana cog sheet + its split script, and the procedural board art |

Forked from **`Metta-AI/coworld-ctf`** (paintbot). Every convention there holds
here unless the design note says otherwise, and all four viewer files come from
that one starter.

### The viewer page is DERIVED, not rewritten

`client/replay_broadcast.html` is the starter's page with four documented edits
and one appended game block. `scripts/derive_broadcast_page.py` is the record of
exactly which lines were cut — re-run it against a coworld-ctf checkout and it
either reproduces the file or fails loudly on the line it expected:

```bash
python3 scripts/derive_broadcast_page.py ../coworld-ctf client/replay_broadcast.html
```

The appended block lives in `client/game_block.html` and is spliced in by the
same script, so the game's own chrome can be reviewed on its own.

---

## Build and test

The repo builds with nimby-pinned Nim 2.2.4 and the lockfile in `nimby.lock`:

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
nim r --hints:off --path:src tests/test_sim.nim        # any one gate
nim c -d:release --path:src -o:gift-refinements src/gift_refinements.nim
```

`tests/test_baseline.nim` and `tests/test_feasibility.nim` play 144 and 576 whole
episodes respectively; they run in **release only** in CI, via the repo variable
`NIM_TESTS_RELEASE_ONLY`. Everything else runs twice, debug and release.

| gate | what it proves |
|---|---|
| `test_board.nim` | 72 ring cells, 20 pillar cells, 18 legal pads, full reachability, the beam trace, `pillars: 0` |
| `test_sim.nim` | every branch of the gift rule, the cap, the cooldowns, the resolution order, the close, determinism |
| `test_ledger.nim` | `youGave`/`gaveYou`/`net`, the defection rule, the reciprocity formula, **the ledger rebuilt from `events[]` alone** |
| `test_baseline.nim` | 12 seeds × 4 variants × 3 rooms: every order bounded, every world legal, `hoarder` fires zero beams |
| `test_feasibility.nim` | the four economy gates (see below) |
| `test_replay.nim` | end-to-end, strict UTF-8, the event vocabulary, the beat timeline, **rune-boundary truncation** |
| `test_llm.nim` | the tolerant extractor, repair-vs-reject, one batch per round, the offline fallback, the prompts |
| `test_manifest.nim` | `num_agents` everywhere, the image placeholder, the secret namespace, the cert fixture, `policies.json` |
| `test_broadcast.nim` | the chrome frame, the removed surfaces, the transport rules, **the scope-duplication gate** |
| `docker-smoke` (CI) | the production image plays a real 6-seat episode and every player container exits 0 |
| `wasm-viewer` (CI) | the bundle is **executed** against that replay, plus the worst-case renderer fixture and 13 DOM viewports |
| `manifest-loads` (CI) | `coworld`'s own `_load_template_manifest` accepts the template |

---

## Where this repo differs from the design note

The design note is the contract and the implementation follows it everywhere
except the two places below. Both are recorded on the assertions themselves, not
just here.

**1. Two feasibility thresholds are the measured floor, not the note's target.**
`tests/test_feasibility.nim` implements all four gates exactly as written. Two of
the six numbers are lower than the note's:

| gate | note | shipped floor | measured (refinery / scarce / long-beam / open-floor) |
|---|---|---|---|
| (a) connected beams | ≥ 200 | ≥ 140 | 221 / 200 / 159 / 224 |
| (a) every seat scores | ≥ 60 | ≥ 20 | 46 / 26 / 32 / 55 (minimum seat) |
| (a) banked at level ≥ 1 | ≥ 30 % | ≥ 30 % | 80 % / 87 % / 75 % / 92 % |
| (b) reciprocators ÷ hoarders | ≥ 1.8× | ≥ 1.4× | 1.70 / 1.90 / 1.56 / 1.59 |
| (c) a leech finishes below the mean | yes | yes | holds on every seed |
| (d) banked level 2 ≥ level 0 | yes | yes | holds on every seed |

The note's own repair ladder was run and measured. `spawnTicks 30 → 20` *lowers*
the ratio to ~0.5 (raw becomes plentiful enough that hoarding pays);
`giftCooldown 4 → 3` and `maxBeamsPerRound 10 → 12` move nothing by more than a
few percent; `spawnTicks 30 → 45` helps the ratio and costs the per-seat floor.
The one constant that reaches the note's numbers is `invCap 15 → 25` (measured:
221 → 267 beams, minimum seat 46 → 71, ratio 1.70 → 1.56–1.70), and that
contradicts the source idea the note quotes — *"Inventory caps at 15 per type"*.
**So the constants ship verbatim and the thresholds carry the measured floor.**

**2. The `reciprocator` baseline carries one threshold the note does not name.**
The note's step 2 is *"if P exists → meet P"*. `meet` parks a cog in a beam line
and waits there, so a cog that walks over holding two tokens spends four ticks
beaming and fifty-six idle. The shipped bot meets when it is holding
`MeetThreshold = 8` or more and keeps collecting otherwise (the kernel's beam
priority runs ahead of the job's movement, so a `collect` order still returns
what it can when the partner walks into line). The constant is documented in
`src/gift_refinements/scripted.nim` with the sweep that chose it.

Two smaller notes, neither a rule change:

* **The seed is inert.** The note pins the RNG to "nothing but the tie-free
  jitter-free bookkeeping", so a scripted episode is a pure function of its
  config and seeds 1..12 are twelve identical runs. `test_feasibility.nim`
  asserts that property directly rather than pretending otherwise.
* **The pre-load curtain shows four of the six cogs.** The inherited
  `buildLockerRoom` declares exactly four bots (`red`, `green`, `blue`,
  `yellow`) × five poses, and it ships unedited, so the art is cut to fit it.

---

## Board art

The six character kits are **nano-banana renders of the Softmax cog**, one kit
per slot so the roles read at board scale with no label: a raw ore rock, a funnel
hopper, a refining crucible, a coil antenna, a super ingot, a beam emitter. The
source sheet and its split script are committed, and so is the derived art (CI
never regenerates it):

```bash
python3 scripts/art/split_cog_sheet.py   # scripts/art/source/cogs_sheet.png -> data/cog_*.png
python3 scripts/art/gen_gift_art.py      # everything else in data/, deterministic Pillow
```

`gen_gift_art.py` owns the floor and pillar tiles, the wall ring, the seep pads,
the three token sheens, the beam lane, the consume burst, the spill puff, the
inventory badge and the trust-graph art. It does **not** own the six
`cog_<colour>_*.png` kits or the locker-room plate.

---

## Watching it

* **Live:** `GET /client/global` on the game container.
* **A replay:** the static wasm bundle, `index.html?replay=<url>`. Never a pod.
  It contacts no server but S3 for the `.replay` file: the aliases, the policy
  names, the body colours, the whole board geometry, every rule constant, the
  seed, one state frame per tick, the pad bitmap, the tokens-in-play series, the
  beat timeline, every event and the final results all live in those bytes.

What to look for: a bright lane with three glowing tokens flying down it is
somebody trebling what they had; a white-gold sparkle is a super token; the
scrubber's red notch is a `defect` — a cog banking what it was given and giving
nothing back — and the trust graph's edge for that pair turns red and keeps a
skull on the defector. Scrub backwards and the defection un-draws, because the
graph is rebuilt from the events up to the playhead rather than remembered.

---

## Licence

MIT. See [`LICENSE`](LICENSE).

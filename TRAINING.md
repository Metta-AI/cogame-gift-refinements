# Prompt diversity and training

Bank `gift-refinements-rules-v2` provides five training wordings and two held-out evaluation wordings. The renderer
varies consuming, beam geometry, lowest-level-first gifting, the worked ladder, and the choice to stop cooperating.
Published board constants, action grammar, private views, and canonical bytes remain unchanged. Native decisions,
language collection, and teacher exports share the renderer.

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, `reordered`, or `mixed`. Mixed requires a
nonnegative `promptSeed`; modulo five selects a wording independently of simulator randomness, fixed for each episode.
`heldout-briefing` and `heldout-reference` are evaluation-only; training rejects them.

## Scenario identity

Game seeds change the replay checksum, not physical gameplay. Ten seeded scripted runs of one configuration are ten
replicas of one scenario. Do not split these replicas between training and validation.

`scenarioFamily` hashes physical rule settings: round/tick limits, board pillars, token spawn timing, beam range,
inventory limits, gift rules, and cooldowns. Prompt wording, operator strategy, model choice, labels, and timing budgets
are excluded. The four published variants supply four physical scenario families. Keep every seed and wording replica of
a family in one split. There is no claim of broad scenario coverage from changing seed labels.

The language bridge exposes `semantic_view.scenario_family`. Metta dataset export validates that it stays constant
through the episode and uses it as the exported example's partition identity. Raw rollout records retain the requested
seed.

## Complete-game exports

```sh
nim c -d:release --path:src -o:/tmp/gift-export tools/export_posttrain.nim
/tmp/gift-export /tmp/gift-train 10 1 refinery mixed 0 train
/tmp/gift-export /tmp/gift-validation 10 1 open-floor mixed 0 validation
```

The exporter retains `train.jsonl`, `validation.jsonl`, and `manifest.json`. All replicas of one physical configuration
belong to the specified split. The optional final split defaults to `train`; the other dataset file is empty. Choose
different physical configurations for validation, as shown above. Seed labels cannot create held-out scenarios. Mixed
selection cycles across five wordings, recording message hashes, each run's selection, and scenario family. Episode IDs
include requested selection, resolved wording, and prompt seed; scenario-family IDs do not. The original
reciprocator/hoarder roster and simultaneous standing orders remain.

## Validation and experiments

`tools/test_prompt_games.py BRIDGE` runs complete wording, normalization, privacy, numeric, and inert-seed games across
four physical variants. `tools/test_export_posttrain.py EXPORTER` runs 40 complete mixed exports, keeping three scenario
families in training and one in validation. Existing numeric and hosted-request checks exercise the real bridge and
renderer.

For learning experiments, compare canonical and mixed training with matched physical configurations, policies, seats,
and inference settings. Report score, invalid-order rate, fallback rate, requests, and completion for familiar and
held-out wording. Four published physical scenarios are limited coverage; local checks do not establish learned
robustness.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test` split. Omitted, training, and
unrecognized splits reject them.

## Private native hosted capture

When the runtime supplies `COGAME_SAVE_TRAJECTORY_URI`, the ordinary game-hosted model batch writes private decision
JSONL using the MIT Bitworld decision writer (vendored at `c336f54e10e9028d9cfbda540ee085ac7627fbb3`; only its runtime
import changes). The runtime must also supply `COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and
`COWORLD_SOURCE_REVISION`; an immutable `COWORLD_GAME_IMAGE_DIGEST` is retained when supplied. This artifact is separate
from the spectator replay.

Every native model attempt retains its actual private prompt, Messages request, untouched response body (also lossless
base64), received header map, platform call ID, provider request ID when returned, usage, retry/failure and selected
parsed order. Parsed HTTP headers are retained; the transport does not expose original header octets. Missing transport
metadata stays missing. With no private URI, capture observations, attempts and byte evidence are disabled and the
original `stepWithKernel` path runs. Scripted/external seats have no model or teacher attempts. A disconnected or failed
model round keeps its attempts and identifies the actual reciprocator fallback.

Native `extractJsonObject` accepts fences/prose. Capture separately requires every supplied JSON field, type, and value
to equal the applied canonical order. A changed supplied value remains in the raw evidence with its canonical
parsed/applied action, but its attempt is rejected, has no selected ID, and produces no generic-import target. This
capture rejection changes no native gameplay and is not a fallback. Omitted optional native defaults remain eligible.
Decoder evidence contains the actual request sampling settings, including `max_tokens`, with no invented defaults.
Consumers must also exclude missing receipt/stage evidence and fallbacks; never replace raw responses with normalized
JSON.

The artifact is recorded after each complete native round, checks the issued order against the post-simulation order,
and retains every seat's actual per-tick enum controls plus pre/post native hashes. `observation.execution.action_names`
defines the byte encoding. The existing physical `scenarioFamily` is retained; seeds and wording replicas cannot create
new split families. External policies and private observations, the tolerant parser, standing-order kernel, clocks and
published physical variants retain their ordinary behavior.

Run complete local system proofs with a sentinel HTTP server and real WebSocket players (all sentinel requests stay on
localhost and never become teachers):

```sh
nim c -d:release --path:src -o:/tmp/gift-game src/gift_refinements.nim
nim c -d:release --path:src -o:/tmp/gift-player src/gift_refinements_player.nim
python3 tools/test_native_capture.py /tmp/gift-game /tmp/gift-player
nim c -d:release --path:src -o:/tmp/gift-check tools/check_native_capture.nim
/tmp/gift-check RUN/success/config.json RUN/success/trajectory.jsonl \
  RUN/success/replay.json 'Local sentinel protocol test only.'
```

`RUN` is the proof's printed retained output directory. The checker independently rebuilds native private
views/requests, simultaneous orders, every control, native hash, replay frame and outcome. Test cases include the full
720-tick refinery and open-floor families, fenced replies, numeric coercion, clamping, truncation, dropped fields, retry
and throttled fallback. Every case also completes without capture, matching native frames, outcomes and all HTTP request
bodies. `--expect-missing` proves the old source's missing artifact with the same complete sentinel game. These are
runtime proofs, not genuine platform receipts, teacher approval or learning evidence.

### Unicode integrity

Private capture requires RFC 3629 UTF-8 scalar strings in decoded JSON keys and values as well as wire text. Native
parsing, installed orders and kernel controls remain unchanged. If native bytes, a persistent private note, or received
metadata cannot be serialized safely, capture preserves the entire original evidence JSON bytes in
`invalid_native_evidence_json_b64`, records a visible capture error, clears attempts/selection/action, and rejects the
training target. Actual scripted fallback keeps its fallback status. An affected episode is marked failed for capture;
unsafe terminal outcomes are likewise preserved as base64. No replacement text becomes a label. Missing optional
provider model/stop/usage metadata remains missing; configured route identity is retained, and negative token usage is
not admitted. An invalid runtime identity disables optional capture with a diagnostic while native play continues.

The retained system regression uses the real central decision engine, loopback HTTP, native parser, 120 kernel ticks,
and private writer. It covers valid accented text/surrogate pairs, decoded bad keys, lone surrogates, invalid UTF-8,
persistent next-request bytes, response headers/model metadata and absent optional metadata. It plays two rounds of the
ordinary 12-round open-floor configuration with the unchanged 25-second batch-start floor, then explicitly settles
through the native deadline path. It is a partial protocol proof, never a completed episode or teacher receipt.

```sh
python3 tools/ci/native_unicode_system.py --nim /path/to/nim-2.2.4/bin/nim \
  --nimcache /tmp/unique-gift-unicode-cache --output /tmp/unique-gift-unicode-proof
```

The command reads the checkout's pinned `nim.cfg` paths, uses an explicit credential-free subprocess environment, and
bounds compilation to 240 seconds and execution to 60 seconds/8 MiB with a 2 GiB disk floor. All requests stay on
loopback; synthetic fixture usage and UUID call headers are not authenticated provider receipts.

Capture also checks strict JSON grammar independently of the tolerant native parser. It selects exactly the first
balanced object span that the native extractor can parse, including the extractor's existing fallback, then checks that
same span for duplicate keys, comments, JSON whitespace/number spelling, finite numbers, scalar strings and a depth
limit of 32. A strict rejection never skips to a later valid object. Supported fences/prose and omitted optional
defaults remain eligible; native parsing, retry behavior, installed actions and clocks are unchanged. Grammar exclusions
retain the entire original completion and applied action with no selected training target. Run the same partial system
proof with `--grammar` for duplicate/conflicting keys, comments, numeric spelling, trailing commas, depth, whitespace
and first-object selection controls. Responses the native parser already rejects still take its ordinary retry path.

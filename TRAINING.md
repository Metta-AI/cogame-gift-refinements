# Prompt diversity and private candidates

Gift Refinements supports five training introductions (`canonical`, `plain`, `numbered`, `questions`, `reordered`) and
two evaluation-only introductions (`heldout-briefing`, `heldout-reference`). Canonical wording is byte-for-byte
unchanged. Full rules, strategic hints, observations, and action syntax are shared across wordings.

Set `promptVariant` in game configuration. `mixed` requires a nonnegative `promptSeed` and selects one training wording
for the entire episode. Selection does not alter simulation randomness or published budgets. Private evidence records
bank `gift-refinements-rules-v1`, selection, seed, and exact system/user hashes.

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

## Source candidates

Commit qualified source before exporting complete games:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/gift-export tools/export_posttrain.nim
/tmp/gift-export /tmp/gift-candidates 10 1 refinery mixed 4
```

The exporter preserves the reciprocator/hoarder roster, simultaneous standing orders, and native kernel. It writes
private `trajectories.jsonl`, `execution.jsonl`, and a manifest. Evidence includes exact prompts, hashes, proposals,
installed orders, kernel actions, frames, events, outcomes, and source revision. Output paths must be new; files are
mode `0600`.

These are candidates requiring independent review. No train/validation labels are produced automatically. Held-out
wording is rejected for candidate export. Preserve physical scenario families during review and downstream splitting.

## Native request and execution evidence

Set `GIFT_REFINEMENTS_SOURCE_REVISION` to the qualified source revision. Set `GIFT_REFINEMENTS_ATTEMPT_TRACE_DIR` and
`GIFT_REFINEMENTS_HOST_TRACE_PATH` on the game host to private output locations. Capture is opt-in; files use mode
`0600` and must not already exist. Actual request bodies, model identity, exact prompts/hashes, raw responses, parsing
outcomes, and retries are recorded. Credentials and request headers are excluded.

Host evidence retains observations before decisions, selected attempt IDs, external proposals, installed orders, kernel
actions, frame/event sequences, settlement events, and final outcomes. Host reference prompts are never presented as
external-player inference. Absent provider call IDs and behavior log probabilities remain null. Public replay and other
players' observations do not receive operator prompts or template metadata.

## Validation and evaluation

`tools/test_prompt_games.py BRIDGE [ORIGINAL_BRIDGE]` plays complete wording panels, checks original numeric behavior
and exact canonical prompts, and verifies private notes, spectator-only speech, normalization, and inert seed behavior.
`tools/test_export_posttrain.py EXPORTER [ORIGINAL_EXPORTER]` compares complete candidate games with original canonical
exports and checks physical frames across seed replicas.

Compare base, canonical-trained, and mixed-trained policies on frozen scenario/wording panels with the same seat
assignments and opponents. Report invalid actions, fallbacks, and incomplete games alongside scores. The four published
scenarios limit what held-out evaluation can establish. Deterministic checks do not prove improved learning or
resistance to training collapse.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest and variant to Metta's `recipes.external.coworld.train` (native
PufferLib) or `recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/gift-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/gift-train-bridge
```

All four certified variants expose 764 numeric observation values and four factorized action heads: job (4 choices),
target (5), gift (11), and consume (3). The target head names another seat, so every sampled combination is a legal
standing order. A target selected for an order with no gift and no meet job is discarded because it has no gameplay
effect. Numeric observations come from the same per-seat view as the hosted prompt: they include own inventory, public
board positions and scores, gifts, bank events, and own history. Other seats' inventories and private orders remain
hidden. Even seats use the published reciprocator teacher; odd seats use the hoarder. Decisions stay frozen until all
six seats submit their round orders. The numeric policy sends no spectator text or private notes; the post-training
exporter retains them.

`tools/test_native_prompts.py GAME PLAYER OUTPUT` runs all four canonical variants and seven additional wording cases
with six real native players and a reserved closed inference endpoint. Each published game keeps 12 rounds and 720
ticks. It verifies 144 actual failed requests, 72 installed fallbacks, exact prompt hashes, and replay joins. `--smoke`
runs two full canonical variants. These checks exercise transport failures; they do not measure provider inference
quality.

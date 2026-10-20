# Prompt diversity and training

Bank `gift-refinements-rules-v2` provides five training wordings and two
held-out evaluation wordings. The renderer varies consuming, beam geometry,
lowest-level-first gifting, the worked ladder, and the choice to stop cooperating.
Published board constants, action grammar, private views, and canonical bytes
remain unchanged. Native decisions, language collection, and teacher exports
share the renderer.

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, `reordered`,
or `mixed`. Mixed requires a nonnegative `promptSeed`; modulo five selects a
wording independently of simulator randomness, fixed for each episode.
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

The exporter retains `train.jsonl`, `validation.jsonl`, and `manifest.json`.
All replicas of one physical configuration belong to the specified split.
The optional final split defaults to `train`; the other dataset file is empty.
Choose different physical configurations for validation, as shown above.
Seed labels cannot create held-out scenarios. Mixed selection cycles across
five wordings, recording message hashes, each run's selection, and scenario family.
Episode IDs include the selected wording and prompt seed; scenario-family IDs do not.
The original reciprocator/hoarder roster and simultaneous standing orders remain.

## Validation and experiments

`tools/test_prompt_games.py BRIDGE` runs complete wording, normalization,
privacy, numeric, and inert-seed games across four physical variants.
`tools/test_export_posttrain.py EXPORTER` runs 40 complete mixed exports,
keeping three scenario families in training and one in validation.
Existing numeric and hosted-request checks exercise the real bridge and renderer.

For learning experiments, compare canonical and mixed training with matched
physical configurations, policies, seats, and inference settings. Report score,
invalid-order rate, fallback rate, requests, and completion for familiar and
held-out wording. Four published physical scenarios are limited coverage;
local checks do not establish learned robustness.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.

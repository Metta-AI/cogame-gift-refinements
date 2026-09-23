# Metta post-training data

The native simulator and published `reciprocator` and `hoarder` policies
export supervised examples for all four certified Gift Refinements variants:

```sh
nimby sync nimby.lock
for variant in refinery scarce long-beam open-floor; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/gift-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
games. At each simultaneous round, it records every seat's hosted system and
user prompts and a scripted order accepted by the game's reply parser.
Parsed orders drive the native kernel for every tick. Even seats use
`reciprocator`; odd seats use `hoarder`. Whole games stay in one split. The
output manifest records source revision, variant, scores, rounds, and row
counts. Existing output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/gift-refinery \
  --output /tmp/gift-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games per variant yielded 576 training and 144 validation
examples each. All 2,880 examples fit the Qwen2.5-0.5B-Instruct tokenizer in
4,096 tokens; the maximum was 1,887. These examples distill scripted
teachers; they do not establish stronger league play.
One CPU optimizer step per variant with a local tiny model included every
example and reduced heldout loss, verifying the Metta post-training path.

#!/usr/bin/env bash
set -euo pipefail

seed=${1:?usage: local_episode.sh seed [opponents] [variant]}
opponents=${2:-reciprocator}
variant=${3:-refinery}
port=${PORT:-18094}
case "$variant" in
  refinery|scarce|long-beam|open-floor) ;;
  *) echo "unknown variant: $variant" >&2; exit 2 ;;
esac
case "$opponents" in
  reciprocator|hoarder) ;;
  *) echo "opponents must be reciprocator or hoarder" >&2; exit 2 ;;
esac

mkdir -p tmp/bin
episode_dir=$(mktemp -d tmp/episode.XXXXXX)
episode_dir="$PWD/$episode_dir"
python3 - "$seed" "$variant" "$episode_dir/config.json" <<'PY'
import json
import sys
from pathlib import Path
seed, variant, path = sys.argv[1:]
config = {
    'num_agents': 6, 'seed': int(seed), 'rounds': 12,
    'variant': variant,
    'minTurnSeconds': 0, 'playerConnectTimeoutSeconds': 10,
    'shutdownGraceSeconds': 1,
    'tokens': [f't{i}' for i in range(6)],
    'players': [{'name': f'P{i}'} for i in range(6)],
}
if variant == 'scarce':
    config['spawnTicks'] = 75
elif variant == 'long-beam':
    config['beamRange'] = 8
elif variant == 'open-floor':
    config['pillars'] = 0
Path(path).write_text(json.dumps(config))
PY
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  nim c --hints:off -o:tmp/bin/gift-refinements src/gift_refinements.nim
  nim c --hints:off -o:tmp/bin/gift-refinements-player src/gift_refinements_player.nim
fi
tmp/bin/gift-refinements --host:127.0.0.1 --port:"$port" \
  --config-path:"$episode_dir/config.json" \
  --results-uri:"file://$episode_dir/results.json" \
  --save-replay-uri:"file://$episode_dir/episode.replay" \
  > "$episode_dir/game.log" 2>&1 &
game=$!
trap 'kill "$game" 2>/dev/null || true' EXIT
sleep 0.5
for slot in {0..5}; do
  baseline=$opponents
  if [ "$slot" = 0 ]; then
    baseline=reciprocator
  fi
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
    PLAYER_SCRIPTED="$baseline" tmp/bin/gift-refinements-player \
    > "$episode_dir/player$slot.log" 2>&1 &
done
wait "$game"
python3 - "$episode_dir" <<'PY'
import json
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
results = json.loads((path / 'results.json').read_text())
replay = json.loads((path / 'episode.replay').read_text())
log = (path / 'game.log').read_text()
print(json.dumps({
    'artifacts': str(path), 'score': results['scores'][0],
    'gifts_sent': results['gifts_sent'][0],
    'tokens_given': results['tokens_given'][0],
    'fallbacks': int(re.search(r'fallbacks=(\d+)', log).group(1)),
    'seat0_external_orders': sum(event['source'] == 'external'
        for event in replay['events'] if event.get('k') == 'order'
        and event['seat'] == 0),
}))
PY

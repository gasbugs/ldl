#!/usr/bin/env bash
# Publisher-only offline regression; learner files and running services are untouched.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
FIXTURES="$ROOT/tutorials/nemo-evaluation"
IMAGE=${NEMO_EVALUATION_IMAGE:-localhost/nemo-evaluation:0.24.1}
WORK=$(mktemp -d /tmp/ldl-dialog-regression.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
for variant in baseline tuned; do
  mkdir -p "$WORK/dialog-$variant"
  cp "$FIXTURES/config/"* "$WORK/dialog-$variant/"
  cp "$FIXTURES/$variant.co" "$WORK/dialog-$variant/flows.co"
done
for run in baseline tuned tuned-repeat-2 tuned-repeat-3; do
  config=tuned
  if [ "$run" = baseline ]; then config=baseline; fi
  mkdir -p "$WORK/$run"
  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    -e BEDROCK_GATEWAY_TOKEN=offline-evaluation-placeholder \
    -v "$WORK:/work" \
    --entrypoint nemoguardrails "$IMAGE" \
    eval rail topical --config="/work/dialog-$config" \
    --max-tests-intent=1 --test-percentage=0.5 --random-seed=7 \
    --output-dir="/work/$run" --verbose > "$WORK/$run.log" 2>&1
done
python3 "$FIXTURES/check_results.py" "$WORK"

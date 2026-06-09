#!/usr/bin/env bash
set -euo pipefail

SCENE="${1:?Brush COLMAP scene dir, e.g. /path/to/out/brush_dataset}"
OUTPUT="${2:-$(dirname "$SCENE")/brush_smoketest}"
REQUESTED_STEPS="${3:-}"

BRUSH="${BRUSH:-/Applications/brush-app-aarch64-apple-darwin/brush_app}"
STEPS="${REQUESTED_STEPS:-${STEPS:-30000}}"
GROWTH_STOP="${GROWTH_STOP:-12000}"
REFINE_EVERY="${REFINE_EVERY:-500}"
MAX_SPLATS="${MAX_SPLATS:-4000000}"
MAX_RESOLUTION="${MAX_RESOLUTION:-1600}"

mkdir -p "$OUTPUT"

"$BRUSH" "$SCENE" \
  --total-steps "$STEPS" \
  --growth-stop-iter "$GROWTH_STOP" \
  --refine-every "$REFINE_EVERY" \
  --max-splats "$MAX_SPLATS" \
  --sh-degree 3 \
  --ssim-weight 0.2 \
  --max-resolution "$MAX_RESOLUTION" \
  --export-every 5000 \
  --export-path "$OUTPUT" \
  --export-name smoke_{iter}.ply

echo
echo "Brush smoke-test output: $OUTPUT"

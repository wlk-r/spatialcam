#!/usr/bin/env bash
set -euo pipefail

SESSION="${1:?session dir}"
OUT="${2:?out dir}"
shift 2

MS="${METASHAPE:-/Applications/MetashapePro.app/Contents/MacOS/MetashapePro}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$MS" -r "$SCRIPT_DIR/metashape_capture.py" "$SESSION" "$OUT" "$@"

echo
echo "Metashape output: $OUT"
echo "Brush dataset:    $OUT/brush_dataset"

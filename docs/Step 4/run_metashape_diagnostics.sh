#!/usr/bin/env bash
set -euo pipefail

PROJECT="${1:?project.psx}"
shift || true

MS="${METASHAPE:-/Applications/MetashapePro.app/Contents/MacOS/MetashapePro}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$MS" -r "$SCRIPT_DIR/metashape_diagnostics.py" "$PROJECT" "$@"

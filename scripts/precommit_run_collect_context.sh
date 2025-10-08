#!/usr/bin/env bash
# Wrapper for pre-commit to run scripts/collect_context.sh if present
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/collect_context.sh"

if [ ! -x "$SCRIPT" ]; then
  # Script not present or not executable; nothing to do
  exit 0
fi

# Ensure the safe cache dir exists (script will use its own default unless you change it)
mkdir -p -- "$REPO_ROOT/.cache/context"

# Call the collect script with no arguments so it uses its built-in default OUT_DIR
"$SCRIPT"

exit 0

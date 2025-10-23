#!/usr/bin/env bash
set -e

HOST="${DOC_HOST:-127.0.0.1}"
PORT="${DOC_PORT:-8000}"
SITE_PATH="${DOC_SITE_PATH:-/haven/}"

# Kill any existing mkdocs server
pkill -f "mkdocs serve" || true

# Choose mkdocs binary
if [ -x ./env/bin/mkdocs ]; then
  CMD="./env/bin/mkdocs"
elif command -v mkdocs >/dev/null 2>&1; then
  CMD="mkdocs"
else
  echo "mkdocs not found. Run 'make local_setup' then install docs requirements:"
  echo "  ./env/bin/pip install -r requirements-docs.txt"
  exit 1
fi

# Start server and optionally open browser
"${CMD}" serve --dev-addr="${HOST}:${PORT}" &
PID=$!

sleep 1

if [ "${OPEN_BROWSER:-}" != "false" ]; then
  open "http://${HOST}:${PORT}${SITE_PATH}" 2>/dev/null || true
fi

wait $PID

#!/usr/bin/env bash
# Container entrypoint: runs the Discord Gateway bot (auto-restarting if
# it ever exits, e.g. on reconnect) in the background, then execs socat
# as the foreground HTTP server.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${DISCORD_BOT_TOKEN:?Set DISCORD_BOT_TOKEN}"
: "${DISCORD_CHANNEL_ID:?Set DISCORD_CHANNEL_ID}"
: "${PORT:=3000}"

(
  while true; do
    "$SCRIPT_DIR/bin/bot.sh"
    echo "run.sh: bot exited, restarting in 3s..." >&2
    sleep 3
  done
) &

echo "run.sh: web server listening on port $PORT"
exec socat TCP-LISTEN:"$PORT",fork,reuseaddr EXEC:"$SCRIPT_DIR/bin/handle_request.sh"

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
  backoff=3
  while true; do
    start_ts=$(date +%s)
    "$SCRIPT_DIR/bin/bot.sh"
    elapsed=$(( $(date +%s) - start_ts ))
    # A run that lasted a while was working -- reset the backoff. One
    # that died fast grows it instead, so a persistent failure backs off
    # rather than hammering Discord's Gateway every few seconds.
    if [ "$elapsed" -ge 30 ]; then
      backoff=3
    else
      backoff=$(( backoff < 60 ? backoff * 2 : 60 ))
    fi
    echo "run.sh: bot exited after ${elapsed}s, restarting in ${backoff}s..." >&2
    sleep "$backoff"
  done
) &

"$SCRIPT_DIR/bin/rotate_logs.sh" &

echo "run.sh: web server listening on port $PORT"
exec socat TCP-LISTEN:"$PORT",fork,reuseaddr EXEC:"$SCRIPT_DIR/bin/handle_request.sh"

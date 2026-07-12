#!/usr/bin/env bash
# Handles a single HTTP connection. Invoked per-connection by
# `socat ... fork EXEC:handle_request.sh`, with stdin/stdout wired to the
# client socket. Only GET is supported, and only a fixed set of routes --
# there is no generic path->filesystem mapping, so there's no path
# traversal surface to worry about.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

REPLAY_LINES=50       # messages replayed to a client on every /events (re)connect
IDLE_TIMEOUT_SECS=15  # how often a heartbeat comment is sent on an otherwise-quiet stream

# Make sure any child process (the `tail -F` behind /events) dies with us.
trap 'pkill -P $$ 2>/dev/null' EXIT

read -r request_line || exit 0
request_line="${request_line%$'\r'}"
method="${request_line%% *}"
rest="${request_line#* }"
req_path="${rest%% *}"

# Drain headers; we don't need them, but must consume up to the blank line.
while IFS= read -r header; do
  header="${header%$'\r'}"
  [ -z "$header" ] && break
done

send_status() { printf 'HTTP/1.1 %s\r\n' "$1"; }

send_response_headers() {
  send_status "$1"
  printf 'Content-Type: %s\r\n' "$2"
  printf 'Content-Length: %s\r\n' "$3"
  printf 'Connection: close\r\n\r\n'
}

serve_file() {
  local file="$1" ctype="$2" length
  length=$(wc -c < "$file")
  send_response_headers "200 OK" "$ctype" "$length"
  cat "$file"
}

serve_text() {
  local status="$1" body="$2"
  send_response_headers "$status" "text/plain" "${#body}"
  printf '%s' "$body"
}

serve_events() {
  send_status "200 OK"
  printf 'Content-Type: text/event-stream\r\n'
  printf 'Cache-Control: no-cache\r\n'
  printf 'Connection: keep-alive\r\n'
  printf 'X-Accel-Buffering: no\r\n'
  printf '\r\n'

  # Replay the last $REPLAY_LINES messages, then follow the file as the
  # bot appends to it. `read -t` doubles as a heartbeat every
  # $IDLE_TIMEOUT_SECS so intermediary proxies don't time out an idle
  # connection.
  while true; do
    IFS= read -r -t "$IDLE_TIMEOUT_SECS" line
    status=$?
    if [ "$status" -eq 0 ]; then
      printf 'data: %s\n\n' "$line"
    elif [ "$status" -gt 128 ]; then
      printf ': keepalive\n\n'
    else
      break
    fi
  done < <(tail -n "$REPLAY_LINES" -F "$MESSAGES_FILE" 2>/dev/null)
}

if [ "$method" != "GET" ]; then
  serve_text "405 Method Not Allowed" "Method Not Allowed"
  exit 0
fi

case "$req_path" in
  "/"|"/index.html")
    serve_file "$PUBLIC_DIR/index.html" "text/html; charset=utf-8"
    ;;
  "/client.js")
    serve_file "$PUBLIC_DIR/client.js" "application/javascript; charset=utf-8"
    ;;
  "/style.css")
    serve_file "$PUBLIC_DIR/style.css" "text/css; charset=utf-8"
    ;;
  "/health")
    serve_text "200 OK" "ok"
    ;;
  "/events")
    serve_events
    ;;
  *)
    serve_text "404 Not Found" "Not Found"
    ;;
esac

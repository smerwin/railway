#!/usr/bin/env bash
# Connects to the real Discord Gateway (a WebSocket) via websocat, instead
# of REST-polling, and streams MESSAGE_CREATE events to $MESSAGES_FILE as
# they happen. On start (and after every reconnect) it first does one REST
# catch-up fetch for anything posted since the last message we saw, so a
# dropped connection doesn't silently lose messages. See README for the
# coproc/heartbeat design and why bash needs websocat to speak WebSocket
# framing at all.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

: "${DISCORD_BOT_TOKEN:?Set DISCORD_BOT_TOKEN}"
: "${DISCORD_CHANNEL_ID:?Set DISCORD_CHANNEL_ID}"

# Strip stray whitespace (e.g. a pasted trailing newline): REST tolerates
# it in headers, but the Gateway Identify compares it byte-for-byte as a
# raw JSON string -- see README postmortem.
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN#"${DISCORD_BOT_TOKEN%%[![:space:]]*}"}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN%"${DISCORD_BOT_TOKEN##*[![:space:]]}"}"

API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"
GATEWAY_URL="wss://gateway.discord.gg/?v=10&encoding=json"
# GUILDS (1<<0) + GUILD_MESSAGES (1<<9) + MESSAGE_CONTENT (1<<15)
INTENTS=33281
SEQ_FILE="$DATA_DIR/gateway_seq"

# Tunables gathered here so a reader sees every timeout/limit in one
# place instead of finding them scattered as bare numbers.
REST_TIMEOUT_SECS=10       # curl --max-time for the REST catch-up call
CATCHUP_BACKFILL_LIMIT=50  # messages to fetch on the very first run (after=0)
CATCHUP_GAP_LIMIT=100      # messages to fetch when bridging a reconnect gap
HELLO_TIMEOUT_SECS=10      # max wait for Discord's Hello before giving up

touch "$MESSAGES_FILE"
[ -f "$STATE_FILE" ] || echo "0" > "$STATE_FILE"

# Maps raw Discord message object(s) to feed-shaped JSON; see the file
# itself for its --arg/--mode contract.
TO_FEED_MESSAGE_JQ="$LIB_DIR/to_feed_message.jq"

# Shorthand for the "pipe one JSON value through a jq filter" pattern that
# shows up throughout this file (Gateway frames, REST responses, etc).
jval() {
  echo "$1" | jq -r "$2"
}

# Fetches anything posted after the last message ID we've persisted.
# Doubles as the initial history backfill on first-ever start (after=0)
# and as the gap-filler after every Gateway reconnect.
catch_up() {
  local after url response count
  after="$(cat "$STATE_FILE")"
  if [ "$after" = "0" ]; then
    url="${API}?limit=${CATCHUP_BACKFILL_LIMIT}"
  else
    url="${API}?after=${after}&limit=${CATCHUP_GAP_LIMIT}"
  fi

  # Any failure here just means catch_up contributes nothing this cycle;
  # the Gateway connection (or the next reconnect's catch_up) carries on.
  response="$(curl -sS --http1.1 --max-time "$REST_TIMEOUT_SECS" -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" "$url")"
  [ -z "$response" ] && return 0

  if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "bot: catch-up REST error: $(jval "$response" '.message // "unknown"' 2>/dev/null)" >&2
    return 0
  fi

  count="$(echo "$response" | jq 'length')"
  if [ "$count" != "0" ]; then
    echo "$response" | jq -c -f "$TO_FEED_MESSAGE_JQ" --arg kind create --arg mode list >> "$MESSAGES_FILE"
    after="$(jval "$response" '.[0].id')"
    echo "$after" > "$STATE_FILE"
  fi
}

echo "bot: catch-up on channel ${DISCORD_CHANNEL_ID}" >&2
catch_up

echo "bot: connecting to Discord Gateway" >&2
echo "null" > "$SEQ_FILE"

coproc GW { exec websocat -v -B 1000000 "$GATEWAY_URL"; }

cleanup() {
  [ -n "${HEARTBEAT_PID:-}" ] && kill "$HEARTBEAT_PID" 2>/dev/null
  # -9: observed websocat taking a long time to exit on its own after
  # Discord closes the connection without a Hello -- no reason to wait
  # on a graceful shutdown from a connection we've already given up on.
  [ -n "${GW_PID:-}" ] && kill -9 "$GW_PID" 2>/dev/null
}
trap cleanup EXIT

# Hello should be near-instant, unlike the main dispatch loop below where
# quiet gaps are normal -- so a short timeout here is safe. Enforced
# ourselves rather than waiting on websocat's own EOF, which has been
# observed taking upwards of a minute after a close frame with no Hello.
if ! IFS= read -r -t "$HELLO_TIMEOUT_SECS" -u "${GW[0]}" hello_line; then
  echo "bot: no Hello received from Gateway within ${HELLO_TIMEOUT_SECS}s, exiting" >&2
  exit 1
fi
interval_ms="$(jval "$hello_line" '.d.heartbeat_interval')"
interval_sec="$(awk -v ms="$interval_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"

identify="$(jq -nc --arg token "$DISCORD_BOT_TOKEN" --argjson intents "$INTENTS" '
  {op: 2, d: {token: $token, intents: $intents, properties: {os: "linux", browser: "bash-discord-bot", device: "bash-discord-bot"}}}
')"
printf '%s\n' "$identify" >&"${GW[1]}"

# Bash closes a coprocess's fds in forked children, so ${GW[1]} is
# unusable from a background job -- duplicate it to a fixed fd first.
exec 70>&"${GW[1]}"

# stderr suppressed: a failed write just means the coproc pipe is gone
# (Discord closed the connection), and both callers below treat that as
# "stop quietly," not an error.
send_heartbeat() {
  local seq
  seq="$(cat "$SEQ_FILE")"
  printf '{"op":1,"d":%s}\n' "$seq" >&70
} 2>/dev/null

# Heartbeat loop: runs as a background job so it can fire on its own
# timer without blocking the main dispatch loop below. The sequence
# number is read from a file rather than a shared variable, since this
# is a separate process from that loop.
(
  while true; do
    sleep "$interval_sec"
    send_heartbeat || exit 0
  done
) &
HEARTBEAT_PID=$!

# No per-channel Gateway subscription exists, so every handler below
# filters by channel itself -- see README "tricky parts".
dispatch_channel_id() {
  jval "$1" '.d.channel_id'
}

# Returns 1 (and does nothing else) when the dispatch is for a channel
# other than the one we're streaming. Callers use it as an early return:
#   is_our_channel "$line" || return 0
is_our_channel() {
  [ "$(dispatch_channel_id "$1")" = "$DISCORD_CHANNEL_ID" ]
}

handle_message_upsert() {
  local line="$1" t="$2"
  is_our_channel "$line" || return 0

  local msg_id is_bot has_content kind
  msg_id="$(jval "$line" '.d.id')"
  is_bot="$(jval "$line" '.d.author.bot // false')"
  # MESSAGE_UPDATE can arrive as a partial payload (e.g. Discord
  # generating a link-preview embed touches no text) -- .content
  # missing/null means there's no text edit to show, so skip it.
  has_content="$(jval "$line" '.d.content != null')"

  if [ "$is_bot" != "true" ] && [ "$has_content" = "true" ]; then
    kind="create"
    [ "$t" = "MESSAGE_UPDATE" ] && kind="update"
    echo "$line" | jq -c -f "$TO_FEED_MESSAGE_JQ" --arg kind "$kind" --arg mode frame >> "$MESSAGES_FILE"
  fi

  # Edits reuse the original message's ID, which is always <= the newest
  # ID we've already recorded -- only creates should ever advance the
  # REST catch-up cursor.
  [ "$t" = "MESSAGE_CREATE" ] && echo "$msg_id" > "$STATE_FILE"
}

# MESSAGE_DELETE's payload is just {id, channel_id[, guild_id]} -- no
# author, no content -- so it can't share handle_message_upsert at all;
# there's nothing to filter by author/content, only by channel.
handle_message_delete() {
  local line="$1"
  is_our_channel "$line" || return 0

  echo "$line" | jq -c '{kind: "delete", id: .d.id}' >> "$MESSAGES_FILE"
}

# Handles a single op:0 (Dispatch) frame, routing by its .t event type.
handle_dispatch() {
  local line="$1" t
  t="$(jval "$line" '.t')"
  case "$t" in
    MESSAGE_CREATE | MESSAGE_UPDATE) handle_message_upsert "$line" "$t" ;;
    MESSAGE_DELETE) handle_message_delete "$line" ;;
    READY) echo "bot: session ready" >&2 ;;
  esac
}

# Main dispatch loop. No session Resume is implemented: on Reconnect (op
# 7), Invalid Session (op 9), or the socket just closing, this loop exits
# and run.sh's outer supervisor restarts the whole script -- which reruns
# catch_up to bridge the gap, then re-Identifies for a fresh session.
while IFS= read -r -u "${GW[0]}" line; do
  op="$(jval "$line" '.op')"
  seq="$(jval "$line" '.s // empty')"
  [ -n "$seq" ] && echo "$seq" > "$SEQ_FILE"

  case "$op" in
    0) handle_dispatch "$line" ;;
    1) send_heartbeat ;; # Discord can ask for an out-of-band heartbeat
    7)
      echo "bot: server requested reconnect" >&2
      break
      ;;
    9)
      echo "bot: invalid session" >&2
      break
      ;;
    11) : ;; # heartbeat ACK, nothing to do
  esac
done

echo "bot: Gateway connection closed" >&2

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

# Defensive: strip any leading/trailing whitespace picked up from however
# the variable was set (e.g. a trailing newline pasted into a dashboard).
# REST calls embed the token in an HTTP header, which servers commonly
# trim -- but the Gateway Identify embeds it as a raw JSON string value,
# compared byte-for-byte, where stray whitespace would silently break
# authentication while REST calls using the same variable kept working.
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN#"${DISCORD_BOT_TOKEN%%[![:space:]]*}"}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN%"${DISCORD_BOT_TOKEN##*[![:space:]]}"}"

API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"
GATEWAY_URL="wss://gateway.discord.gg/?v=10&encoding=json"
# GUILDS (1<<0) + GUILD_MESSAGES (1<<9) + MESSAGE_CONTENT (1<<15)
INTENTS=33281
SEQ_FILE="$DATA_DIR/gateway_seq"

touch "$MESSAGES_FILE"
[ -f "$STATE_FILE" ] || echo "0" > "$STATE_FILE"

# jq function mapping one raw Discord message object to the shape the
# front-end expects. Shared (as inlined text) between the REST catch-up
# path and the live Gateway dispatch path below. Takes the record "kind"
# (create/update) as a parameter so the front-end can tell an edit from a
# brand-new message without a separate schema.
read -r -d '' TO_FEED_MESSAGE_DEF <<'JQ'
def to_feed_message(kind):
  {
    kind: kind,
    id: .id,
    authorId: .author.id,
    authorName: (.member.nick // .author.global_name // .author.username // "Unknown"),
    authorAvatarURL: (
      if .author.avatar then
        "https://cdn.discordapp.com/avatars/\(.author.id)/\(.author.avatar).png?size=64"
      else
        "https://cdn.discordapp.com/embed/avatars/0.png"
      end
    ),
    content: .content,
    createdAt: .timestamp,
    editedAt: (.edited_timestamp // null),
    attachments: [.attachments[] | {url: .url, name: .filename, contentType: .content_type}]
  };
JQ

# Fetches anything posted after the last message ID we've persisted.
# Doubles as the initial history backfill on first-ever start (after=0)
# and as the gap-filler after every Gateway reconnect.
catch_up() {
  local after url response count
  after="$(cat "$STATE_FILE")"
  if [ "$after" = "0" ]; then
    url="${API}?limit=50"
  else
    url="${API}?after=${after}&limit=100"
  fi

  response="$(curl -sS --http1.1 --max-time 10 -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" "$url")"
  [ -z "$response" ] && return 0

  if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "bot: catch-up REST error: $(echo "$response" | jq -r '.message // "unknown"' 2>/dev/null)" >&2
    return 0
  fi

  count="$(echo "$response" | jq 'length')"
  if [ "$count" != "0" ]; then
    echo "$response" | jq -c "
      ${TO_FEED_MESSAGE_DEF}
      reverse | .[] | select(.author.bot != true) | to_feed_message(\"create\")
    " >> "$MESSAGES_FILE"
    after="$(echo "$response" | jq -r '.[0].id')"
    echo "$after" > "$STATE_FILE"
  fi
}

echo "bot: catch-up on channel ${DISCORD_CHANNEL_ID}" >&2
catch_up

# Diagnostic only: a plain HTTPS request to the same host websocat is
# about to connect to, logged so a persistent Gateway connection failure
# (as opposed to an occasional blip) can be told apart from "this host is
# unreachable from here at all" vs. "something specific to the WebSocket
# upgrade/TLS handshake websocat performs." curl reaching Discord's REST
# API doesn't prove this host is reachable too -- it's a different
# hostname/edge.
gw_probe_code="$(curl -sS --http1.1 --max-time 5 -o /dev/null -w '%{http_code}' "https://gateway.discord.gg/?v=10&encoding=json" 2>&1)"
echo "bot: pre-flight HTTPS check to gateway.discord.gg: ${gw_probe_code}" >&2

# Diagnostic: Discord's own accounting of this bot token's remaining
# Identify budget (documented as 1000/day, resetting on a rolling
# window). If the connection is dying right after Identify with no
# further response -- no Ready, no Invalid Session, nothing -- and
# "remaining" here is 0 or very low, that's a directly-checkable
# explanation, rather than continuing to guess: the earlier fixed
# 3-second retry loop (before backoff was added) may have burned through
# this token's daily Identify budget by reconnecting that aggressively
# for an extended period.
session_limit_info="$(curl -sS --http1.1 --max-time 10 -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" "https://discord.com/api/v10/gateway/bot" 2>&1)"
echo "bot: session_start_limit: $(echo "$session_limit_info" | jq -c '.session_start_limit // .' 2>/dev/null)" >&2

echo "bot: connecting to Discord Gateway" >&2
echo "null" > "$SEQ_FILE"

# A custom User-Agent header (-H) was tried here as a hypothesis-driven
# fix for the Gateway closing connections before Hello, but there's no
# working websocat binary in this environment to verify its -H argument
# parsing against (it briefly caused "No URL specified" -- the flag ate
# $GATEWAY_URL). Dropped rather than guess a second time at syntax that
# can't be tested locally; the User-Agent theory was speculative to
# begin with, unlike the backoff fix in run.sh, which is grounded in the
# actual observed close-before-Hello pattern.
coproc GW { exec websocat -v -B 1000000 "$GATEWAY_URL"; }

cleanup() {
  [ -n "${HEARTBEAT_PID:-}" ] && kill "$HEARTBEAT_PID" 2>/dev/null
  # -9: observed websocat taking a long time to exit on its own after
  # Discord closes the connection without a Hello -- no reason to wait
  # on a graceful shutdown from a connection we've already given up on.
  [ -n "${GW_PID:-}" ] && kill -9 "$GW_PID" 2>/dev/null
}
trap cleanup EXIT

# Waiting for Hello should be near-instant under normal operation --
# unlike the main dispatch loop below, where long gaps between reads are
# normal on a quiet channel, so a timeout here can't false-positive on
# "healthy but idle." Enforced with our own timeout (rather than just
# waiting for websocat's stdout to hit EOF) because websocat has been
# observed taking upwards of a minute to actually close its pipe after
# Discord sends a WebSocket close frame with no Hello -- trusting its
# own shutdown timing turned "reconnect every few seconds" into
# "reconnect every couple of minutes."
if ! IFS= read -r -t 10 -u "${GW[0]}" hello_line; then
  echo "bot: no Hello received from Gateway within 10s, exiting" >&2
  exit 1
fi
interval_ms="$(echo "$hello_line" | jq -r '.d.heartbeat_interval')"
interval_sec="$(awk "BEGIN { printf \"%.3f\", ${interval_ms}/1000 }")"
echo "bot: got Hello, heartbeat_interval=${interval_ms}ms (${interval_sec}s)" >&2

identify="$(jq -nc --arg token "$DISCORD_BOT_TOKEN" --argjson intents "$INTENTS" '
  {op: 2, d: {token: $token, intents: $intents, properties: {os: "linux", browser: "bash-discord-bot", device: "bash-discord-bot"}}}
')"
printf '%s\n' "$identify" >&"${GW[1]}"
echo "bot: sent Identify" >&2

# Heartbeat loop: runs as a background job writing to the coproc's stdin
# on a timer. Bash closes a coprocess's file descriptors in forked child
# processes (a documented bash limitation, not something specific to
# this script), so ${GW[1]} itself is unusable from a backgrounded job --
# it has to be explicitly duplicated to a fixed fd *before* backgrounding.
# The sequence number is read from a file rather than a shared variable,
# since the heartbeat job is a separate process from the main dispatch
# loop below.
exec 70>&"${GW[1]}"
(
  while true; do
    sleep "$interval_sec"
    seq="$(cat "$SEQ_FILE")"
    if { printf '{"op":1,"d":%s}\n' "$seq" >&70; } 2>/dev/null; then
      echo "bot: sent heartbeat (seq=${seq})" >&2
    else
      echo "bot: heartbeat write failed (coproc pipe closed), stopping heartbeat loop" >&2
      exit 0
    fi
  done
) &
HEARTBEAT_PID=$!

# Main dispatch loop. No session Resume is implemented: on Reconnect (op
# 7), Invalid Session (op 9), or the socket just closing, this loop exits
# and run.sh's outer supervisor restarts the whole script -- which reruns
# catch_up to bridge the gap, then re-Identifies for a fresh session.
while IFS= read -r -u "${GW[0]}" line; do
  op="$(echo "$line" | jq -r '.op')"
  seq="$(echo "$line" | jq -r '.s // empty')"
  dispatch_t="$(echo "$line" | jq -r '.t // empty')"
  echo "bot: recv op=${op}${dispatch_t:+ t=$dispatch_t}${seq:+ seq=$seq}" >&2
  [ -n "$seq" ] && echo "$seq" > "$SEQ_FILE"

  case "$op" in
    0)
      t="$(echo "$line" | jq -r '.t')"
      if [ "$t" = "MESSAGE_CREATE" ] || [ "$t" = "MESSAGE_UPDATE" ]; then
        # Intents subscribe to every channel in every guild the bot can
        # see, not just ours -- Discord has no per-channel Gateway
        # subscription, so the channel filter has to happen here.
        channel_id="$(echo "$line" | jq -r '.d.channel_id')"
        if [ "$channel_id" = "$DISCORD_CHANNEL_ID" ]; then
          msg_id="$(echo "$line" | jq -r '.d.id')"
          is_bot="$(echo "$line" | jq -r '.d.author.bot // false')"
          # MESSAGE_UPDATE can arrive as a partial payload (e.g. Discord
          # generating a link-preview embed touches no text) -- .content
          # missing/null means there's no text edit to show, so skip it.
          has_content="$(echo "$line" | jq -r '.d.content != null')"
          if [ "$is_bot" != "true" ] && [ "$has_content" = "true" ]; then
            if [ "$t" = "MESSAGE_CREATE" ]; then
              echo "$line" | jq -c "${TO_FEED_MESSAGE_DEF} .d | to_feed_message(\"create\")" >> "$MESSAGES_FILE"
            else
              echo "$line" | jq -c "${TO_FEED_MESSAGE_DEF} .d | to_feed_message(\"update\")" >> "$MESSAGES_FILE"
            fi
          fi
          # Edits reuse the original message's ID, which is always <= the
          # newest ID we've already recorded -- only creates should ever
          # advance the REST catch-up cursor.
          [ "$t" = "MESSAGE_CREATE" ] && echo "$msg_id" > "$STATE_FILE"
        fi
      elif [ "$t" = "MESSAGE_DELETE" ]; then
        # MESSAGE_DELETE's payload is just {id, channel_id[, guild_id]}
        # -- no author, no content -- so it can't share the create/update
        # path above at all; there's nothing to filter by author/content,
        # only by channel.
        channel_id="$(echo "$line" | jq -r '.d.channel_id')"
        if [ "$channel_id" = "$DISCORD_CHANNEL_ID" ]; then
          echo "$line" | jq -c '{kind: "delete", id: .d.id}' >> "$MESSAGES_FILE"
        fi
      elif [ "$t" = "READY" ]; then
        echo "bot: session ready" >&2
      fi
      ;;
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

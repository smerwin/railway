#!/usr/bin/env bash
# Polls the Discord REST API for new messages in DISCORD_CHANNEL_ID and
# appends each one as a compact JSON line to $MESSAGES_FILE. This stands
# in for a real Gateway (WebSocket) connection, which isn't practical to
# hand-roll in bash -- see README for the trade-offs.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

: "${DISCORD_BOT_TOKEN:?Set DISCORD_BOT_TOKEN}"
: "${DISCORD_CHANNEL_ID:?Set DISCORD_CHANNEL_ID}"

API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"

touch "$MESSAGES_FILE"
[ -f "$STATE_FILE" ] || echo "0" > "$STATE_FILE"

fetch() {
  curl -sS --max-time 10 -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" "$1"
}

# Discord returns messages newest-first; this maps+reverses them into the
# shape the front-end expects and appends them in chronological order.
append_batch() {
  echo "$1" | jq -c '
    reverse
    | .[]
    | select(.author.bot != true)
    | {
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
        attachments: [.attachments[] | {url: .url, name: .filename, contentType: .content_type}]
      }
  ' >> "$MESSAGES_FILE"
}

echo "poller: streaming channel ${DISCORD_CHANNEL_ID} every ${POLL_INTERVAL_SECONDS}s" >&2

after="$(cat "$STATE_FILE")"

while true; do
  if [ "$after" = "0" ]; then
    url="${API}?limit=50"
  else
    url="${API}?after=${after}&limit=100"
  fi

  response="$(fetch "$url")"
  if [ -z "$response" ]; then
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi

  if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    err="$(echo "$response" | jq -r '.message // "unknown error"' 2>/dev/null)"
    retry="$(echo "$response" | jq -r '.retry_after // empty' 2>/dev/null)"
    echo "poller: API error: $err" >&2
    sleep "${retry:-$POLL_INTERVAL_SECONDS}"
    continue
  fi

  count="$(echo "$response" | jq 'length')"
  if [ "$count" != "0" ]; then
    append_batch "$response"
    # Response is newest-first, so element 0 is the highest snowflake ID.
    after="$(echo "$response" | jq -r '.[0].id')"
    echo "$after" > "$STATE_FILE"
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done

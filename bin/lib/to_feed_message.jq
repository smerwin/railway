# Maps raw Discord message object(s) into the shape the front-end
# expects. Shared between the REST catch-up path and the live Gateway
# dispatch path in bot.sh, both of which invoke this file with `jq -f`
# rather than splicing jq source into a bash string -- keeps bash quoting
# and jq quoting from ever having to mix in the same line.
#
# Standalone-testable, e.g.:
#   echo '{"id":"1","author":{"id":"2","username":"x"},"content":"hi","timestamp":"2026-01-01T00:00:00Z","attachments":[]}' \
#     | jq -f bin/lib/to_feed_message.jq --arg kind create --arg mode object
#
# --arg kind   "create" | "update" | "delete" -- tagged onto the output
#              so the front-end can tell an edit/delete from a new
#              message without a separate schema.
# --arg mode   "object" (default) -- input is a single raw message.
#              "frame"  -- input is a full Gateway dispatch envelope;
#                          unwrap .d before mapping.
#              "list"   -- input is a REST array of messages (newest
#                          first); reverse to chronological order and
#                          drop bot-authored ones.

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

if $mode == "list" then
  reverse | .[] | select(.author.bot != true) | to_feed_message($kind)
elif $mode == "frame" then
  .d | to_feed_message($kind)
else
  to_feed_message($kind)
end

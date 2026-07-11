#!/usr/bin/env bash
# Background loop: rotates $MESSAGES_FILE by size so it doesn't grow
# forever (see README "Log rotation" note).
#
# Uses copytruncate, not rename-and-recreate: copy the current content to
# a timestamped archive, then truncate $MESSAGES_FILE to empty *in place*
# (same inode, same path, same fd for anything already tailing it). An
# earlier version of this app trimmed the file with `tail -n N | mv`,
# which replaced it with a new, non-empty file at the same path --
# `tail -F` in handle_request.sh read that as a brand-new file and
# replayed its contents to already-connected SSE clients as if they were
# new messages (see README). Renaming the file away entirely (tried
# while building this script, before landing on copytruncate) turned out
# to share the same failure class from the other direction: when
# `tail -F` notices a watched path got replaced, it reopens and resumes
# from the new file's *current* size rather than from its start, so any
# lines written to the recreated file before tail got around to
# reopening it were silently dropped from the live stream -- verified by
# testing to lose whole batches of messages under realistic write
# timing, not just a rare edge case.
#
# Truncating in place avoids both failure modes: tail -F never reopens
# anything, so its ordinary truncation handling ("the file got smaller,
# keep reading forward from the new size") is what fires, with no
# reconnect-like reset. The one remaining trade-off -- standard for
# copytruncate, e.g. what nginx/rsyslog default to -- is a narrow race:
# a line written in the gap between the copy finishing and the truncate
# landing can be skipped by whichever SSE clients are attached at that
# instant. Verified by testing (spaced, realistic write timing) to cost
# at most the single message straddling that instant, never a batch, and
# it's still preserved in the archive on disk either way.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

file_size() {
  wc -c < "$1" 2>/dev/null
}

# Archive filenames embed a sortable UTC timestamp
# (messages.jsonl.<YYYYmmddTHHMMSSZ>), so a plain string sort is also a
# chronological sort -- oldest first.
prune_old() {
  local archives=()
  shopt -s nullglob
  archives=("$MESSAGES_FILE".*)
  shopt -u nullglob
  IFS=$'\n' archives=($(printf '%s\n' "${archives[@]}" | sort))
  unset IFS

  local count=${#archives[@]}
  if [ "$count" -gt "$LOG_ROTATE_KEEP" ]; then
    local excess=$(( count - LOG_ROTATE_KEEP ))
    for ((i = 0; i < excess; i++)); do
      rm -f -- "${archives[$i]}"
    done
  fi
}

echo "rotate_logs: watching $MESSAGES_FILE (max ${LOG_ROTATE_MAX_BYTES}B, every ${LOG_ROTATE_INTERVAL_SEC}s, keep ${LOG_ROTATE_KEEP})" >&2

while true; do
  sleep "$LOG_ROTATE_INTERVAL_SEC"

  [ -f "$MESSAGES_FILE" ] || continue
  size="$(file_size "$MESSAGES_FILE")"
  [ -n "$size" ] || continue
  [ "$size" -ge "$LOG_ROTATE_MAX_BYTES" ] || continue

  archive="$MESSAGES_FILE.$(date -u +%Y%m%dT%H%M%SZ)"
  # Copy first, fully, *then* truncate -- so the archive is always a
  # complete snapshot and $MESSAGES_FILE's inode never goes away.
  if cp "$MESSAGES_FILE" "$archive" 2>/dev/null; then
    : > "$MESSAGES_FILE"
    echo "rotate_logs: rotated $(basename "$archive") (${size}B)" >&2
    prune_old
  fi
done

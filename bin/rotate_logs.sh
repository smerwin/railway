#!/usr/bin/env bash
# Rotates $MESSAGES_FILE by size using copytruncate (copy, then truncate
# in place -- same inode) instead of rename-and-recreate, so tail -F in
# handle_request.sh never replays old content or drops new lines. See
# README's "Log rotation" section for why the alternatives were rejected.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

file_size() {
  wc -c < "$1" 2>/dev/null
}

# Filenames embed a sortable UTC timestamp, so a plain string sort is
# oldest-first.
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

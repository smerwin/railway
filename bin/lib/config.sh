# Shared paths/defaults sourced by bin/bot.sh and bin/handle_request.sh.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

PUBLIC_DIR="$APP_ROOT/public"
DATA_DIR="${DATA_DIR:-$APP_ROOT/data}"
MESSAGES_FILE="$DATA_DIR/messages.jsonl"
STATE_FILE="$DATA_DIR/last_id"

: "${PORT:=3000}"
: "${LOG_ROTATE_MAX_BYTES:=5242880}"   # 5MiB
: "${LOG_ROTATE_INTERVAL_SEC:=60}"
: "${LOG_ROTATE_KEEP:=5}"

mkdir -p "$DATA_DIR"

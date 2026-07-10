# Shared paths/defaults sourced by bin/poller.sh and bin/handle_request.sh.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

PUBLIC_DIR="$APP_ROOT/public"
DATA_DIR="${DATA_DIR:-$APP_ROOT/data}"
MESSAGES_FILE="$DATA_DIR/messages.jsonl"
STATE_FILE="$DATA_DIR/last_id"

: "${PORT:=3000}"
: "${POLL_INTERVAL_SECONDS:=2}"

mkdir -p "$DATA_DIR"

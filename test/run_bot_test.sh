#!/usr/bin/env bash
# Exercises bin/bot.sh's coproc/dispatch/heartbeat logic against the fake
# Gateway in test/fake_websocat, without a real Discord token or network
# access. Runs in an isolated temp DATA_DIR (never touches the real
# data/ directory) and asserts on the resulting messages.jsonl/last_id,
# rather than requiring a human to eyeball the output. Exit code is 0 if
# every assertion passes, 1 otherwise -- safe to wire into CI.
#
# Usage: test/run_bot_test.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$TEST_DIR/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DATA_DIR="$WORK_DIR/data"
export DISCORD_BOT_TOKEN="fake-token-for-test"
export DISCORD_CHANNEL_ID="123456789"
export STUB_LOG="$WORK_DIR/stub.log"
export PATH="$TEST_DIR/fake_websocat:$PATH"

mkdir -p "$DATA_DIR"

timeout 8 "$APP_ROOT/bin/bot.sh" > "$WORK_DIR/bot.out" 2>&1
bot_exit=$?

messages_file="$DATA_DIR/messages.jsonl"
last_id_file="$DATA_DIR/last_id"

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}
pass() {
  echo "pass: $1"
}

check_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (expected [$expected], got [$actual])"
  fi
}

if [ ! -f "$messages_file" ]; then
  fail "messages.jsonl was created"
  echo "--- bot.sh output ---" >&2
  cat "$WORK_DIR/bot.out" >&2
  exit 1
fi

# --- Channel filtering: message 556 (a different channel) must never
# appear, in either its create or delete form. ---
if grep -q '"id":"556"' "$messages_file"; then
  fail "message from a different channel (556) leaked into the feed"
else
  pass "message from a different channel was filtered out"
fi

# --- Creates: exactly one create record each for 555 and 557. ---
check_eq "one create record for message 555" \
  "$(jq -c 'select(.kind == "create" and .id == "555")' "$messages_file" | wc -l | tr -d ' ')" "1"
check_eq "one create record for message 557 (with nick/avatar/attachment)" \
  "$(jq -c 'select(.kind == "create" and .id == "557")' "$messages_file" | wc -l | tr -d ' ')" "1"
check_eq "message 557's author name resolves from member nick" \
  "$(jq -r 'select(.id == "557") | .authorName' "$messages_file" | head -1)" "Nicky"
check_eq "multi-line content is preserved on one JSONL line" \
  "$(jq -r 'select(.kind == "create" and .id == "557") | .content' "$messages_file")" "multi
line
content"

# --- Updates: exactly one update record for 555 (the partial update with
# no content must be skipped, not produce a second, blank-content record). ---
check_eq "exactly one update record for message 555 (partial update skipped)" \
  "$(jq -c 'select(.kind == "update" and .id == "555")' "$messages_file" | wc -l | tr -d ' ')" "1"
check_eq "the update carries the edited content" \
  "$(jq -r 'select(.kind == "update" and .id == "555") | .content' "$messages_file")" \
  "hello from gateway (edited!)"

# --- Deletes: exactly one delete record for 557. ---
check_eq "exactly one delete record for message 557" \
  "$(jq -c 'select(.kind == "delete" and .id == "557")' "$messages_file" | wc -l | tr -d ' ')" "1"

# --- last_id only advances on creates, never on the update/delete that
# follow it (both reference earlier, lower/equal IDs). ---
check_eq "last_id reflects the newest create (557), unmoved by later edits/deletes" \
  "$(cat "$last_id_file" 2>/dev/null)" "557"

# --- Heartbeats: the timer-driven loop plus the injected server-requested
# out-of-band heartbeat (op:1) should both have reached the stub. ---
heartbeat_count="$(grep -c '"op":1' "$WORK_DIR/stub.log" 2>/dev/null || echo 0)"
if [ "$heartbeat_count" -ge 2 ]; then
  pass "heartbeats were sent, including a response to the server-requested one ($heartbeat_count total)"
else
  fail "expected at least 2 heartbeats (timer-driven + server-requested), got $heartbeat_count"
fi

echo "---"
if [ "$failures" -eq 0 ]; then
  echo "PASS: all assertions passed"
  exit 0
else
  echo "FAIL: $failures assertion(s) failed"
  echo "--- bot.sh output ---" >&2
  cat "$WORK_DIR/bot.out" >&2
  exit 1
fi

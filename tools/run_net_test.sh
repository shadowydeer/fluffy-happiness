#!/usr/bin/env bash
# Two-instance co-op regression: a host and a client on 127.0.0.1, both headless.
#   tools/run_net_test.sh [port]
# Exits 0 when both instances pass every check and neither logged a script error.
set -uo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"
PORT="${1:-7791}"
LOGS="${TMPDIR:-/tmp}"
HOST_LOG="$LOGS/bind_and_deliver_host.log"
CLIENT_LOG="$LOGS/bind_and_deliver_client.log"

"$GODOT" --headless --path . -s tools/net_test.gd -- host "$PORT" > "$HOST_LOG" 2>&1 &
host=$!
sleep 2
"$GODOT" --headless --path . -s tools/net_test.gd -- join "$PORT" > "$CLIENT_LOG" 2>&1 &
client=$!

wait "$host"
host_code=$?
wait "$client"
client_code=$?

grep -h -E '^(PASS|FAIL|RESULT)' "$HOST_LOG" "$CLIENT_LOG"
errors=$(cat "$HOST_LOG" "$CLIENT_LOG" | grep -c -E 'SCRIPT ERROR|Parse Error')
echo "host exit $host_code, client exit $client_code, script errors $errors (logs: $HOST_LOG $CLIENT_LOG)"
[ "$host_code" -eq 0 ] && [ "$client_code" -eq 0 ] && [ "$errors" -eq 0 ]

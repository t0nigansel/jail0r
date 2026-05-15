#!/usr/bin/env bash
# jail0r test suite — runs against a local Python mock server.
# Requires: bash, curl, jq, python3

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RUNNER="$REPO_DIR/run.sh"

PASS=0
FAIL=0

pass() { printf "[PASS] %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "[FAIL] %s\n" "$1"; FAIL=$((FAIL + 1)); }

# --- Setup temp workspace ---------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; stop_mock' EXIT

mkdir -p "$WORK/attacks" "$WORK/results"
printf "Test attack prompt one\n" > "$WORK/attacks/test.txt"

# Source default detector patterns.
. "$REPO_DIR/detectors.example.env"
export JAIL0R_ATTACKS_DIR="$WORK/attacks"
export JAIL0R_RESULTS_DIR="$WORK/results"
export JAIL0R_BEARER_TOKEN=""
export JAIL0R_TIMEOUT_SECONDS=10

# --- Mock server helpers ----------------------------------------------------

MOCK_PID=""

free_port() {
    python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)"
}

start_mock() {
    local port="$1" mode="$2"
    python3 "$SCRIPT_DIR/mock_server.py" "$mode" "$port" &
    MOCK_PID=$!
    sleep 0.4
}

stop_mock() {
    if [ -n "$MOCK_PID" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        MOCK_PID=""
    fi
}

run_jail0r() {
    (cd "$REPO_DIR" && bash "$RUNNER" "$@")
}

# --- Tests ------------------------------------------------------------------

# Test 1: refusal response → exit 0
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0
run_jail0r || code=$?
if [ "$code" -eq 0 ]; then
    pass "refusal response exits 0"
else
    fail "refusal response exits 0 (got $code)"
fi
stop_mock

# Test 2: bypass response → exit 1
PORT="$(free_port)"
start_mock "$PORT" "bypassed"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0
run_jail0r || code=$?
if [ "$code" -eq 1 ]; then
    pass "bypass response exits 1"
else
    fail "bypass response exits 1 (got $code)"
fi
stop_mock

# Test 3: network error, non-CI mode → exit 0
PORT="$(free_port)"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0
run_jail0r || code=$?
if [ "$code" -eq 0 ]; then
    pass "network error non-CI exits 0"
else
    fail "network error non-CI exits 0 (got $code)"
fi

# Test 4: network error, CI mode → exit 2
code=0
run_jail0r --ci || code=$?
if [ "$code" -eq 2 ]; then
    pass "network error CI exits 2"
else
    fail "network error CI exits 2 (got $code)"
fi

# Test 5: non-2xx response, CI mode → exit 2
PORT="$(free_port)"
start_mock "$PORT" "error"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0
run_jail0r --ci || code=$?
if [ "$code" -eq 2 ]; then
    pass "non-2xx CI exits 2"
else
    fail "non-2xx CI exits 2 (got $code)"
fi
stop_mock

# Test 6: summary contains prompt text
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
run_jail0r || true
SUMMARY="$WORK/results/summary.md"
if grep -q "Test attack prompt one" "$SUMMARY"; then
    pass "summary contains prompt text"
else
    fail "summary contains prompt text (not found in $SUMMARY)"
fi
stop_mock

# Test 7: summary contains verdict
if grep -qE "REFUSED|BYPASSED" "$SUMMARY"; then
    pass "summary contains REFUSED or BYPASSED verdict"
else
    fail "summary contains verdict"
fi

# Test 8: JAIL0R_JSON_FIELD override produces correct field name
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
export JAIL0R_JSON_FIELD="input"
code=0
run_jail0r || code=$?
if [ "$code" -eq 0 ]; then
    pass "JAIL0R_JSON_FIELD override exits cleanly"
else
    fail "JAIL0R_JSON_FIELD override exits cleanly (got $code)"
fi
export JAIL0R_JSON_FIELD="message"
stop_mock

# Test 9: request template file
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
TMPL="$WORK/tmpl.json"
printf '{"input":"{{prompt}}","mode":"test"}\n' > "$TMPL"
export JAIL0R_REQUEST_TEMPLATE_FILE="$TMPL"
code=0
run_jail0r || code=$?
if [ "$code" -eq 0 ]; then
    pass "JAIL0R_REQUEST_TEMPLATE_FILE exits cleanly"
else
    fail "JAIL0R_REQUEST_TEMPLATE_FILE exits cleanly (got $code)"
fi
export JAIL0R_REQUEST_TEMPLATE_FILE=""
stop_mock

# Test 10: missing JAIL0R_TARGET_URL → exit 2
PORT="$(free_port)"
code=0
(unset JAIL0R_TARGET_URL; cd "$REPO_DIR" && bash "$RUNNER") || code=$?
if [ "$code" -eq 2 ]; then
    pass "missing JAIL0R_TARGET_URL exits 2"
else
    fail "missing JAIL0R_TARGET_URL exits 2 (got $code)"
fi

# --- Summary ----------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

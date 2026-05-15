#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
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

# --- Setup temp workspace -----------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; stop_mock' EXIT

mkdir -p "$WORK/attacks" "$WORK/results"
printf "Test attack prompt one\n" > "$WORK/attacks/test.txt"
printf "Test attack prompt two\n" > "$WORK/attacks/other.txt"

. "$REPO_DIR/detectors.example.env"
export JAIL0R_ATTACKS_DIR="$WORK/attacks"
export JAIL0R_RESULTS_DIR="$WORK/results"
export JAIL0R_BEARER_TOKEN=""
export JAIL0R_TIMEOUT_SECONDS=10

# --- Mock server helpers ------------------------------------------------------

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

# --- Core exit-code tests -----------------------------------------------------

# Test 1: refusal response → exit 0
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0; run_jail0r || code=$?
[ "$code" -eq 0 ] && pass "refusal response exits 0" || fail "refusal response exits 0 (got $code)"
stop_mock

# Test 2: bypass response → exit 1
PORT="$(free_port)"
start_mock "$PORT" "bypassed"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0; run_jail0r || code=$?
[ "$code" -eq 1 ] && pass "bypass response exits 1" || fail "bypass response exits 1 (got $code)"
stop_mock

# Test 3: unclear response, no --strict → exit 0
PORT="$(free_port)"
start_mock "$PORT" "unclear"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0; run_jail0r || code=$?
[ "$code" -eq 0 ] && pass "unclear response (no --strict) exits 0" || fail "unclear response (no --strict) exits 0 (got $code)"
stop_mock

# Test 4: unclear response + --strict → exit 1
PORT="$(free_port)"
start_mock "$PORT" "unclear"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0; run_jail0r --strict || code=$?
[ "$code" -eq 1 ] && pass "unclear + --strict exits 1" || fail "unclear + --strict exits 1 (got $code)"
stop_mock

# Test 5: network error, non-CI → exit 0
PORT="$(free_port)"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0; run_jail0r || code=$?
[ "$code" -eq 0 ] && pass "network error non-CI exits 0" || fail "network error non-CI exits 0 (got $code)"

# Test 6: network error, CI → exit 2
code=0; run_jail0r --ci || code=$?
[ "$code" -eq 2 ] && pass "network error CI exits 2" || fail "network error CI exits 2 (got $code)"

# Test 7: non-2xx response, CI → exit 2
PORT="$(free_port)"
start_mock "$PORT" "error"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0; run_jail0r --ci || code=$?
[ "$code" -eq 2 ] && pass "non-2xx CI exits 2" || fail "non-2xx CI exits 2 (got $code)"
stop_mock

# --- Summary content tests ----------------------------------------------------

# Test 8: summary contains prompt text
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
run_jail0r || true
SUMMARY="$WORK/results/summary.md"
grep -q "Test attack prompt one" "$SUMMARY" \
    && pass "summary contains prompt text" \
    || fail "summary contains prompt text"
stop_mock

# Test 9: summary contains verdict
grep -qE "BYPASSED|REFUSED|UNCLEAR" "$SUMMARY" \
    && pass "summary contains a verdict" \
    || fail "summary contains a verdict"

# Test 10: summary contains aggregate results table
grep -q "## Results" "$SUMMARY" \
    && pass "summary contains aggregate Results section" \
    || fail "summary contains aggregate Results section"

# Test 11: summary contains response snippet
grep -q "Response:" "$SUMMARY" \
    && pass "summary contains Response snippet" \
    || fail "summary contains Response snippet"

# --- --only flag tests --------------------------------------------------------

# Test 12: --only runs only named category
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
rm -f "$WORK/results"/test_001.json "$WORK/results"/other_001.json
run_jail0r --only test || true
if [ -f "$WORK/results/test_001.json" ] && [ ! -f "$WORK/results/other_001.json" ]; then
    pass "--only processes only named category"
else
    fail "--only processes only named category"
fi
stop_mock

# Test 13: --only with nonexistent category → exit 2
PORT="$(free_port)"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
code=0; run_jail0r --only nonexistent || code=$?
[ "$code" -eq 2 ] && pass "--only nonexistent category exits 2" || fail "--only nonexistent category exits 2 (got $code)"

# --- Config & template tests --------------------------------------------------

# Test 14: JAIL0R_JSON_FIELD override
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
export JAIL0R_JSON_FIELD="input"
code=0; run_jail0r --only test || code=$?
[ "$code" -eq 0 ] && pass "JAIL0R_JSON_FIELD override exits cleanly" || fail "JAIL0R_JSON_FIELD override exits cleanly (got $code)"
export JAIL0R_JSON_FIELD="message"
stop_mock

# Test 15: JAIL0R_REQUEST_TEMPLATE_FILE
PORT="$(free_port)"
start_mock "$PORT" "refused"
export JAIL0R_TARGET_URL="http://127.0.0.1:$PORT"
TMPL="$WORK/tmpl.json"
printf '{"input":"{{prompt}}","mode":"test"}\n' > "$TMPL"
export JAIL0R_REQUEST_TEMPLATE_FILE="$TMPL"
code=0; run_jail0r --only test || code=$?
[ "$code" -eq 0 ] && pass "JAIL0R_REQUEST_TEMPLATE_FILE exits cleanly" || fail "JAIL0R_REQUEST_TEMPLATE_FILE exits cleanly (got $code)"
export JAIL0R_REQUEST_TEMPLATE_FILE=""
stop_mock

# Test 16: missing JAIL0R_TARGET_URL → exit 2
code=0
(unset JAIL0R_TARGET_URL; cd "$REPO_DIR" && bash "$RUNNER") || code=$?
[ "$code" -eq 2 ] && pass "missing JAIL0R_TARGET_URL exits 2" || fail "missing JAIL0R_TARGET_URL exits 2 (got $code)"

# --- Summary ------------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

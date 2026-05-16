#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# jail0r — jailbreak regression for LLM HTTP endpoints.
#
# Reads attack prompts from $JAIL0R_ATTACKS_DIR, sends each as a POST request
# to $JAIL0R_TARGET_URL, writes per-prompt JSON results and a summary.md.

set -eu

# --- Argument parsing ---------------------------------------------------------

CI_MODE=0
STRICT_MODE=0
ONLY_CATEGORY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ci)     CI_MODE=1; shift ;;
        --strict) STRICT_MODE=1; shift ;;
        --only)
            if [ -z "${2:-}" ]; then
                printf "jail0r: --only requires a category name\n" >&2; exit 2
            fi
            ONLY_CATEGORY="$2"; shift 2 ;;
        -h|--help)
            printf "Usage: %s [--ci] [--strict] [--only <category>]\n\n" "$0"
            printf "  --ci              Exit 2 on endpoint errors (for CI pipelines)\n"
            printf "  --strict          Exit 1 on UNCLEAR verdicts (no pattern matched)\n"
            printf "  --only <name>     Run only the named attack category\n\n"
            printf "Environment:\n"
            printf "  JAIL0R_TARGET_URL          Target endpoint (required)\n"
            printf "  JAIL0R_BEARER_TOKEN        Bearer token (optional)\n"
            printf "  JAIL0R_ATTACKS_DIR         Attack corpus dir (default: attacks)\n"
            printf "  JAIL0R_JSON_FIELD          Prompt field name (default: message)\n"
            printf "  JAIL0R_REQUEST_TEMPLATE_FILE  Full request template with {{prompt}}\n"
            printf "  JAIL0R_RESULTS_DIR         Output dir (default: results)\n"
            printf "  JAIL0R_TIMEOUT_SECONDS     Curl timeout (default: 60)\n"
            printf "  JAIL0R_REFUSAL_PATTERNS    Refusal regex (source detectors.example.env or a target profile)\n"
            printf "  JAIL0R_LEAK_PATTERNS       Leak regex (source detectors.example.env or a target profile)\n"
            exit 0 ;;
        *)
            printf "jail0r: unknown argument: %s\n" "$1" >&2; exit 2 ;;
    esac
done

# --- Dependency checks --------------------------------------------------------

for bin in curl jq awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        printf "jail0r: missing dependency: %s\n" "$bin" >&2; exit 2
    fi
done

# --- Config validation --------------------------------------------------------

: "${JAIL0R_ATTACKS_DIR:=attacks}"
: "${JAIL0R_JSON_FIELD:=message}"
: "${JAIL0R_BEARER_TOKEN:=}"
: "${JAIL0R_TIMEOUT_SECONDS:=60}"
: "${JAIL0R_RESULTS_DIR:=results}"
: "${JAIL0R_REQUEST_TEMPLATE_FILE:=}"

if [ -z "${JAIL0R_TARGET_URL:-}" ]; then
    printf "jail0r: JAIL0R_TARGET_URL is not set\n" >&2; exit 2
fi
if [ -z "${JAIL0R_REFUSAL_PATTERNS:-}" ]; then
    printf "jail0r: JAIL0R_REFUSAL_PATTERNS is not set (source detectors.example.env or a target profile)\n" >&2; exit 2
fi
if [ -z "${JAIL0R_LEAK_PATTERNS:-}" ]; then
    printf "jail0r: JAIL0R_LEAK_PATTERNS is not set (source detectors.example.env or a target profile)\n" >&2; exit 2
fi
if [ ! -d "$JAIL0R_ATTACKS_DIR" ]; then
    printf "jail0r: attacks dir not found: %s\n" "$JAIL0R_ATTACKS_DIR" >&2; exit 2
fi
if [ -n "$ONLY_CATEGORY" ] && [ ! -f "$JAIL0R_ATTACKS_DIR/$ONLY_CATEGORY.txt" ]; then
    printf "jail0r: category not found: %s/%s.txt\n" "$JAIL0R_ATTACKS_DIR" "$ONLY_CATEGORY" >&2; exit 2
fi
if [ -n "$JAIL0R_REQUEST_TEMPLATE_FILE" ] && [ ! -f "$JAIL0R_REQUEST_TEMPLATE_FILE" ]; then
    printf "jail0r: request template not found: %s\n" "$JAIL0R_REQUEST_TEMPLATE_FILE" >&2; exit 2
fi

mkdir -p "$JAIL0R_RESULTS_DIR"
SUMMARY="$JAIL0R_RESULTS_DIR/summary.md"
BODY_TMP="$(mktemp)"
NO_DATA_TMP="$(mktemp)"
CURL_ERR_TMP="$(mktemp)"
trap 'rm -f "$BODY_TMP" "$NO_DATA_TMP" "$CURL_ERR_TMP"' EXIT

# Write summary preamble (aggregate stats prepended after run).
{
    printf "# jail0r summary\n\n"
    printf "Target: %s\n\n" "$JAIL0R_TARGET_URL"
    printf "Run started: %s\n\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$SUMMARY"

# --- Request body builder -----------------------------------------------------

build_body() {
    prompt="$1"
    if [ -n "$JAIL0R_REQUEST_TEMPLATE_FILE" ]; then
        # JSON-safe substitution: encode prompt with jq, then string-replace.
        encoded="$(printf '%s' "$prompt" | jq -Rs .)"
        # Strip surrounding quotes that jq adds, so we can drop into a JSON string.
        encoded_unquoted="${encoded#\"}"
        encoded_unquoted="${encoded_unquoted%\"}"
        awk -v p="$encoded_unquoted" '{ gsub(/\{\{prompt\}\}/, p); print }' \
            "$JAIL0R_REQUEST_TEMPLATE_FILE"
    else
        jq -n --arg field "$JAIL0R_JSON_FIELD" --arg val "$prompt" \
            '{ ($field): $val }'
    fi
}

# --- Verdict logic ------------------------------------------------------------

# Four cases:
#   leak=1, refusal=0    → BYPASSED  (high confidence: clean bypass)
#   leak=1, refusal=1    → UNCLEAR   (contested: leak phrase may be prompt echo in refusal)
#   leak=0, refusal=1    → REFUSED
#   leak=0, refusal=0    → UNCLEAR   (no signal — pattern gap or novel phrasing)
# UNCLEAR is not counted as a bypass unless --strict is set.

classify() {
    text="$1"
    leak=0
    refusal=0
    if printf '%s' "$text" | grep -Eiq "$JAIL0R_LEAK_PATTERNS";    then leak=1;    fi
    if printf '%s' "$text" | grep -Eiq "$JAIL0R_REFUSAL_PATTERNS"; then refusal=1; fi
    if   [ "$leak" -eq 1 ] && [ "$refusal" -eq 0 ]; then printf "BYPASSED"
    elif [ "$leak" -eq 0 ] && [ "$refusal" -eq 1 ]; then printf "REFUSED"
    else                                                  printf "UNCLEAR"
    fi
}

extract_text() {
    file="$1"
    # Tried shapes (in order): choices[0].message.content (OpenAI Chat),
    # reply, response, message, content, output, raw JSON fallback.
    jq -r '
        if .choices[0].message.content? then .choices[0].message.content
        elif .reply?    then .reply
        elif .response? then .response
        elif .message?  then .message
        elif .content?  then .content
        elif .output?   then .output
        else tostring end
    ' "$file" 2>/dev/null || cat "$file"
}

# --- HTTP request helper ------------------------------------------------------

do_request() {
    out_file="$1"; body="$2"
    if [ -n "$JAIL0R_BEARER_TOKEN" ]; then
        curl -s -o "$out_file" -w '%{http_code}' \
            --max-time "$JAIL0R_TIMEOUT_SECONDS" \
            -X POST "$JAIL0R_TARGET_URL" \
            -H "Authorization: Bearer $JAIL0R_BEARER_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$body" \
            2>"$CURL_ERR_TMP"
    else
        curl -s -o "$out_file" -w '%{http_code}' \
            --max-time "$JAIL0R_TIMEOUT_SECONDS" \
            -X POST "$JAIL0R_TARGET_URL" \
            -H "Content-Type: application/json" \
            --data "$body" \
            2>"$CURL_ERR_TMP"
    fi
}

# --- Main loop ----------------------------------------------------------------

count_bypassed=0
count_refused=0
count_unclear=0
count_nodata=0
any_bypass=0
any_unclear=0

for attack_file in "$JAIL0R_ATTACKS_DIR"/*.txt; do
    [ -f "$attack_file" ] || continue
    category="$(basename "$attack_file" .txt)"

    if [ -n "$ONLY_CATEGORY" ] && [ "$category" != "$ONLY_CATEGORY" ]; then
        continue
    fi

    printf "\n## %s\n" "$category" >> "$BODY_TMP"

    n=0
    while IFS= read -r prompt || [ -n "$prompt" ]; do
        # Skip blank and comment lines.
        case "$prompt" in
            ''|\#*) continue ;;
        esac
        n=$((n + 1))
        idx="$(printf '%03d' "$n")"
        out_file="$JAIL0R_RESULTS_DIR/${category}_${idx}.json"

        body="$(build_body "$prompt")"
        http_status="$(do_request "$out_file" "$body" || true)"

        if [ "$http_status" = "000" ] || [ -z "$http_status" ]; then
            printf -- "- %s #%s: network error or timeout\n" \
                "$category" "$idx" >> "$NO_DATA_TMP"
            count_nodata=$((count_nodata + 1))
            if [ "$CI_MODE" -eq 1 ]; then
                printf "jail0r: endpoint error in CI mode, aborting\n" >&2; exit 2
            fi
            continue
        fi

        if [ "${http_status:0:1}" != "2" ]; then
            printf "\n### #%s — NO DATA\n\n- **HTTP:** %s\n- **Signals:** none\n- **Prompt:** %s\n" \
                "$idx" "$http_status" "$prompt" >> "$BODY_TMP"
            count_nodata=$((count_nodata + 1))
            if [ "$CI_MODE" -eq 1 ]; then
                printf "jail0r: non-2xx response in CI mode (%s), aborting\n" \
                    "$http_status" >&2; exit 2
            fi
            continue
        fi

        text="$(extract_text "$out_file")"
        verdict="$(classify "$text")"
        snippet="$(printf '%s' "$text" | head -c 200)"

        signals=""
        if printf '%s' "$text" | grep -Eiq "$JAIL0R_LEAK_PATTERNS"; then
            signals="leak"
        fi
        if printf '%s' "$text" | grep -Eiq "$JAIL0R_REFUSAL_PATTERNS"; then
            signals="${signals:+$signals, }refusal"
        fi
        signals="${signals:-none}"

        printf "\n### #%s — %s\n\n- **HTTP:** %s\n- **Signals:** %s\n- **Prompt:** %s\n- **Response:** %s\n" \
            "$idx" "$verdict" "$http_status" "$signals" "$prompt" "$snippet" >> "$BODY_TMP"

        case "$verdict" in
            BYPASSED) count_bypassed=$((count_bypassed + 1)); any_bypass=1 ;;
            REFUSED)  count_refused=$((count_refused + 1)) ;;
            UNCLEAR)  count_unclear=$((count_unclear + 1)); any_unclear=1 ;;
        esac
    done < "$attack_file"
done

if [ -s "$NO_DATA_TMP" ]; then
    { printf "\n## No data\n\n"; cat "$NO_DATA_TMP"; } >> "$BODY_TMP"
fi

# --- Aggregate stats, then body ----------------------------------------------

total=$((count_bypassed + count_refused + count_unclear + count_nodata))
{
    printf "## Results\n\n"
    printf "| Verdict  | Count | %% |\n"
    printf "|----------|-------|----|\n"
    if [ "$total" -gt 0 ]; then
        printf "| BYPASSED | %5d | %2d%% |\n" \
            "$count_bypassed" "$((count_bypassed * 100 / total))"
        printf "| REFUSED  | %5d | %2d%% |\n" \
            "$count_refused"  "$((count_refused  * 100 / total))"
        printf "| UNCLEAR  | %5d | %2d%% |\n" \
            "$count_unclear"  "$((count_unclear  * 100 / total))"
        printf "| NO DATA  | %5d | %2d%% |\n" \
            "$count_nodata"   "$((count_nodata   * 100 / total))"
    fi
    printf "\n---\n"
    cat "$BODY_TMP"
} >> "$SUMMARY"

printf "\njail0r: summary written to %s\n" "$SUMMARY"

if [ "$any_bypass" -eq 1 ]; then exit 1; fi
if [ "$STRICT_MODE" -eq 1 ] && [ "$any_unclear" -eq 1 ]; then exit 1; fi
exit 0

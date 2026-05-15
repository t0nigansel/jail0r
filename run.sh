#!/usr/bin/env bash
#
# jail0r — jailbreak regression for LLM HTTP endpoints.
#
# Reads attack prompts from $JAIL0R_ATTACKS_DIR, sends each as a POST request
# to $JAIL0R_TARGET_URL, writes per-prompt JSON results and a summary.md.

set -eu

CI_MODE=0
for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE=1 ;;
        -h|--help)
            printf "Usage: %s [--ci]\n" "$0"
            exit 0
            ;;
        *)
            printf "Unknown argument: %s\n" "$arg" >&2
            exit 2
            ;;
    esac
done

# --- Dependency checks --------------------------------------------------------

for bin in curl jq awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        printf "jail0r: missing dependency: %s\n" "$bin" >&2
        exit 2
    fi
done

# --- Config validation --------------------------------------------------------

: "${JAIL0R_TARGET_URL:?jail0r: JAIL0R_TARGET_URL is not set}"
: "${JAIL0R_ATTACKS_DIR:=attacks}"
: "${JAIL0R_JSON_FIELD:=message}"
: "${JAIL0R_BEARER_TOKEN:=}"
: "${JAIL0R_TIMEOUT_SECONDS:=60}"
: "${JAIL0R_RESULTS_DIR:=results}"
: "${JAIL0R_REQUEST_TEMPLATE_FILE:=}"
: "${JAIL0R_REFUSAL_PATTERNS:?jail0r: JAIL0R_REFUSAL_PATTERNS is not set (source detectors.example.env)}"
: "${JAIL0R_LEAK_PATTERNS:?jail0r: JAIL0R_LEAK_PATTERNS is not set (source detectors.example.env)}"

if [ ! -d "$JAIL0R_ATTACKS_DIR" ]; then
    printf "jail0r: attacks dir not found: %s\n" "$JAIL0R_ATTACKS_DIR" >&2
    exit 2
fi

if [ -n "$JAIL0R_REQUEST_TEMPLATE_FILE" ] && [ ! -f "$JAIL0R_REQUEST_TEMPLATE_FILE" ]; then
    printf "jail0r: request template not found: %s\n" "$JAIL0R_REQUEST_TEMPLATE_FILE" >&2
    exit 2
fi

mkdir -p "$JAIL0R_RESULTS_DIR"
SUMMARY="$JAIL0R_RESULTS_DIR/summary.md"
NO_DATA_TMP="$(mktemp)"
trap 'rm -f "$NO_DATA_TMP"' EXIT

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

classify() {
    text="$1"
    leak=0
    refusal=0
    if printf '%s' "$text" | grep -Eiq "$JAIL0R_LEAK_PATTERNS"; then
        leak=1
    fi
    if printf '%s' "$text" | grep -Eiq "$JAIL0R_REFUSAL_PATTERNS"; then
        refusal=1
    fi
    if [ "$leak" -eq 1 ]; then
        printf "BYPASSED"
    elif [ "$refusal" -eq 1 ]; then
        printf "REFUSED"
    else
        printf "BYPASSED"
    fi
}

extract_text() {
    file="$1"
    # Try common response shapes in order.
    jq -r '
        if .choices[0].message.content? then .choices[0].message.content
        elif .response? then .response
        elif .message? then .message
        elif .content? then .content
        elif .output? then .output
        else tostring end
    ' "$file" 2>/dev/null || cat "$file"
}

# --- Main loop ----------------------------------------------------------------

any_bypass=0
auth_header=()
if [ -n "$JAIL0R_BEARER_TOKEN" ]; then
    auth_header=(-H "Authorization: Bearer $JAIL0R_BEARER_TOKEN")
fi

for attack_file in "$JAIL0R_ATTACKS_DIR"/*.txt; do
    [ -f "$attack_file" ] || continue
    category="$(basename "$attack_file" .txt)"

    printf "\n## %s\n\n" "$category" >> "$SUMMARY"
    printf "| # | HTTP | signals | verdict |\n" >> "$SUMMARY"
    printf "| --- | --- | --- | --- |\n" >> "$SUMMARY"

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

        http_status="$(
            curl -sS -o "$out_file" -w '%{http_code}' \
                --max-time "$JAIL0R_TIMEOUT_SECONDS" \
                -X POST "$JAIL0R_TARGET_URL" \
                "${auth_header[@]}" \
                -H "Content-Type: application/json" \
                --data "$body" \
                2>>"$NO_DATA_TMP" || printf '000'
        )"

        if [ "$http_status" = "000" ] || [ -z "$http_status" ]; then
            printf -- "- %s #%s: network error or timeout\n" \
                "$category" "$idx" >> "$NO_DATA_TMP"
            if [ "$CI_MODE" -eq 1 ]; then
                printf "jail0r: endpoint error in CI mode, aborting\n" >&2
                exit 2
            fi
            continue
        fi

        if [ "${http_status:0:1}" != "2" ]; then
            printf "| %s | %s | http error | NO DATA |\n" \
                "$idx" "$http_status" >> "$SUMMARY"
            if [ "$CI_MODE" -eq 1 ]; then
                printf "jail0r: non-2xx response in CI mode (%s), aborting\n" \
                    "$http_status" >&2
                exit 2
            fi
            continue
        fi

        text="$(extract_text "$out_file")"
        verdict="$(classify "$text")"

        signals=""
        if printf '%s' "$text" | grep -Eiq "$JAIL0R_LEAK_PATTERNS"; then
            signals="leak"
        fi
        if printf '%s' "$text" | grep -Eiq "$JAIL0R_REFUSAL_PATTERNS"; then
            signals="${signals:+$signals, }refusal"
        fi
        signals="${signals:-none}"

        printf "| %s | %s | %s | %s |\n" \
            "$idx" "$http_status" "$signals" "$verdict" >> "$SUMMARY"

        if [ "$verdict" = "BYPASSED" ]; then
            any_bypass=1
        fi
    done < "$attack_file"
done

if [ -s "$NO_DATA_TMP" ]; then
    {
        printf "\n## No data\n\n"
        cat "$NO_DATA_TMP"
    } >> "$SUMMARY"
fi

printf "\njail0r: summary written to %s\n" "$SUMMARY"

if [ "$any_bypass" -eq 1 ]; then
    exit 1
fi
exit 0

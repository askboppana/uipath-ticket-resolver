#!/bin/bash
# forgeops-summary.sh - Summarize ForgeOps CI/CD events into a GitHub Actions summary table
# Reads .forgeops/events.json and writes a Markdown summary to GITHUB_STEP_SUMMARY.

set -euo pipefail

EVENTS_FILE=".forgeops/events.json"

if [ ! -f "$EVENTS_FILE" ]; then
    echo "[INFO] No events file found at ${EVENTS_FILE} - nothing to summarize."
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "### ForgeOps Pipeline Summary" >> "$GITHUB_STEP_SUMMARY"
        echo "" >> "$GITHUB_STEP_SUMMARY"
        echo "No events were recorded during this run." >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
fi

# Count statuses
TOTAL=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
INFO_COUNT=0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))

    # Extract status field from JSON line using simple pattern match
    status=""
    if echo "$line" | grep -q '"status":"PASS"'; then
        status="PASS"
    elif echo "$line" | grep -q '"status":"FAIL"'; then
        status="FAIL"
    elif echo "$line" | grep -q '"status":"SKIP"'; then
        status="SKIP"
    elif echo "$line" | grep -q '"status":"INFO"'; then
        status="INFO"
    fi

    case "$status" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
        INFO) INFO_COUNT=$((INFO_COUNT + 1)) ;;
    esac
done < "$EVENTS_FILE"

# Determine overall result
if [ "$FAIL_COUNT" -gt 0 ]; then
    OVERALL="[FAIL]"
elif [ "$PASS_COUNT" -gt 0 ]; then
    OVERALL="[PASS]"
elif [ "$SKIP_COUNT" -gt 0 ]; then
    OVERALL="[SKIP]"
else
    OVERALL="[INFO]"
fi

# Print to stdout
echo "=== ForgeOps Pipeline Summary ==="
echo "Total events: ${TOTAL}"
echo "  [PASS]: ${PASS_COUNT}"
echo "  [FAIL]: ${FAIL_COUNT}"
echo "  [SKIP]: ${SKIP_COUNT}"
echo "  [INFO]: ${INFO_COUNT}"
echo "Overall: ${OVERALL}"
echo ""

# Write to GITHUB_STEP_SUMMARY
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### ForgeOps Pipeline Summary"
        echo ""
        echo "| Metric | Count |"
        echo "|--------|-------|"
        echo "| Total Events | ${TOTAL} |"
        echo "| [PASS] | ${PASS_COUNT} |"
        echo "| [FAIL] | ${FAIL_COUNT} |"
        echo "| [SKIP] | ${SKIP_COUNT} |"
        echo "| [INFO] | ${INFO_COUNT} |"
        echo ""
        echo "**Overall Result: ${OVERALL}**"
        echo ""
        echo "---"
        echo ""
        echo "#### Event Details"
        echo ""
        echo "| Timestamp | Type | Status | Message |"
        echo "|-----------|------|--------|---------|"

        while IFS= read -r line; do
            [ -z "$line" ] && continue

            # Extract fields with simple sed patterns
            ts="$(echo "$line" | sed 's/.*"timestamp":"\([^"]*\)".*/\1/')"
            etype="$(echo "$line" | sed 's/.*"event_type":"\([^"]*\)".*/\1/')"
            st="$(echo "$line" | sed 's/.*"status":"\([^"]*\)".*/\1/')"
            msg="$(echo "$line" | sed 's/.*"message":"\([^"]*\)".*/\1/')"

            echo "| ${ts} | ${etype} | [${st}] | ${msg} |"
        done < "$EVENTS_FILE"

    } >> "$GITHUB_STEP_SUMMARY"
fi

# Exit with failure if any FAIL events recorded
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0

#!/bin/bash
# forgeops-log.sh - Structured event logging for ForgeOps CI/CD pipelines
# Usage: forgeops-log.sh <event_type> <status> <message> [json_payload]
# Writes to GITHUB_STEP_SUMMARY, appends to .forgeops/events.json,
# and optionally forwards to Splunk HEC.

set -euo pipefail

EVENT_TYPE="${1:-}"
STATUS="${2:-}"
MESSAGE="${3:-}"
JSON_PAYLOAD="${4:-{}}"

if [ -z "$EVENT_TYPE" ] || [ -z "$STATUS" ] || [ -z "$MESSAGE" ]; then
    echo "Usage: forgeops-log.sh <event_type> <status> <message> [json_payload]"
    echo "  event_type: deploy, test, security, build, notify, etc."
    echo "  status:     PASS, FAIL, SKIP, INFO"
    echo "  message:    Human-readable description"
    echo "  json_payload: Optional JSON object with extra fields"
    exit 1
fi

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Normalize status label
case "$STATUS" in
    PASS|pass) STATUS_LABEL="[PASS]" ;;
    FAIL|fail) STATUS_LABEL="[FAIL]" ;;
    SKIP|skip) STATUS_LABEL="[SKIP]" ;;
    INFO|info) STATUS_LABEL="[INFO]" ;;
    *)         STATUS_LABEL="[$STATUS]" ;;
esac

# --- Write to GITHUB_STEP_SUMMARY ---
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "| ${TIMESTAMP} | ${EVENT_TYPE} | ${STATUS_LABEL} | ${MESSAGE} |" >> "$GITHUB_STEP_SUMMARY"
fi

# --- Append JSON event to .forgeops/events.json ---
EVENTS_DIR=".forgeops"
EVENTS_FILE="${EVENTS_DIR}/events.json"
mkdir -p "$EVENTS_DIR"

# Build a single JSON line using only shell builtins and standard tools
# Escape double quotes in message for safe JSON embedding
ESCAPED_MESSAGE="$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g')"
ESCAPED_TYPE="$(printf '%s' "$EVENT_TYPE" | sed 's/\\/\\\\/g; s/"/\\"/g')"

EVENT_LINE="{\"timestamp\":\"${TIMESTAMP}\",\"event_type\":\"${ESCAPED_TYPE}\",\"status\":\"${STATUS}\",\"message\":\"${ESCAPED_MESSAGE}\",\"payload\":${JSON_PAYLOAD}}"

echo "$EVENT_LINE" >> "$EVENTS_FILE"

# --- Forward to Splunk HEC if configured ---
if [ -n "${SPLUNK_HEC_URL:-}" ]; then
    SPLUNK_TOKEN="${SPLUNK_HEC_TOKEN:-}"
    if [ -z "$SPLUNK_TOKEN" ]; then
        # Silently skip if token is not set
        exit 0
    fi

    SPLUNK_INDEX="${SPLUNK_INDEX:-main}"
    SPLUNK_SOURCE="${SPLUNK_SOURCE:-forgeops-ci}"
    SPLUNK_SOURCETYPE="${SPLUNK_SOURCETYPE:-forgeops:event}"

    SPLUNK_PAYLOAD="{\"index\":\"${SPLUNK_INDEX}\",\"source\":\"${SPLUNK_SOURCE}\",\"sourcetype\":\"${SPLUNK_SOURCETYPE}\",\"event\":${EVENT_LINE}}"

    # Send to Splunk HEC; ignore failures so the pipeline continues
    curl -s -S -k \
        -H "Authorization: Splunk ${SPLUNK_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$SPLUNK_PAYLOAD" \
        "${SPLUNK_HEC_URL}/services/collector/event" \
        >/dev/null 2>&1 || true
fi

exit 0

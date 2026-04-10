#!/bin/bash
# cherwell-health-check.sh - Health check for Cherwell or ServiceNow ITSM connectivity
# Checks CHERWELL_URL or SERVICENOW_URL env vars and tests API reachability.

set -euo pipefail

CHERWELL_URL="${CHERWELL_URL:-}"
SERVICENOW_URL="${SERVICENOW_URL:-}"

# Determine which ITSM backend is configured
BACKEND=""
URL=""

if [ -n "$CHERWELL_URL" ]; then
    BACKEND="Cherwell"
    URL="$CHERWELL_URL"
elif [ -n "$SERVICENOW_URL" ]; then
    BACKEND="ServiceNow"
    URL="$SERVICENOW_URL"
else
    echo "[SKIP] No ITSM configured (neither CHERWELL_URL nor SERVICENOW_URL is set)"
    exit 0
fi

echo "[INFO] ITSM backend: ${BACKEND}"
echo "[INFO] URL: ${URL}"

# Build the health check endpoint
if [ "$BACKEND" = "Cherwell" ]; then
    HEALTH_ENDPOINT="${URL%/}/CherwellAPI/api/V1/serviceinfo"
elif [ "$BACKEND" = "ServiceNow" ]; then
    HEALTH_ENDPOINT="${URL%/}/api/now/table/sys_properties?sysparm_limit=1"
fi

echo "[INFO] Testing connectivity to: ${HEALTH_ENDPOINT}"

# Perform the health check via curl
HTTP_CODE=""
CURL_EXIT=0

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 \
    --max-time 30 \
    -H "Accept: application/json" \
    "$HEALTH_ENDPOINT" 2>/dev/null) || CURL_EXIT=$?

if [ "$CURL_EXIT" -ne 0 ]; then
    echo "[FAIL] Connection failed (curl exit code: ${CURL_EXIT})"
    echo ""
    echo "Possible causes:"
    echo "  - URL is unreachable or DNS resolution failed"
    echo "  - Network/firewall is blocking the connection"
    echo "  - TLS/SSL certificate issue"
    exit 1
fi

echo "[INFO] HTTP response code: ${HTTP_CODE}"

case "$HTTP_CODE" in
    200|201|204)
        echo "[PASS] ${BACKEND} is reachable and responding (HTTP ${HTTP_CODE})"
        ;;
    401|403)
        echo "[PASS] ${BACKEND} is reachable (HTTP ${HTTP_CODE} - authentication required, which is expected)"
        echo "[INFO] The endpoint responded but credentials are needed for full access"
        ;;
    404)
        echo "[FAIL] ${BACKEND} returned HTTP 404 - endpoint not found"
        echo "[INFO] The server is reachable but the API path may be incorrect"
        exit 1
        ;;
    5[0-9][0-9])
        echo "[FAIL] ${BACKEND} returned server error (HTTP ${HTTP_CODE})"
        exit 1
        ;;
    000)
        echo "[FAIL] No response received from ${BACKEND}"
        exit 1
        ;;
    *)
        echo "[INFO] ${BACKEND} returned HTTP ${HTTP_CODE} - unexpected status"
        echo "[INFO] The server is reachable but returned a non-standard response"
        ;;
esac

# DNS resolution check
HOSTNAME="$(echo "$URL" | sed 's|https\?://||' | sed 's|/.*||' | sed 's|:.*||')"
echo ""
echo "[INFO] DNS resolution for: ${HOSTNAME}"
if command -v nslookup >/dev/null 2>&1; then
    if nslookup "$HOSTNAME" >/dev/null 2>&1; then
        echo "[PASS] DNS resolution successful for ${HOSTNAME}"
    else
        echo "[FAIL] DNS resolution failed for ${HOSTNAME}"
        exit 1
    fi
elif command -v host >/dev/null 2>&1; then
    if host "$HOSTNAME" >/dev/null 2>&1; then
        echo "[PASS] DNS resolution successful for ${HOSTNAME}"
    else
        echo "[FAIL] DNS resolution failed for ${HOSTNAME}"
        exit 1
    fi
else
    echo "[SKIP] No DNS lookup tool available (nslookup/host not found)"
fi

echo ""
echo "[PASS] ${BACKEND} health check completed successfully"
exit 0

#!/bin/bash
# =============================================================================
# Health Check Script
# Monitors all critical endpoints and container health.
# Run via cron (every 5 min) or manually with: make health-check
# Exits non-zero if anything is unhealthy — suitable for alerting.
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

# Load .env for domain config
while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    key="${key# }"; key="${key% }"
    value="${value# }"; value="${value% }"
    export "${key}"="${value}"
done < .env 2>/dev/null || true

FAILURES=""
WARNINGS=""

# =============================================================================
# 1. Docker container health
# =============================================================================
for container in $(docker compose ps -q 2>/dev/null); do
    name=$(docker inspect --format '{{.Name}}' "$container" | tr -d '/')
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "unknown")

    if [ "${status}" != "running" ]; then
        FAILURES="${FAILURES}
  ❌ ${name}: not running (status: ${status})"
    elif [ "${health}" = "unhealthy" ]; then
        FAILURES="${FAILURES}
  ❌ ${name}: unhealthy"
    fi
done

# =============================================================================
# 2. TLS endpoint checks
# =============================================================================
check_endpoint() {
    local url="$1" name="$2"
    local http_code
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
    case "${http_code}" in
        000) FAILURES="${FAILURES}
  ❌ ${name}: unreachable (timeout/refused)" ;;
        2??|3??) ;;  # OK
        401) ;;       # Auth required (expected for dashboard)
        *) WARNINGS="${WARNINGS}
  ⚠️  ${name}: HTTP ${http_code}" ;;
    esac
}

if [ -n "${AUTHENTIK_DOMAIN:-}" ]; then
    check_endpoint "https://${AUTHENTIK_DOMAIN}/-/health/ready/" "Authentik"
fi

if [ -n "${TRAEFIK_DOMAIN:-}" ]; then
    check_endpoint "https://${TRAEFIK_DOMAIN}" "Traefik Dashboard"
fi

# =============================================================================
# 3. Report
# =============================================================================
if [ -n "${FAILURES}" ]; then
    echo -e "🔴 HEALTH CHECK FAILED:${FAILURES}"
    [ -n "${WARNINGS}" ] && echo -e "\nWarnings:${WARNINGS}"
    exit 1
elif [ -n "${WARNINGS}" ]; then
    echo -e "🟡 Health check passed with warnings:${WARNINGS}"
    exit 0
else
    echo "🟢 All systems healthy"
    exit 0
fi
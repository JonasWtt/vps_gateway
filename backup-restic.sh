#!/bin/bash
# =============================================================================
# Authentik + Traefik Restic Backup
# Encrypted, deduplicated, compressed offsite-ready backups
# =============================================================================

set -euo pipefail

# --- Configuration ---
DEPLOY_DIR="/opt/authentik-traefik"
RESTIC_REPO="/opt/backups/authentik/restic-repo"
RESTIC_PASSWORD_FILE="/opt/backups/authentik/.restic-password"
RESTIC_CACHE_DIR="/opt/backups/authentik/.cache"
RETENTION_POLICY="--keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Ensure restic cache dir exists
mkdir -p "${RESTIC_CACHE_DIR}"

export RESTIC_REPOSITORY="${RESTIC_REPO}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

# --- Pre-flight checks ---
command -v restic >/dev/null 2>&1 || error_exit "restic not found in PATH"
[ -f "${RESTIC_PASSWORD_FILE}" ] || error_exit "Restic password file not found: ${RESTIC_PASSWORD_FILE}"
restic snapshots --quiet >/dev/null 2>&1 || error_exit "Restic repo inaccessible or not initialized"

# --- 1. PostgreSQL dump (hot backup via pg_dump) ---
log "Dumping PostgreSQL database..."
PGDUMP_FILE="/tmp/authentik_pgdump_${TIMESTAMP}.dump"
docker exec authentik-postgresql pg_dump -U authentik -d authentik -Fc > "${PGDUMP_FILE}" 2>/dev/null || {
    rm -f "${PGDUMP_FILE}"
    error_exit "PostgreSQL dump failed"
}
PGDUMP_SIZE=$(du -h "${PGDUMP_FILE}" | cut -f1)
log "PostgreSQL dump completed (${PGDUMP_SIZE})"

# --- 2. Restic backup ---
log "Starting restic backup..."

restic backup \
    "${PGDUMP_FILE}" \
    "${DEPLOY_DIR}/data/media" \
    "${DEPLOY_DIR}/data/custom-templates" \
    "${DEPLOY_DIR}/docker-compose.yml" \
    "${DEPLOY_DIR}/.env" \
    "${DEPLOY_DIR}/traefik/dynamic" \
    --tag "authentik" \
    --tag "automated" \
    --compression auto \
    --exclude "*.log" \
    --exclude "*.tmp" \
    --exclude "__pycache__" \
    --host "gateway" \
    2>&1 || error_exit "Restic backup failed"

# Clean up pg_dump temp file
rm -f "${PGDUMP_FILE}"

# --- 3. Retention policy ---
log "Applying retention policy..."
restic forget ${RETENTION_POLICY} --prune --group-by host 2>&1 | tail -5
log "Retention applied"

# --- 4. Verify latest snapshot ---
log "Verifying latest snapshot..."
SNAPSHOT_COUNT=$(restic snapshots --quiet 2>/dev/null | wc -l)
log "Repository contains ${SNAPSHOT_COUNT} snapshot(s)"

# --- 5. Check repo integrity (weekly, Sunday only) ---
DAY_OF_WEEK=$(date +%u)
if [ "${DAY_OF_WEEK}" = "7" ]; then
    log "Running weekly restic check..."
    restic check --quiet 2>&1 || log "WARNING: Restic check failed"
    log "Restic check completed"
fi

log "Backup completed successfully!"
exit 0

#!/bin/bash
# =============================================================================
# Authentik + Traefik — One-shot setup script
# Run this on a fresh Ubuntu 24.04 server to deploy the full stack.
# Reads .env for all configuration; renders templates for Traefik and Postfix.
# Safe to re-run (idempotent).
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# =============================================================================
# 1. Prerequisites
# =============================================================================
log "Checking prerequisites..."

command -v docker >/dev/null 2>&1  || err "Docker not installed. Install with: curl -fsSL https://get.docker.com | sh"
command -v docker compose >/dev/null 2>&1 || err "Docker Compose v2 not found."
command -v git >/dev/null 2>&1 || err "git not installed."
command -v openssl >/dev/null 2>&1 || err "openssl not installed."

# =============================================================================
# 2. Check for .env or create from template
# =============================================================================
if [ -f .env ]; then
    log ".env found — validating..."
    # Read .env manually to preserve literal $ in values (e.g. htpasswd)
    while IFS='=' read -r key value; do
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        key="${key# }"; key="${key% }"
        value="${value# }"; value="${value% }"
        export "${key}"="${value}"
    done < .env
    [ -z "${PG_PASS:-}" ] && err "PG_PASS not set in .env"
    [ -z "${REDIS_PASS:-}" ] && err "REDIS_PASS not set in .env"
    [ -z "${AUTHENTIK_SECRET_KEY:-}" ] && err "AUTHENTIK_SECRET_KEY not set in .env"
    [ -z "${ACME_EMAIL:-}" ] && err "ACME_EMAIL not set in .env"
    [ -z "${AUTHENTIK_DOMAIN:-}" ] && err "AUTHENTIK_DOMAIN not set in .env"
    [ -z "${TRAEFIK_DOMAIN:-}" ] && err "TRAEFIK_DOMAIN not set in .env"
    [ -z "${SMTP_RELAY_HOST:-}" ] && err "SMTP_RELAY_HOST not set in .env"
    [ -z "${SMTP_RELAY_USER:-}" ] && err "SMTP_RELAY_USER not set in .env"
    [ "${SMTP_RELAY_PASS:-}" = "CHANGE_ME" ] && err "SMTP_RELAY_PASS not set in .env"
else
    log "No .env found — generating from template with random secrets"
    PG_PASS=$(openssl rand -base64 32 | tr -d '=/+')
    REDIS_PASS=$(openssl rand -base64 48 | tr -d '=/+')
    AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '=/+')

    cat > .env << EOF
# Database
PG_USER=authentik
PG_PASS=${PG_PASS}
PG_DB=authentik

# Redis
REDIS_PASS=${REDIS_PASS}

# Authentik
AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY}

# Let's Encrypt
ACME_EMAIL=you@example.com

# Domain
AUTHENTIK_DOMAIN=auth.example.com
TRAEFIK_DOMAIN=traefik.example.com

# SMTP Relay
SMTP_RELAY_HOST=smtp.example.com
SMTP_RELAY_PORT=587
SMTP_RELAY_USER=noreply@example.com
SMTP_RELAY_PASS=CHANGE_ME
EOF

    chmod 600 .env
    err "Template .env created with random secrets. Edit .env and re-run setup.sh."
fi

# Source .env for all following steps
# Read .env manually to preserve literal $ in values (e.g. htpasswd).
# Docker-compose .env files use $$ for literal $ — we un-escape for templates.
while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    key="${key# }"; key="${key% }"
    value="${value# }"; value="${value% }"
    # Un-escape $$ → $ for template rendering (docker-compose uses $$ for literal $)
    value="${value//\\$\\$/\\$}"
    export "${key}"="${value}"
done < .env

# Derive BASE_DOMAIN (strip subdomain: auth.example.com → example.com)
BASE_DOMAIN="${AUTHENTIK_DOMAIN#*.}"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

# =============================================================================
# 3. Render config templates from .env
# =============================================================================
log "Rendering config templates from .env..."

render_template() {
    local src="$1" dst="$2"
    if [ -f "${src}" ]; then
        sed \
            -e "s|{{AUTHENTIK_DOMAIN}}|${AUTHENTIK_DOMAIN}|g" \
            -e "s|{{TRAEFIK_DOMAIN}}|${TRAEFIK_DOMAIN}|g" \
            -e "s|{{BASE_DOMAIN}}|${BASE_DOMAIN}|g" \
            -e "s|{{HOSTNAME}}|${HOSTNAME_FQDN}|g" \
            -e "s|{{SMTP_RELAY_HOST}}|${SMTP_RELAY_HOST}|g" \
            -e "s|{{SMTP_RELAY_PORT}}|${SMTP_RELAY_PORT}|g" \
            -e "s|{{SMTP_RELAY_USER}}|${SMTP_RELAY_USER}|g" \
            -e "s|{{TRAEFIK_DASHBOARD_AUTH}}|${TRAEFIK_DASHBOARD_AUTH}|g" \
            "${src}" > "${dst}"
        log "  Rendered: ${dst}"
    else
        warn "  Template not found: ${src} (skipping)"
    fi
}

render_template "traefik/dynamic/authentik.yml.template" "traefik/dynamic/authentik.yml"
render_template "smtp/main.cf.template" "smtp/main.cf"
render_template "smtp/sender_rewrite.template" "smtp/sender_rewrite"

# =============================================================================
# 4. Create data directories
# =============================================================================
log "Creating data directories..."

mkdir -p data/certs data/media data/custom-templates data/postgres
mkdir -p traefik/dynamic traefik/logs
chmod 777 data/certs  # Traefik needs write access for acme.json

# =============================================================================
# 4b. Install fail2ban Authentik jail
# =============================================================================
log "Installing fail2ban Authentik jail..."

if command -v fail2ban-client >/dev/null 2>&1; then
    sudo cp "${DEPLOY_DIR}/fail2ban/filter-authentik.conf" /etc/fail2ban/filter.d/authentik.conf
    sudo cp "${DEPLOY_DIR}/fail2ban/jail-authentik.conf" /etc/fail2ban/jail.d/authentik.conf
    sudo fail2ban-client reload 2>/dev/null || true
    log "Fail2ban Authentik jail installed"
else
    warn "fail2ban not found — skipping Authentik jail. Install with: sudo apt install fail2ban"
fi

# =============================================================================
# 5. SMTP SASL password
# =============================================================================
log "Setting up SMTP relay..."

if [ ! -f smtp/sasl_passwd ] || [ ! -s smtp/sasl_passwd ]; then
    echo "[${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT} ${SMTP_RELAY_USER}:${SMTP_RELAY_PASS}" > smtp/sasl_passwd
    chmod 600 smtp/sasl_passwd
fi

if [ ! -f smtp/sasl_passwd.db ]; then
    if command -v postmap >/dev/null 2>&1; then
        postmap smtp/sasl_passwd
    else
        log "postmap not found on host — using Docker container to generate sasl_passwd.db"
        docker run --rm -v "$(pwd)/smtp:/etc/postfix" mwader/postfix-relay postmap /etc/postfix/sasl_passwd
    fi
    log "SASL password database generated"
else
    log "sasl_passwd.db already exists, skipping"
fi

# =============================================================================
# 6. Create backup-access group
# =============================================================================
log "Setting up backup group..."

if ! getent group backup-access >/dev/null 2>&1; then
    sudo groupadd backup-access
fi
sudo usermod -aG backup-access "$(whoami)"

# Make .env and docker-compose.yml readable by backup group
sudo chgrp backup-access .env docker-compose.yml 2>/dev/null || true
sudo chmod 640 .env docker-compose.yml 2>/dev/null || true

# =============================================================================
# 7. Docker daemon hardening
# =============================================================================
log "Configuring Docker daemon..."

if [ ! -f /etc/docker/daemon.json ]; then
    sudo tee /etc/docker/daemon.json > /dev/null << 'DAEMON'
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true
}
DAEMON
    log "Docker daemon.json created — restarting Docker"
    sudo systemctl restart docker
else
    warn "/etc/docker/daemon.json already exists, skipping"
fi

# =============================================================================
# 8. Restic backup setup
# =============================================================================
log "Setting up Restic backups..."

command -v restic >/dev/null 2>&1 || sudo apt-get install -y restic

RESTIC_PASS_FILE="/opt/backups/authentik/.restic-password"
RESTIC_REPO="/opt/backups/authentik/restic-repo"

if [ ! -f "${RESTIC_PASS_FILE}" ]; then
    RESTIC_PASS=$(openssl rand -base64 32)
    sudo mkdir -p /opt/backups/authentik
    echo "${RESTIC_PASS}" | sudo tee "${RESTIC_PASS_FILE}" > /dev/null
    sudo chmod 600 "${RESTIC_PASS_FILE}"
    sudo chown "$(whoami)": "$(whoami)" "${RESTIC_PASS_FILE}"
fi

if [ ! -d "${RESTIC_REPO}" ]; then
    RESTIC_REPOSITORY="${RESTIC_REPO}" \
    RESTIC_PASSWORD_FILE="${RESTIC_PASS_FILE}" \
    restic init
    log "Restic repository initialized"
else
    warn "Restic repository already exists, skipping init"
fi

chmod +x backup-restic.sh

# Add cron job for daily backups (idempotent)
CRON_LINE="0 2 * * * sg backup-access -c '${DEPLOY_DIR}/backup-restic.sh'"
(crontab -l 2>/dev/null | grep -v "backup-restic"; echo "$CRON_LINE") | crontab -
log "Backup cron job installed (daily at 02:00)"

# Add cron job for daily TLS cert check
chmod +x check-certs.sh
CRON_CERT="0 8 * * * ${DEPLOY_DIR}/check-certs.sh"
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
if echo "${CURRENT_CRON}" | grep -q "check-certs"; then
    log "Cert check cron already installed"
else
    echo "${CURRENT_CRON}" | cat - <(echo "${CRON_CERT}") | crontab -
    log "Cert check cron job installed (daily at 08:00)"
fi

# =============================================================================
# 9. Start the stack
# =============================================================================
log "Starting Docker Compose stack..."

docker compose pull
docker compose up -d

log "Waiting for containers to become healthy..."
for i in $(seq 1 18); do
    UNHEALTHY=$(docker compose ps --format '{{.Health}}' 2>/dev/null | grep -cv "healthy\|^$" || true)
    if [ "${UNHEALTHY}" -eq 0 ]; then
        log "All containers healthy"
        break
    fi
    if [ "$i" -eq 18 ]; then
        warn "Some containers not healthy after 3 minutes. Check: docker compose ps"
    fi
    echo "  Waiting... ($i/18)"
    sleep 10
done

docker compose ps

# =============================================================================
# 10. Apply Authentik blueprints
# =============================================================================
log "Waiting for Authentik server to be ready..."
for i in $(seq 1 30); do
    if docker exec authentik-server python -c "import urllib.request; urllib.request.urlopen('http://localhost:9000/-/health/live/')" 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        warn "Authentik server not ready after 5 minutes. Apply blueprints manually."
    fi
    echo "  Waiting... ($i/30)"
    sleep 10
done

log "Applying Authentik default blueprints..."
for bp in \
    default/flow-default-authentication-flow.yaml \
    default/flow-default-invalidation-flow.yaml \
    default/events-default.yaml \
    default/default-brand.yaml \
    system/bootstrap.yaml \
    default/flow-default-source-authentication.yaml \
    default/flow-default-source-enrollment.yaml \
    default/flow-default-source-pre-authentication.yaml \
    default/flow-default-authenticator-totp-setup.yaml \
    default/flow-default-authenticator-static-setup.yaml \
    default/flow-default-authenticator-webauthn-setup.yaml \
    default/flow-default-provider-authorization-explicit-consent.yaml \
    default/flow-default-provider-authorization-implicit-consent.yaml \
    default/flow-default-user-settings-flow.yaml \
    default/flow-password-change.yaml \
    default/flow-oobe.yaml \
    system/providers-oauth2.yaml \
    system/providers-saml.yaml \
    system/providers-proxy.yaml \
    system/providers-scim.yaml \
    system/providers-rac.yaml; do
    echo "  Applying: $bp"
    docker exec authentik-server ak apply_blueprint "$bp" 2>/dev/null || true
done

# =============================================================================
# 11. Done
# =============================================================================
echo ""
log "============================================"
log "  Setup complete!"
log "============================================"
echo ""
echo "  Authentik:   https://${AUTHENTIK_DOMAIN}"
echo "  Dashboard:   https://${TRAEFIK_DOMAIN}"
echo ""
echo "Next steps:"
echo "  1. Create your admin account at:"
echo "     https://${AUTHENTIK_DOMAIN}/if/flow/initial-setup/"
echo ""
echo "  2. Test email in Authentik Admin → System → Settings → Email"
echo ""
echo "  3. Add DNS records for SPF/DMARC (improves deliverability)"
echo ""
echo "  4. (Optional) Add your IP to the Traefik dashboard allowlist in:"
echo "     traefik/dynamic/authentik.yml.template"
echo ""
log "Save your .env and restic password securely!"
echo "  Restic password: ${RESTIC_PASS_FILE}"
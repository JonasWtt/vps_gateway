#!/bin/bash
# =============================================================================
# Authentik + Traefik — One-shot setup script
# Run this on a fresh Ubuntu 24.04 server to deploy the full stack.
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
    log ".env found — using existing secrets"
    # Validate that required vars are set
    set -a; source .env; set +a
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
    warn "You MUST edit .env before proceeding!"
    warn "Set: ACME_EMAIL, AUTHENTIK_DOMAIN, TRAEFIK_DOMAIN, SMTP_RELAY_*"

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
    log "Template .env created with random secrets"
    err "Edit .env now and re-run setup.sh. Aborting."
fi

# Source .env for all following steps
set -a; source .env; set +a

# =============================================================================
# 3. Create data directories
# =============================================================================
log "Creating data directories..."

mkdir -p data/certs data/media data/custom-templates data/postgres
mkdir -p traefik/dynamic traefik/logs
chmod 777 data/certs  # Traefik needs write access for acme.json

# =============================================================================
# 4. SMTP SASL password
# =============================================================================
log "Setting up SMTP relay..."

if [ ! -f smtp/sasl_passwd ] || [ ! -f smtp/sasl_passwd.db ]; then
    echo "[${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT} ${SMTP_RELAY_USER}:${SMTP_RELAY_PASS}" > smtp/sasl_passwd
    chmod 600 smtp/sasl_passwd

    # Generate sasl_passwd.db — try postmap on host, fall back to container
    if command -v postmap >/dev/null 2>&1; then
        postmap smtp/sasl_passwd
    else
        log "postmap not found on host — starting temporary container to generate sasl_passwd.db"
        docker compose run --rm --no-deps smtp postmap /etc/postfix/sasl_passwd 2>/dev/null || {
            # Alternative: use a one-off postfix container
            docker run --rm -v "$(pwd)/smtp:/etc/postfix" mwader/postfix-relay postmap /etc/postfix/sasl_passwd
        }
        # postmap inside container writes to /etc/postfix/sasl_passwd.db which maps to smtp/
        # But the :ro mount on main.cf would block. We only mount the smtp dir.
    fi
    log "SASL password database generated"
else
    log "sasl_passwd and sasl_passwd.db already exist, skipping"
fi

# Update main.cf with the correct relayhost and domain
sed -i "s|^relayhost = .*|relayhost = [${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT}|" smtp/main.cf
sed -i "s|^myhostname = .*|myhostname = $(hostname -f)|" smtp/main.cf
DOMAIN="${AUTHENTIK_DOMAIN#*.}"
sed -i "s|^mydomain = .*|mydomain = ${DOMAIN}|" smtp/main.cf

# Update sender_rewrite with the SMTP user
sed -i "s|/^.+$/  .*|/^.+$/  ${SMTP_RELAY_USER}|" smtp/sender_rewrite

# =============================================================================
# 5. Update Traefik dynamic config with domain
# =============================================================================
log "Updating Traefik dynamic config with domain..."

sed -i "s/\`auth\.[^)]*\`/\`auth.${DOMAIN}\`/g" traefik/dynamic/authentik.yml 2>/dev/null || true
# Note: AUTHENTIK_DOMAIN may include subdomain. Use the full domain for Host() rules.
# If your authentik domain differs from the pattern, edit traefik/dynamic/authentik.yml manually.

# =============================================================================
# 6. Create backup-access group
# =============================================================================
log "Setting up backup group..."

if ! getent group backup-access >/dev/null 2>&1; then
    sudo groupadd backup-access
fi
sudo usermod -aG backup-access "$(whoami)"
log "backup-access group created. You may need to log out/in for group to take effect."

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

# Add cron job for daily backups
CRON_LINE="0 2 * * * sg backup-access -c '${DEPLOY_DIR}/backup-restic.sh'"
(crontab -l 2>/dev/null | grep -v "backup-restic"; echo "$CRON_LINE") | crontab -
log "Backup cron job installed (daily at 02:00)"

# =============================================================================
# 9. Start the stack
# =============================================================================
log "Starting Docker Compose stack..."

docker compose pull
docker compose up -d

log "Waiting for containers to become healthy..."
for i in $(seq 1 12); do
    UNHEALTHY=$(docker compose ps --format '{{.Health}}' 2>/dev/null | grep -v "healthy\|^$" | wc -l)
    if [ "${UNHEALTHY}" -eq 0 ]; then
        break
    fi
    echo "  Waiting for containers... ($i/12)"
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
echo "  Dashboard:  https://${TRAEFIK_DOMAIN}"
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
echo "     traefik/dynamic/authentik.yml"
echo ""
log "Save your .env and restic password securely!"
echo "  Restic password: ${RESTIC_PASS_FILE}"
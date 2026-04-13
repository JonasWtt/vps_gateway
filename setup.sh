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
command -v postmap >/dev/null 2>&1 || err "postfix not installed (needed for postmap). Install: sudo apt install postfix"

# Check if .env exists
if [ -f .env ]; then
    warn ".env already exists. Backing up to .env.bak"
    cp .env .env.bak
fi

# =============================================================================
# 2. Generate secrets
# =============================================================================
log "Generating secrets..."

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
ACME_EMAIL=${ACME_EMAIL:-you@example.com}

# Domain
AUTHENTIK_DOMAIN=${AUTHENTIK_DOMAIN:-auth.example.com}
TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN:-traefik.example.com}

# SMTP Relay
SMTP_RELAY_HOST=${SMTP_RELAY_HOST:-smtp.ionos.de}
SMTP_RELAY_PORT=${SMTP_RELAY_PORT:-587}
SMTP_RELAY_USER=${SMTP_RELAY_USER:-noreply@example.com}
SMTP_RELAY_PASS=${SMTP_RELAY_PASS:-CHANGE_ME}
EOF

chmod 600 .env
log "Secrets generated and saved to .env"
warn ">>> Edit .env and set ACME_EMAIL, domains, and SMTP credentials before continuing!"
warn ">>> Press Enter to edit .env, or Ctrl+C to abort and edit manually."
read -r

# =============================================================================
# 3. Create data directories
# =============================================================================
log "Creating data directories..."

mkdir -p data/certs data/media data/custom-templates data/postgres
mkdir -p traefik/dynamic traefik/logs
chmod 600 data/certs
chmod 777 data/certs  # Traefik needs write access for acme.json

# =============================================================================
# 4. SMTP SASL password
# =============================================================================
log "Setting up SMTP relay..."

# Source the .env for SMTP credentials
set -a; source .env; set +a

if [ -f smtp/sasl_passwd ] && [ ! -s smtp/sasl_passwd ]; then
    echo "[${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT} ${SMTP_RELAY_USER}:${SMTP_RELAY_PASS}" > smtp/sasl_passwd
    chmod 600 smtp/sasl_passwd
    postmap smtp/sasl_passwd
    log "SASL password database generated"
elif [ ! -f smtp/sasl_passwd ]; then
    warn "smtp/sasl_passwd not found. Create it from sasl_passwd.example and run: postmap smtp/sasl_passwd"
fi

# Update main.cf with the correct relayhost
sed -i "s/relayhost = .*/relayhost = [${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT}/" smtp/main.cf
sed -i "s/myhostname = .*/myhostname = $(hostname)/" smtp/main.cf
sed -i "s/mydomain = .*/mydomain = ${AUTHENTIK_DOMAIN#*.}/" smtp/main.cf

# Update sender_rewrite with the SMTP user's domain
sed -i "s|/^.+$/  .*|/^.+$/  ${SMTP_RELAY_USER}|" smtp/sender_rewrite

# Update docker-compose.yml email FROM address
sed -i "s/AUTHENTIK_EMAIL__FROM: .*/AUTHENTIK_EMAIL__FROM: ${SMTP_RELAY_USER}/" docker-compose.yml

# =============================================================================
# 5. Create backup-access group
# =============================================================================
log "Setting up backup group..."

if ! getent group backup-access >/dev/null 2>&1; then
    sudo groupadd backup-access
fi
sudo usermod -aG backup-access "$(whoami)"
log "backup-access group created. You may need to log out/in for group to take effect."

# Make .env and docker-compose.yml readable by backup group
chgrp backup-access .env docker-compose.yml 2>/dev/null || true
chmod 640 .env docker-compose.yml 2>/dev/null || true

# =============================================================================
# 6. Docker daemon hardening
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
    log "Docker daemon.json created"
else
    warn "/etc/docker/daemon.json already exists, skipping"
fi

# =============================================================================
# 7. Restic backup setup
# =============================================================================
log "Setting up Restic backups..."

command -v restic >/dev/null 2>&1 || sudo apt-get install -y restic

RESTIC_PASS=$(openssl rand -base64 32)
mkdir -p /opt/backups/authentik

echo "${RESTIC_PASS}" > /opt/backups/authentik/.restic-password
chmod 600 /opt/backups/authentik/.restic-password
chown "$(whoami)": "$(whoami)" /opt/backups/authentik/.restic-password

if [ ! -d /opt/backups/authentik/restic-repo ]; then
    RESTIC_REPOSITORY=/opt/backups/authentik/restic-repo \
    RESTIC_PASSWORD_FILE=/opt/backups/authentik/.restic-password \
    restic init
    log "Restic repository initialized"
else
    warn "Restic repository already exists, skipping init"
fi

chmod 750 backup-restic.sh

# Add cron job for daily backups
CRON_LINE="0 2 * * * sg backup-access -c '${DEPLOY_DIR}/backup-restic.sh'"
(crontab -l 2>/dev/null | grep -v "backup-restic"; echo "$CRON_LINE") | crontab -
log "Backup cron job installed (daily at 02:00)"

# =============================================================================
# 8. Start the stack
# =============================================================================
log "Starting Docker Compose stack..."

docker compose pull
docker compose up -d

log "Waiting for containers to become healthy..."
sleep 30
docker compose ps

# =============================================================================
# 9. Apply Authentik blueprints
# =============================================================================
log "Waiting for Authentik server to be ready..."
for i in $(seq 1 30); do
    if docker exec authentik-server python -c "import urllib.request; urllib.request.urlopen('http://localhost:9000/-/health/live/')" 2>/dev/null; then
        break
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
# 10. Done
# =============================================================================
echo ""
log "============================================"
log "  Setup complete!"
log "============================================"
echo ""
log "Next steps:"
echo "  1. Go to https://${AUTHENTIK_DOMAIN}/if/flow/initial-setup/"
echo "     to create your admin account"
echo ""
echo "  2. Configure email in Authentik Admin → System → Settings → Email"
echo "     (should already be pre-configured via env vars)"
echo ""
echo "  3. Add DNS records for SPF/DKIM/DMARC (improves deliverability)"
echo ""
echo "  4. (Optional) Add your IP to the Traefik dashboard allowlist in:"
echo "     traefik/dynamic/authentik.yml"
echo ""
log "Save your .env file securely — it contains all secrets!"
echo ""
log "Restic backup password is at: /opt/backups/authentik/.restic-password"
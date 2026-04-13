#!/bin/bash
# =============================================================================
# UFW Firewall Rules — Authentik + Traefik deployment
# Reads SSH_PORT from .env (default: 22).
# Exposes ONLY: 80/tcp, 443/tcp (public), SSH_PORT (Tailscale + localhost)
# Removes stale port 22 rule if SSH is on non-standard port.
# Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

# Load SSH_PORT from .env
SSH_PORT="${SSH_PORT:-}"
if [ -z "$SSH_PORT" ]; then
    if [ -f .env ]; then
        SSH_PORT=$(grep -E '^SSH_PORT=' .env | head -1 | cut -d= -f2 | tr -d ' ')
    fi
    SSH_PORT="${SSH_PORT:-22}"
fi

echo "=== UFW firewall setup (SSH port: ${SSH_PORT}) ==="

if [ "$SSH_PORT" = "22" ]; then
    echo "⚠️  WARNING: SSH_PORT is 22 (default). If your SSH is on a non-standard port,"
    echo "   set SSH_PORT in .env before running this script. Wrong value = LOCKOUT."
    echo ""
    read -r -p "Continue with port 22? [y/N] " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Aborted. Set SSH_PORT in .env and re-run."
        exit 1
    fi
fi

# Ensure default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# === Public services ===
sudo ufw allow 80/tcp comment "HTTP (Traefik)"       2>/dev/null || true
sudo ufw allow 443/tcp comment "HTTPS (Traefik)"      2>/dev/null || true

# === SSH on configured port ===
# Tailscale CGNAT range covers all Tailscale devices
sudo ufw allow from 100.64.0.0/10 to any port "${SSH_PORT}" proto tcp comment "SSH via Tailscale" 2>/dev/null || true
sudo ufw allow from 127.0.0.1 to any port "${SSH_PORT}" proto tcp comment "SSH localhost"           2>/dev/null || true
sudo ufw limit "${SSH_PORT}"/tcp comment "SSH rate limit (fallback)"                                2>/dev/null || true

# === Remove stale port 22 rule (if SSH is on a different port) ===
if [ "$SSH_PORT" != "22" ]; then
    STALE_RULES=$(sudo ufw status numbered | grep -E '^\[.\]\s+22/tcp' | grep -v "${SSH_PORT}" || true)
    if [ -n "$STALE_RULES" ]; then
        echo "Removing stale port 22 rules..."
        for num in $(echo "$STALE_RULES" | grep -oP '^\[\K\d+' | sort -rn); do
            echo "  Deleting rule [$num]"
            echo "y" | sudo ufw delete "$num" 2>/dev/null || true
        done
    fi
fi

# === Reload ===
sudo ufw --force reload

echo ""
echo "=== UFW status ==="
sudo ufw status numbered
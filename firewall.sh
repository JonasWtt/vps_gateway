#!/bin/bash
# =============================================================================
# UFW Firewall Rules — Authentik + Traefik deployment
# Exposes ONLY: 80/tcp, 443/tcp (public), 22222/tcp (SSH, Tailscale + localhost)
# Removes stale port 22 rule if present (SSH is on 22222).
# Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

echo "=== Setting up UFW firewall rules ==="

# Ensure default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# === Public services ===
sudo ufw allow 80/tcp comment "HTTP (Traefik)"       2>/dev/null || true
sudo ufw allow 443/tcp comment "HTTPS (Traefik)"      2>/dev/null || true

# === SSH on port 22222 ===
# SSH listens on 22222, bound to Tailscale (100.64.0.0/10) and localhost.
# Allow from Tailscale CGNAT range + localhost. Rate-limit as fallback.
sudo ufw allow from 100.64.0.0/10 to any port 22222 proto tcp comment "SSH via Tailscale" 2>/dev/null || true
sudo ufw allow from 127.0.0.1 to any port 22222 proto tcp comment "SSH localhost"              2>/dev/null || true
sudo ufw limit 22222/tcp comment "SSH rate limit (fallback)"                                  2>/dev/null || true

# === Remove stale port 22 rule (nothing listens on port 22) ===
# Delete by matching rule text, highest number first to avoid renumbering
STALE_RULES=$(sudo ufw status numbered | grep -E '^\[.\]\s+22/tcp' | grep -v '22222' || true)
if [ -n "$STALE_RULES" ]; then
    echo "Removing stale port 22 rules..."
    for num in $(echo "$STALE_RULES" | grep -oP '^\[\K\d+' | sort -rn); do
        echo "  Deleting rule [$num]"
        echo "y" | sudo ufw delete "$num" 2>/dev/null || true
    done
fi

# === Reload ===
sudo ufw --force reload

echo ""
echo "=== UFW status ==="
sudo ufw status numbered
#!/bin/bash
# =============================================================================
# Render config templates from .env values
# Standalone script so Makefile can call it directly.
# setup.sh also has its own render — kept in sync.
# =============================================================================
set -eo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

if [ ! -f .env ]; then
    echo "ERROR: .env not found. Copy .env.example to .env and fill in values."
    exit 1
fi

# Read .env manually to preserve literal $ in values (e.g. htpasswd).
# Docker-compose uses $$ for literal $ — we un-escape for template rendering.
# Note: we avoid set -u because htpasswd values contain $var-like strings
# that would trigger "unbound variable" errors.
while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    key="${key# }"; key="${key% }"
    value="${value# }"; value="${value% }"
    # Un-escape $$ → $ for template rendering (docker-compose uses $$ for literal $)
    value="${value//\$\$/\$}"
    export "${key}"="${value}"
done < <(cat .env; echo)

# Derive BASE_DOMAIN
BASE_DOMAIN="${AUTHENTIK_DOMAIN#*.}"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

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
        echo "Rendered: ${dst}"
    else
        echo "WARNING: Template not found: ${src} (skipping)"
    fi
}

render_template "traefik/dynamic/authentik.yml.template" "traefik/dynamic/authentik.yml"
render_template "smtp/main.cf.template" "smtp/main.cf"
render_template "smtp/sender_rewrite.template" "smtp/sender_rewrite"
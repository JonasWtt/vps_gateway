# =============================================================================
# Authentik + Traefik — Makefile
# =============================================================================
# Convenience targets for common operations.
# All targets assume you're in the deploy directory.
# =============================================================================

DEPLOY_DIR := $(shell pwd)
COMPOSE     := docker compose

.PHONY: help setup up down restart ps logs render backup check-certs \
        blueprints shell-db shell-redis clean

# ---------------------------------------------------------------------------
# Default
# ---------------------------------------------------------------------------
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup & Deployment
# ---------------------------------------------------------------------------
setup: ## Full one-shot setup (run setup.sh)
	bash setup.sh

render: ## Re-render config templates from .env
	@bash -c 'set -a; while IFS== read -r k v; do [[ -z "$$k" || "$$k" == \#* ]] && continue; k="$${k# }"; k="$${k% }"; v="$${v# }"; v="$${v% }"; v="$${v//\\$\\$/\\$}"; export "$$k"="$$v"; done < .env; \
	for t in traefik/dynamic/authentik.yml.template smtp/main.cf.template smtp/sender_rewrite.template; do \
		dst="$${t%.template}"; \
		sed -e "s|{{AUTHENTIK_DOMAIN}}|$$AUTHENTIK_DOMAIN|g" \
		    -e "s|{{TRAEFIK_DOMAIN}}|$$TRAEFIK_DOMAIN|g" \
		    -e "s|{{BASE_DOMAIN}}|$${AUTHENTIK_DOMAIN#*.}|g" \
		    -e "s|{{HOSTNAME}}|$$(hostname -f 2>/dev/null || hostname)|g" \
		    -e "s|{{SMTP_RELAY_HOST}}|$$SMTP_RELAY_HOST|g" \
		    -e "s|{{SMTP_RELAY_PORT}}|$$SMTP_RELAY_PORT|g" \
		    -e "s|{{SMTP_RELAY_USER}}|$$SMTP_RELAY_USER|g" \
		    -e "s|{{TRAEFIK_DASHBOARD_AUTH}}|$$TRAEFIK_DASHBOARD_AUTH|g" \
		    "$$t" > "$$dst" && echo "Rendered: $$dst"; \
	done'

# ---------------------------------------------------------------------------
# Container Management
# ---------------------------------------------------------------------------
up: ## Start all containers
	$(COMPOSE) up -d

down: ## Stop all containers
	$(COMPOSE) down

restart: ## Restart all containers
	$(COMPOSE) restart

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Tail container logs (use: make logs SVC=traefik)
	$(COMPOSE) logs -f --tail 100 $(SVC)

pull: ## Pull latest images
	$(COMPOSE) pull

# ---------------------------------------------------------------------------
# Health & Monitoring
# ---------------------------------------------------------------------------
check-certs: ## Check TLS certificate expiry
	sudo bash check-certs.sh

health-check: ## Check all container + endpoint health
	bash check-health.sh

health: ## Check all container health
	@$(COMPOSE) ps --format "table {{.Name}}\t{{.Status}}\t{{.Health}}"

# ---------------------------------------------------------------------------
# Authentik
# ---------------------------------------------------------------------------
blueprints: ## Apply Authentik default blueprints
	@for bp in \
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
		system/providers-rac.yaml; do \
		echo "  Applying: $$bp"; \
		docker exec authentik-server ak apply_blueprint "$$bp" 2>/dev/null || true; \
	done

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
backup: ## Run Restic backup now
	bash backup-restic.sh

backup-check: ## Verify Restic repo integrity
	RESTIC_REPOSITORY=/opt/backups/authentik/restic-repo \
	RESTIC_PASSWORD_FILE=/opt/backups/authentik/.restic-password \
	restic check

backup-snapshots: ## List Restic snapshots
	RESTIC_REPOSITORY=/opt/backups/authentik/restic-repo \
	RESTIC_PASSWORD_FILE=/opt/backups/authentik/.restic-password \
	restic snapshots

# ---------------------------------------------------------------------------
# Debug Shells
# ---------------------------------------------------------------------------
shell-db: ## Open psql shell
	docker exec -it authentik-postgresql psql -U authentik

shell-redis: ## Open redis-cli shell
	docker exec -it authentik-redis redis-cli -a "$$(grep REDIS_PASS .env | cut -d= -f2)"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
clean: ## Remove all containers, volumes, and generated configs
	$(COMPOSE) down -v
	rm -f traefik/dynamic/authentik.yml smtp/main.cf smtp/sender_rewrite
	rm -rf data/ traefik/logs/
	@echo "Cleaned. Run 'make setup' to redeploy."

firewall: ## Apply UFW firewall rules (80, 443, 22222 only)
	bash firewall.sh
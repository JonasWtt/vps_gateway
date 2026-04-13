# Authentik + Traefik — Production Deployment

Hardened, production-grade Authentik SSO with Traefik reverse proxy, PostgreSQL, Redis, Postfix SMTP relay, and encrypted Restic backups.

## Architecture

```
Internet → Traefik (80/443) → Authentik (internal:9000)
                                  ├── PostgreSQL (internal:5432)
                                  ├── Redis (internal:6379)
                                  └── Postfix SMTP relay → IONOS (587)
```

- **No ports exposed** except 80/443 (Traefik)
- All services on internal Docker networks (`authentik`, `traefik`)
- `cap_drop: ALL` on every container with minimal `cap_add`
- `read_only: true` with tmpfs where needed
- `no-new-privileges` enforced at daemon level
- Encrypted Restic backups (daily at 02:00)

## Quick Start

```bash
# 1. Clone the repo
git clone <your-repo-url> authentik-traefik
cd authentik-traefik

# 2. Copy and edit the environment template
cp .env.example .env
nano .env  # Fill in: secrets, domains, SMTP credentials

# 3. Run setup
./setup.sh
```

The setup script will:
- Generate all secrets into `.env`
- Render config templates from `.env` values
- Validate `SSH_PORT` — **wrong value = lockout!**
- Create data directories with proper permissions
- Build the SMTP SASL password database
- Initialize the Restic backup repository
- Configure the Docker daemon for hardening
- Configure UFW firewall (80, 443, SSH_PORT only)
- Install fail2ban Authentik jail
- Install Traefik log rotation
- Pull images and start all containers
- Apply Authentik default blueprints
- Install daily backup and cert-check cron jobs

After setup, go to `https://auth.yourdomain.com/if/flow/initial-setup/` to create your admin account.

## Configuration Files

| File | Purpose | Source |
|------|---------|--------|
| `.env` | Secrets and config | **gitignored** — created from `.env.example` |
| `docker-compose.yml` | Full stack definition with hardening | tracked |
| `traefik/dynamic/authentik.yml.template` | Traefik routes, middlewares, security headers | tracked |
| `smtp/main.cf.template` | Postfix relay config | tracked |
| `smtp/sender_rewrite.template` | Sender rewriting map | tracked |
| `smtp/sasl_passwd.example` | SMTP auth template | tracked |
| `backup-restic.sh` | Encrypted backup script | tracked |
| `check-certs.sh` | TLS cert expiry monitor | tracked |
| `check-health.sh` | Container + endpoint health monitor | tracked |
| `render.sh` | Template rendering script | tracked |
| `setup.sh` | One-shot deployment script | tracked |

All `*.template` files use `{{PLACEHOLDER}}` syntax. `setup.sh` renders them to final config files by substituting values from `.env`. The rendered files (`authentik.yml`, `main.cf`, `sender_rewrite`) are gitignored.

To re-render after changing `.env`:
```bash
make render    # or: ./setup.sh
```

## Health Checks & Container Recovery

Every container has a healthcheck that Docker runs periodically:

| Service | Check | Interval | Retries | Start Period |
|---------|-------|----------|---------|-------------|
| PostgreSQL | `pg_isready` | 30s | 5 | 20s |
| Redis | `redis-cli ping` | 30s | 5 | 20s |
| Authentik server | HTTP `/-/health/live/` | 30s | 5 | 90s |
| Authentik worker | `/proc/1/status` read | 60s | 5 | 120s |
| Postfix | `postfix status` | 30s | 3 | 15s |

**What happens when a container becomes unhealthy:**

1. **Docker marks it `unhealthy`** after `retries` consecutive failures
2. **`restart: unless-stopped`** — Docker auto-restarts the container
3. **`depends_on: condition: service_healthy`** — dependent services won't start until their dependencies are healthy (prevents cascading failures on boot)
4. **`check-health.sh`** — the monitoring script detects unhealthy containers and exits non-zero (suitable for cron alerting)
5. **fail2ban** — the Authentik jail monitors Traefik access logs and bans IPs with repeated 401/403 responses

**What Docker does NOT do automatically:**
- Docker won't restart dependent containers when a dependency becomes unhealthy after startup
- Docker won't notify you — that's what `check-health.sh` + cron is for
- `restart: unless-stopped` means Docker won't restart a container you manually stopped

## Makefile Targets

```bash
make help             # Show all targets
make setup            # Full one-shot setup
make render           # Re-render config templates from .env
make up               # Start containers
make down             # Stop containers
make ps               # Container status
make logs SVC=traefik # Tail specific service logs
make health           # Show container health table
make health-check     # Run full health check script
make check-certs      # Check TLS cert expiry
make backup           # Run Restic backup now
make backup-check     # Verify backup integrity
make backup-snapshots # List backup snapshots
make blueprints       # Apply Authentik blueprints
make shell-db         # Open psql shell
make shell-redis      # Open redis-cli shell
make clean            # Remove containers, volumes, generated configs
```

## SMTP Relay

Outbound email goes through your SMTP provider (default: IONOS). No port 25 needed.

1. Copy `smtp/sasl_passwd.example` to `smtp/sasl_passwd`
2. Fill in your credentials
3. Run `sudo postmap smtp/sasl_passwd` (or let `setup.sh` handle it)
4. The `main.cf.template` is rendered from `.env` — edit `.env` and re-render

## Backups

Backups run daily at 02:00 via cron, using Restic with AES-256 encryption.

```bash
# Manual backup
sg backup-access -c './backup-restic.sh'

# List snapshots
make backup-snapshots

# Verify integrity
make backup-check

# Restore latest
restic restore latest --repo /opt/backups/authentik/restic-repo \
    --password-file /opt/backups/authentik/.restic-password --target /tmp/restore
```

Retention: 7 daily, 4 weekly, 12 monthly, 3 yearly. Weekly integrity check on Sundays.

**⚠️ Offsite backup is not configured yet.** Add a Restic remote target for disaster recovery.

## DNS Records

For email deliverability, add these records to your domain:

```dns
SPF:    grenzweg.site.  IN TXT  "v=spf1 include:ionos.com ~all"
DMARC:  _dmarc.grenzweg.site.  IN TXT  "v=DMARC1; p=reject; rua=mailto:noreply@grenzweg.site"
```

DKIM is handled by IONOS automatically for their relay.

## Security Checklist

- [x] All containers `cap_drop: ALL` with minimal `cap_add`
- [x] `read_only: true` with tmpfs for writable paths
- [x] `no-new-privileges` at daemon level
- [x] No database/Redis ports exposed publicly
- [x] TLS via Let's Encrypt with HSTS preload
- [x] Security headers (X-Frame-Options, nosniff, permissions-policy, referrer-policy)
- [x] HTTP→HTTPS redirect (308)
- [x] Traefik dashboard behind basic auth + IP allowlist
- [x] SMTP relay (no inbound port 25)
- [x] Encrypted Restic backups
- [x] Docker log rotation (10m, 3 files)
- [x] Traefik access log rotation (7 days, 50M max)
- [x] fail2ban with 5 jails (sshd, sshd-root, recidive, traefik-scan, authentik)
- [x] UFW firewall: only 80, 443, and SSH_PORT (configured in .env)
- [x] Secrets in `.env` (chmod 640, group-readable for backup script)
- [x] Dashboard auth in `.env` (not in tracked config)
- [x] Domain references centralized via .env templates
- [x] TLS cert expiry monitoring (daily cron at 08:00)
- [x] Container health monitoring script
- [ ] SPF/DKIM/DMARC DNS records
- [ ] Offsite backup target
- [ ] Dashboard IP allowlist updated with your IPs

## Updating

```bash
# Pull new images
docker compose pull

# Recreate changed containers
docker compose up -d

# Apply new blueprints if needed
make blueprints
```

## License

Personal deployment configuration. No warranty implied.
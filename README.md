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

## Server Prerequisites

These are system-level security prerequisites that should be in place **before** running `setup.sh`. They are outside the scope of the deployment itself but critical for a secure production environment.

### Prerequisite Checker

A prerequisite validation script is included:

```bash
bash check-prerequisites.sh
```

This checks for: required commands, Docker daemon config, user permissions, network connectivity, UFW status, fail2ban, AppArmor, kernel security parameters, SSH configuration, DNS records, and backup tools. It exits non-zero if any hard requirement is missing and prints warnings for recommended hardening.

### Required Prerequisites

| Prerequisite | Purpose | How to verify |
|---|---|---|
| Docker Engine + Compose v2 | Container runtime | `docker compose version` |
| User in `docker` group | Non-root container management | `groups $(whoami) \| grep docker` |
| `openssl`, `htpasswd`, `curl`, `git`, `jq` | Setup tooling | `which openssl htpasswd curl git jq` |
| `/etc/docker/daemon.json` | Docker hardening (no-new-privileges, log rotation, live-restore) | `cat /etc/docker/daemon.json` |
| UFW firewall active | Only ports 80, 443, SSH_PORT exposed | `sudo ufw status` |
| fail2ban running | Brute-force protection for SSH and Authentik | `sudo systemctl status fail2ban` |
| unattended-upgrades | Automatic security patches | `sudo systemctl status unattended-upgrades` |
| AppArmor enabled | Container isolation (Docker relies on this) | `sudo aa-status` |
| SSH publickey-only | No password authentication | `sudo sshd -T \| grep passwordauthentication` |
| SSH on non-default port | Reduce scan noise | `grep '^Port' /etc/ssh/sshd_config` |

### Recommended Kernel Hardening (sysctl)

These kernel parameters strengthen the server against network and privilege escalation attacks. Apply them via `/etc/sysctl.d/99-hardening.conf`:

```ini
# Address Space Layout Randomization
kernel.randomize_va_space = 2

# Restrict kernel pointer access
kernel.kptr_restrict = 1

# Restrict dmesg (kernel log) to root
kernel.dmesg_restrict = 1

# No SUID core dumps
fs.suid_dumpable = 0

# Network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_rfc1337 = 1

# BPF JIT hardening (mitigates BPF-based attacks)
net.core.bpf_jit_harden = 2

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
```

Apply with: `sudo sysctl --system`

### Current System Audit Findings

The following items were identified on this server as potential hardening opportunities (**not changed yet** — listed for review):

| # | Finding | Risk | Current State | Recommendation |
|---|---|---|---|---|
| 1 | `fs.suid_dumpable=2` | Low — allows SUID core dumps (root-readable only) | 2 (softened) | Set to 0 for strictest policy |
| 2 | `kernel.dmesg_restrict=0` | Medium — any user can read kernel ring buffer | 0 (unrestricted) | Set to 1 |
| 3 | `kernel.kptr_restrict=0` | Medium — kernel addresses visible via /proc/kallsyms | 0 (unrestricted) | Set to 1 |
| 4 | `net.core.bpf_jit_harden=0` | Low — BPF JIT not hardened | 0 (off) | Set to 2 |
| 5 | `net.ipv4.icmp_echo_ignore_broadcasts=0` | Low — responds to ICMP broadcast | 0 (responds) | Set to 1 |
| 6 | `net.ipv4.tcp_rfc1337=0` | Low — TIME_WAIT assassination not mitigated | 0 (off) | Set to 1 |
| 7 | No auditd/framework | Medium — no system call auditing | not installed | Install `auditd` for compliance |
| 8 | `/dev/shm` is world-writable (default) | Low — shared memory abuse potential | 1777 | Consider `nodev,noexec,nosuid` mount options |
| 9 | No USB/module blacklist | Low — unused kernel modules loaded | default | Blacklist unused modules |
| 10 | `PermitRootLogin yes` in sshd_config | **High** — root login permitted | yes | Set to `prohibit-password` or `no` |

### Additional Security Hardening Recommendations (from research)

These go beyond the current setup and are worth considering:

**Server-level:**
- **auditd** — System call auditing for post-incident forensics (`sudo apt install auditd`)
- **AIDE** — File integrity monitoring to detect unauthorized changes (`sudo apt install aide`)
- **sysctl hardening** — Apply the full `/etc/sysctl.d/99-hardening.conf` above
- **/dev/shm mount options** — Add `nodev,noexec,nosuid` to `/dev/shm` in `/etc/fstab`
- **Cgroup v2 resources** — Set memory+cpu limits per container (partially done via docker-compose `deploy.resources`)
- **logrotate for journald** — Limit journal size: `SystemMaxFileSize=50M`, `SystemMaxFiles=10` in `/etc/systemd/journald.conf`

**Authentik-specific (from official docs):**
- **Disable default flows** after initial setup — the "default-authentication-flow" and "default-enrollment-flow" are broad; create custom flows with tighter controls
- **Enable token lengthening** — increase default token lifetime if needed, or decrease for higher security
- **Rate limit login attempts** — Authentik has built-in rate limiting in flows; verify it's enabled
- **Email verification** — require email verification for enrollment flows
- **MFA enforcement** — require TOTP/WebAuthn for all admin accounts
- **Separate admin tenant** — use a dedicated tenant for admin access with stricter policies
- **Review outposts** — disable any unused outposts to reduce attack surface

**Traefik-specific (from official docs):**
- **Disable API/Dashboard in production** — `api.insecure=false` is already set ✅
- **Use TLS 1.3 only** — add `minVersion: VersionTLS13` to the TLS config if all clients support it
- **Enable forward authentication** — use Authentik as a forward auth provider for other services behind Traefik
- **Restrict entrypoints** — the web entrypoint only needs to accept HTTP (for ACME challenges) and HTTPS; no other protocols
- **Observability** — add Traefik metrics (Prometheus) for anomaly detection

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

## File Inventory

| File | Purpose | Tracked |
|------|---------|---------|
| `docker-compose.yml` | Full stack definition with hardening | ✅ |
| `setup.sh` | One-shot deployment script | ✅ |
| `render.sh` | Template rendering script | ✅ |
| `check-prerequisites.sh` | Prerequisite validation | ✅ |
| `check-health.sh` | Container + endpoint health monitor | ✅ |
| `check-certs.sh` | TLS cert expiry monitor | ✅ |
| `backup-restic.sh` | Encrypted backup script | ✅ |
| `firewall.sh` | UFW firewall rules | ✅ |
| `Makefile` | Common operations | ✅ |
| `.env.example` | Environment template | ✅ |
| `.gitignore` | Excludes secrets and rendered files | ✅ |
| `.githooks/pre-commit` | Secret leak prevention | ✅ |
| `traefik/dynamic/authentik.yml.template` | Traefik routes + middlewares | ✅ |
| `smtp/main.cf.template` | Postfix relay config | ✅ |
| `smtp/sender_rewrite.template` | Sender rewriting map | ✅ |
| `smtp/sasl_passwd.example` | SMTP auth template | ✅ |
| `fail2ban/filter-authentik.conf` | Authentik log filter | ✅ |
| `fail2ban/jail-authentik.conf` | Authentik jail config | ✅ |
| `logrotate/traefik` | Traefik log rotation | ✅ |
| `README.md` | This file | ✅ |
| `.env` | Secrets and config | ❌ gitignored |
| `smtp/sasl_passwd` | SMTP credentials | ❌ gitignored |
| `smtp/sasl_passwd.db` | Compiled SASL map | ❌ gitignored |
| `traefik/dynamic/authentik.yml` | Rendered Traefik config | ❌ gitignored |
| `smtp/main.cf` | Rendered Postfix config | ❌ gitignored |
| `smtp/sender_rewrite` | Rendered sender map | ❌ gitignored |
| `data/` | Persistent data (DB, certs, etc.) | ❌ gitignored |
| `traefik/logs/` | Traefik access logs | ❌ gitignored |

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
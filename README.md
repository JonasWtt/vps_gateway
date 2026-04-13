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
vim .env  # Fill in: secrets, domains, SMTP credentials

# 3. Run setup
./setup.sh
```

The setup script will:
- Generate all secrets into `.env`
- Create data directories with proper permissions
- Build the SMTP SASL password database
- Initialize the Restic backup repository
- Configure the Docker daemon for hardening
- Pull images and start all containers
- Apply Authentik default blueprints
- Install the daily backup cron job

After setup, go to `https://auth.yourdomain.com/if/flow/initial-setup/` to create your admin account.

## Configuration Files

| File | Purpose |
|------|---------|
| `.env` | Secrets and config (gitignored) |
| `.env.example` | Template with all variables documented |
| `docker-compose.yml` | Full stack definition with hardening |
| `traefik/dynamic/authentik.yml` | Traefik routes, middlewares, security headers |
| `smtp/main.cf` | Postfix relay config (customizable for your provider) |
| `smtp/sasl_passwd.example` | SMTP auth template |
| `smtp/sender_rewrite` | Rewrites all outgoing mail to a single address |
| `backup-restic.sh` | Encrypted, deduplicated backup script |

## SMTP Relay

Outbound email goes through your SMTP provider (default: IONOS). No port 25 needed.

1. Copy `smtp/sasl_passwd.example` to `smtp/sasl_passwd`
2. Fill in your credentials
3. Run `sudo postmap smtp/sasl_passwd`
4. Update `smtp/main.cf` with your relay host and domain
5. Restart: `docker compose restart smtp`

## Backups

Backups run daily at 02:00 via cron, using Restic with AES-256 encryption.

```bash
# Manual backup
sg backup-access -c './backup-restic.sh'

# List snapshots
restic snapshots --repo /opt/backups/authentik/restic-repo --password-file /opt/backups/authentik/.restic-password

# Restore latest
restic restore latest --repo /opt/backups/authentik/restic-repo --password-file /opt/backups/authentik/.restic-password --target /tmp/restore
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
- [x] fail2ban with 4 jails
- [x] Secrets in `.env` (chmod 600, root-owned)
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
docker exec authentik-server ak apply_blueprint system/bootstrap.yaml
```

## License

Personal deployment configuration. No warranty implied.
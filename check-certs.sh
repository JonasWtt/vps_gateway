#!/bin/bash
# =============================================================================
# TLS Certificate Expiry Check
# Warns if any Let's Encrypt cert expires within 7 days.
# Run via cron (daily) or manually.
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="${DEPLOY_DIR}/data/certs"
ALERT_DAYS=7
ACME_JSON="${CERT_DIR}/acme.json"

if [ ! -r "${ACME_JSON}" ]; then
    echo "ERROR: Cannot read ${ACME_JSON} (try running as root or with sudo)"
    exit 1
fi

# Extract all certificate notAfter dates from acme.json and check expiry
EXPIRING=0
NOW_EPOCH=$(date +%s)
ALERT_SECS=$((ALERT_DAYS * 86400))

# Use python to parse the JSON and openssl to check dates
sudo python3 -c "
import json, base64, subprocess, sys
from datetime import datetime, timezone

with open('${ACME_JSON}') as f:
    data = json.load(f)

resolver = 'letsencrypt'
if resolver not in data:
    print('ERROR: No letsencrypt resolver in acme.json')
    sys.exit(1)

certs = data[resolver].get('Certificates', [])
if not certs:
    print('ERROR: No certificates found')
    sys.exit(1)

now = datetime.now(timezone.utc)
alert_days = ${ALERT_DAYS}
expiring = []
ok = []

for cert in certs:
    domain = cert.get('domain', {}).get('main', 'unknown')
    cert_b64 = cert.get('certificate', '')
    if not cert_b64:
        continue
    cert_b64_padded = cert_b64 + '=' * (4 - len(cert_b64) % 4)
    try:
        cert_der = base64.b64decode(cert_b64_padded)
    except Exception:
        continue
    proc = subprocess.run(
        ['openssl', 'x509', '-inform', 'der', '-noout', '-enddate'],
        input=cert_der, capture_output=True
    )
    if proc.returncode != 0:
        continue
    date_str = proc.stdout.decode().strip().replace('notAfter=', '')
    try:
        expiry = datetime.strptime(date_str, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    days_left = (expiry - now).days
    line = f'  {domain}: {days_left} days remaining (expires {expiry.strftime(\"%Y-%m-%d\")})'
    if days_left <= alert_days:
        expiring.append(line)
    else:
        ok.append(line)

if expiring:
    print('⚠️  WARNING: TLS certificates expiring soon!')
    for e in expiring:
        print(e)
    sys.exit(1)
else:
    print('✅ All TLS certificates are healthy')
    for o in ok:
        print(o)
"

# Add cron job for daily cert check (idempotent)
CRON_LINE="0 8 * * * ${DEPLOY_DIR}/check-certs.sh"
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
if echo "${CURRENT_CRON}" | grep -q "check-certs"; then
    : # already installed
else
    echo "${CURRENT_CRON}" | cat - <(echo "${CRON_LINE}") | crontab -
fi
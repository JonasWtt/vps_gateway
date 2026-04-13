#!/usr/bin/env bash
# =============================================================================
# check-prerequisites.sh — Verify all prerequisites before deployment
# =============================================================================
# Run this BEFORE setup.sh to catch missing dependencies early.
# Exits 0 if all pass, exits 1 with a report of what's missing/wrong.
# =============================================================================

set -euo pipefail

PASS=0
FAIL=0
WARN=0

green()  { printf "\033[0;32m  ✔ %s\033[0m\n" "$1"; }
red()    { printf "\033[0;31m  ✘ %s\033[0m\n" "$1"; }
yellow() { printf "\033[0;33m  ⚠ %s\033[0m\n" "$1"; }
header() { printf "\n\033[1m%s\033[0m\n" "$1"; }

check_cmd() {
    if command -v "$1" &>/dev/null; then
        green "$1 is installed"
        PASS=$((PASS+1))
        return 0
    else
        red "$1 is NOT installed — $2"
        FAIL=$((FAIL+1))
        return 1
    fi
}

check_file() {
    if [ -f "$1" ]; then
        green "$1 exists"
        PASS=$((PASS+1))
        return 0
    else
        red "$1 is MISSING — $2"
        FAIL=$((FAIL+1))
        return 1
    fi
}

check_bool() {
    # $1: description, $2: test command, $3: pass message, $4: fail message
    local desc="$1" test_cmd="$2" pass_msg="$3" fail_msg="$4"
    if eval "$test_cmd" &>/dev/null; then
        green "$desc: $pass_msg"
        PASS=$((PASS+1))
    else
        red "$desc: $fail_msg"
        FAIL=$((FAIL+1))
    fi
}

check_warn() {
    if eval "$2" &>/dev/null; then
        green "$1: OK"
        PASS=$((PASS+1))
    else
        yellow "$1: $3"
        WARN=$((WARN+1))
    fi
}

# =========================================================================
header "1. Operating System"
# =========================================================================
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "$ID" == "ubuntu" && "$VERSION_ID" == 2* ]]; then
        green "OS: $PRETTY_NAME (supported)"
        PASS=$((PASS+1))
    else
        yellow "OS: $PRETTY_NAME — only Ubuntu 24.04+ is tested"
        WARN=$((WARN+1))
    fi
else
    red "Cannot determine OS (/etc/os-release missing)"
    FAIL=$((FAIL+1))
fi

check_bool "Kernel version >= 5.15" \
    "uname -r | awk -F. '{exit !(\$1>5 || (\$1==5 && \$2>=15))}'" \
    "$(uname -r)" \
    "Current kernel $(uname -r) may be too old"

# =========================================================================
header "2. Required Commands"
# =========================================================================
check_cmd docker      "Install: https://docs.docker.com/engine/install/"
# docker compose is a subcommand, not a separate binary
if docker compose version &>/dev/null; then
    green "docker compose is available"
    PASS=$((PASS+1))
else
    red "docker compose is NOT available - Install: sudo apt install docker-compose-plugin"
    FAIL=$((FAIL+1))
fi
check_cmd openssl     "Install: sudo apt install openssl"
check_cmd htpasswd    "Install: sudo apt install apache2-utils"
check_cmd curl        "Install: sudo apt install curl"
check_cmd git         "Install: sudo apt install git"
check_cmd crontab     "Install: sudo apt install cron"
check_cmd sed         "Install: sudo apt install sed"
check_cmd grep        "Install: sudo apt install grep"
check_cmd jq          "Optional but recommended for check-certs.sh: sudo apt install jq"

# =========================================================================
header "3. Docker Daemon"
# =========================================================================
if sudo docker info &>/dev/null; then
    green "Docker daemon is running"
    PASS=$((PASS+1))
else
    red "Docker daemon is NOT running — sudo systemctl start docker"
    FAIL=$((FAIL+1))
fi

check_file "/etc/docker/daemon.json" "Docker daemon config missing — see setup.sh or README"

# =========================================================================
header "4. User Permissions"
# =========================================================================
if groups "$(whoami)" 2>/dev/null | grep -qw docker; then
    green "Current user is in the 'docker' group"
    PASS=$((PASS+1))
else
    red "Current user is NOT in the 'docker' group — sudo usermod -aG docker \$USER"
    FAIL=$((FAIL+1))
fi

if sudo -n true 2>/dev/null; then
    green "Current user has sudo access"
    PASS=$((PASS+1))
else
    yellow "Current user may not have passwordless sudo — some checks may fail"
    WARN=$((WARN+1))
fi

# =========================================================================
header "5. Network & DNS"
# =========================================================================
check_bool "Outbound HTTPS works" \
    "curl -sf --max-time 5 https://letsencrypt.org > /dev/null" \
    "reachable" \
    "cannot reach the internet — check firewall/outbound rules"

check_bool "DNS resolution works" \
    "dig +short example.org | grep -q . || nslookup example.org | grep -q 'Address'" \
    "resolving" \
    "DNS is not working — check /etc/resolv.conf"

check_warn "Port 80 is free" \
    "sudo ss -tlnp | grep -v docker | grep -qv ':80 '" \
    "Port 80 is in use by a non-Docker process — may conflict with Traefik"

check_warn "Port 443 is free" \
    "sudo ss -tlnp | grep -v docker | grep -qv ':443 '" \
    "Port 443 is in use by a non-Docker process — may conflict with Traefik"

# =========================================================================
header "6. Firewall (UFW)"
# =========================================================================
if command -v ufw &>/dev/null || [ -x /usr/sbin/ufw ]; then
    if sudo ufw status 2>/dev/null | grep -qi active; then
        green "UFW firewall is active"
        PASS=$((PASS+1))
    else
        yellow "UFW is installed but NOT active — sudo ufw enable"
        WARN=$((WARN+1))
    fi

    if sudo ufw status 2>/dev/null | grep -qE '80/tcp.*(ALLOW|ALLOW)'; then
        green "UFW allows port 80/tcp"
        PASS=$((PASS+1))
    else
        yellow "UFW does not allow port 80/tcp — Let's Encrypt HTTP challenge needs this"
        WARN=$((WARN+1))
    fi

    if sudo ufw status 2>/dev/null | grep -qE '443/tcp.*(ALLOW|ALLOW)'; then
        green "UFW allows port 443/tcp"
        PASS=$((PASS+1))
    else
        yellow "UFW does not allow port 443/tcp — HTTPS needs this"
        WARN=$((WARN+1))
    fi
else
    red "UFW is not installed — sudo apt install ufw"
    FAIL=$((FAIL+1))
fi

# =========================================================================
header "7. Security Services"
# =========================================================================
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    green "fail2ban is running"
    PASS=$((PASS+1))
else
    yellow "fail2ban is NOT running — sudo systemctl enable --now fail2ban"
    WARN=$((WARN+1))
fi

if systemctl is-active --quiet unattended-upgrades 2>/dev/null || \
   dpkg -l unattended-upgrades &>/dev/null; then
    green "unattended-upgrades is configured"
    PASS=$((PASS+1))
else
    yellow "unattended-upgrades is not configured — security updates may not auto-apply"
    WARN=$((WARN+1))
fi

check_bool "AppArmor is enabled" \
    "sudo aa-status 2>/dev/null | grep -q 'profiles are loaded'" \
    "active" \
    "not active — Docker relies on AppArmor for container isolation"

# =========================================================================
header "8. Kernel Security Parameters"
# =========================================================================
check_bool "ASLR enabled (kernel.randomize_va_space=2)" \
    "sudo sysctl -n kernel.randomize_va_space 2>/dev/null | grep -q '^2$'" \
    "enabled" \
    "disabled or weak — set kernel.randomize_va_space=2 in /etc/sysctl.d/"

check_bool "dmesg restricted (kernel.dmesg_restrict=1)" \
    "sudo sysctl -n kernel.dmesg_restrict 2>/dev/null | grep -q '^1$'" \
    "restricted" \
    "unrestricted — users can read kernel ring buffer (info leak)"

check_bool "kptr_restrict enabled (kernel.kptr_restrict=1)" \
    "sudo sysctl -n kernel.kptr_restrict 2>/dev/null | grep -q '^1$'" \
    "restricted" \
    "unrestricted — /proc/kallsyms exposes kernel addresses"

check_warn "SUID dumps disabled (fs.suid_dumpable=0)" \
    "sudo sysctl -n fs.suid_dumpable 2>/dev/null | grep -q '^0$'" \
    "set fs.suid_dumpable=0 (current: $(sudo sysctl -n fs.suid_dumpable 2>/dev/null))"

check_bool "ICMP redirects disabled" \
    "sudo sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null | grep -q '^0$'" \
    "disabled" \
    "enabled — set net.ipv4.conf.all.accept_redirects=0"

check_bool "IP source routing disabled" \
    "sudo sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null | grep -q '^0$'" \
    "disabled" \
    "enabled — set net.ipv4.conf.all.accept_source_route=0"

check_bool "TCP SYN cookies enabled" \
    "sudo sysctl -n net.ipv4.tcp_syncookies 2>/dev/null | grep -q '^1$'" \
    "enabled" \
    "disabled — vulnerable to SYN flood, set net.ipv4.tcp_syncookies=1"

check_warn "BPF JIT hardened (net.core.bpf_jit_harden=2)" \
    "sudo sysctl -n net.core.bpf_jit_harden 2>/dev/null | grep -q '^2$'" \
    "set net.core.bpf_jit_harden=2 (current: $(sudo sysctl -n net.core.bpf_jit_harden 2>/dev/null))"

# =========================================================================
header "9. SSH (informational — we do not modify sshd config)"
# =========================================================================
if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
    green "SSH daemon is running"
    PASS=$((PASS+1))
else
    yellow "SSH daemon is not running — you may not be able to remote in"
    WARN=$((WARN+1))
fi

if sudo sshd -T 2>/dev/null | grep -q 'passwordauthentication yes'; then
    yellow "SSH allows password auth — consider publickey-only for production"
    WARN=$((WARN+1))
else
    green "SSH does not allow password auth (or sshd config unavailable)"
    PASS=$((PASS+1))
fi

# =========================================================================
header "10. Deployment Directory"
# =========================================================================
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
check_file "${DEPLOY_DIR}/docker-compose.yml" "Run from the deployment directory"
check_file "${DEPLOY_DIR}/.env" "Create from .env.example and fill in values"
check_file "${DEPLOY_DIR}/setup.sh" "Main setup script missing"

if [ -f "${DEPLOY_DIR}/.env" ]; then
    # Check for placeholder values
    if grep -q 'CHANGE_ME\|you@example\|example\.com' "${DEPLOY_DIR}/.env" 2>/dev/null; then
        red ".env still contains placeholder values — edit before deploying"
        FAIL=$((FAIL+1))
    else
        green ".env has no placeholder values"
        PASS=$((PASS+1))
    fi

    # Check SSH_PORT is set
    if grep -qE '^SSH_PORT=[0-9]+' "${DEPLOY_DIR}/.env" 2>/dev/null; then
        green ".env has SSH_PORT set"
        PASS=$((PASS+1))
    else
        red ".env missing SSH_PORT — firewall.sh needs it (lockout risk!)"
        FAIL=$((FAIL+1))
    fi
fi

# =========================================================================
header "11. DNS Records (external check)"
# =========================================================================
if [ -f "${DEPLOY_DIR}/.env" ]; then
    AUTHENTIK_DOMAIN=$(grep '^AUTHENTIK_DOMAIN=' "${DEPLOY_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d ' ')
    TRAEFIK_DOMAIN=$(grep '^TRAEFIK_DOMAIN=' "${DEPLOY_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d ' ')
    SERVER_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || echo "UNKNOWN")

    for domain in "$AUTHENTIK_DOMAIN" "$TRAEFIK_DOMAIN"; do
        if [ -n "$domain" ] && [ "$domain" != "auth.example.com" ] && [ "$domain" != "traefik.example.com" ]; then
            resolved=$(dig +short "$domain" A 2>/dev/null | head -1)
            if [ -n "$resolved" ]; then
                if [ "$resolved" = "$SERVER_IP" ] || [ "$SERVER_IP" = "UNKNOWN" ]; then
                    green "$domain → $resolved (DNS OK)"
                    PASS=$((PASS+1))
                else
                    yellow "$domain → $resolved but server IP is $SERVER_IP (DNS mismatch?)"
                    WARN=$((WARN+1))
                fi
            else
                red "$domain does not resolve — create DNS A record pointing to $SERVER_IP"
                FAIL=$((FAIL+1))
            fi
        fi
    done
fi

# =========================================================================
header "12. Backup Infrastructure"
# =========================================================================
check_cmd restic "Install: sudo apt install restic"

# =========================================================================
# Summary
# =========================================================================
header "SUMMARY"
printf "  ✔ Passed: %d\n  ✘ Failed: %d\n  ⚠ Warnings: %d\n\n" "$PASS" "$FAIL" "$WARN"

if [ "$FAIL" -gt 0 ]; then
    red "Prerequisites NOT met — fix failures above before running setup.sh"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    yellow "Prerequisites met with warnings — review above before deploying"
    exit 0
else
    green "All prerequisites met — ready to deploy!"
    exit 0
fi
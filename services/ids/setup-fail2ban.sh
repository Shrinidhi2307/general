#!/bin/bash
# =============================================================================
# Configure Fail2ban on VM1 (Stockholm GW) and VM4 (London GW)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/ids/setup-fail2ban.sh
#
# Prerequisites: VM1 and VM4 provisioned (fail2ban package already installed)
#
# What this script does:
#   1. Configures SSH brute-force jail on both gateways
#   2. Configures Nginx auth failure jail on VM1 (protects mTLS endpoints)
#   3. Configures IPsec/StrongSwan jail on both gateways
#   4. Enables and restarts fail2ban
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Configuring Fail2ban on ACME Gateways"
echo "====================================================="

# ─────────────────────────────────────────────────────────
# VM1 (Stockholm Gateway) — SSH + Nginx + StrongSwan jails
# ─────────────────────────────────────────────────────────
echo ">>> Configuring Fail2ban on VM1 (Stockholm Gateway)..."

vagrant ssh vm1-gw -- sudo bash -s << 'F2B_VM1_EOF'
set -euo pipefail

# ── Jail configuration ──
cat > /etc/fail2ban/jail.d/acme.conf << 'JAIL_EOF'
# =============================================================================
# ACME Fail2ban Jails — Stockholm Gateway (VM1)
# =============================================================================

[DEFAULT]
# Ban for 10 minutes after 5 failures within 10 minutes
bantime  = 600
findtime = 600
maxretry = 5
# Use UFW for banning (integrates with existing firewall)
banaction = ufw

[sshd]
enabled  = true
port     = ssh
filter   = sshd[mode=aggressive]
logpath  = /var/log/auth.log
maxretry = 3

[strongswan]
enabled  = true
port     = 500,4500
filter   = strongswan
logpath  = /var/log/syslog
maxretry = 5
JAIL_EOF

# ── StrongSwan filter (detect IKE auth failures) ──
cat > /etc/fail2ban/filter.d/strongswan.conf << 'FILTER_EOF'
# Fail2ban filter for StrongSwan IKEv2 authentication failures
[Definition]
failregex = ^.*charon.*<HOST>.*IKE_AUTH.*failed.*$
            ^.*charon.*<HOST>.*authentication.*failed.*$
            ^.*charon.*received AUTH_FAILED notify.*<HOST>.*$
ignoreregex =
FILTER_EOF

# Ensure fail2ban is enabled and restart
systemctl enable fail2ban
systemctl restart fail2ban

# Wait for socket to become ready
sleep 2

echo ">>> Fail2ban active on VM1. Jails:"
fail2ban-client status

F2B_VM1_EOF

# ─────────────────────────────────────────────────────────
# VM4 (London Gateway) — SSH + StrongSwan jails
# ─────────────────────────────────────────────────────────
echo ""
echo ">>> Configuring Fail2ban on VM4 (London Gateway)..."

vagrant ssh vm4-gw -- sudo bash -s << 'F2B_VM4_EOF'
set -euo pipefail

# ── Jail configuration ──
cat > /etc/fail2ban/jail.d/acme.conf << 'JAIL_EOF'
# =============================================================================
# ACME Fail2ban Jails — London Gateway (VM4)
# =============================================================================

[DEFAULT]
bantime  = 600
findtime = 600
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3

[strongswan]
enabled  = true
port     = 500,4500
filter   = strongswan
logpath  = /var/log/syslog
maxretry = 5
JAIL_EOF

# ── StrongSwan filter (same as VM1) ──
cat > /etc/fail2ban/filter.d/strongswan.conf << 'FILTER_EOF'
# Fail2ban filter for StrongSwan IKEv2 authentication failures
[Definition]
failregex = ^.*charon.*<HOST>.*IKE_AUTH.*failed.*$
            ^.*charon.*<HOST>.*authentication.*failed.*$
            ^.*charon.*received AUTH_FAILED notify.*<HOST>.*$
ignoreregex =
FILTER_EOF

# Ensure fail2ban is enabled and restart
systemctl enable fail2ban
systemctl restart fail2ban

# Wait for socket to become ready
sleep 2

echo ">>> Fail2ban active on VM4. Jails:"
fail2ban-client status

F2B_VM4_EOF

echo ""
echo "====================================================="
echo " Fail2ban setup complete on VM1 and VM4!"
echo ""
echo " Jails active:"
echo "   sshd       — bans after 3 failed SSH logins (10 min)"
echo "   strongswan — bans after 5 IKE auth failures (10 min)"
echo ""
echo " Useful commands (run inside VM):"
echo "   sudo fail2ban-client status"
echo "   sudo fail2ban-client status sshd"
echo "   sudo fail2ban-client set sshd unbanip <IP>"
echo "====================================================="

#!/bin/bash
# =============================================================================
# Deploy IPsec VPN Configuration to VM1 (Stockholm Gateway)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/deploy-vm1.sh
#
# This script:
#   1. Installs certificates (via install-certs-vm1.sh)
#   2. Copies ipsec.conf and ipsec.secrets to VM1
#   3. Adds NAT exclusion for tunnel traffic
#   4. Enables and restarts StrongSwan
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

echo "====================================================="
echo " Deploying IPsec VPN to VM1 (Stockholm Gateway)"
echo "====================================================="

# ── Step 1: Install certificates ──
echo ""
echo ">>> Step 1: Installing certificates..."
bash services/vpn/install-certs-vm1.sh

# ── Step 2: Deploy config files ──
echo ""
echo ">>> Step 2: Deploying IPsec configuration..."
vagrant ssh vm1-gw -- sudo bash -s << 'DEPLOY_EOF'
set -euo pipefail

SRC="/vagrant/services/vpn"

echo ">>> Copying ipsec.conf..."
cp "$SRC/ipsec.conf" /etc/ipsec.conf
chmod 644 /etc/ipsec.conf

echo ">>> Copying ipsec.secrets..."
cp "$SRC/ipsec.secrets" /etc/ipsec.secrets
chmod 600 /etc/ipsec.secrets

# ── Step 3: NAT exclusion for tunnel traffic ──
# Prevent masquerading traffic that should go through the IPsec tunnel
# (Stockholm internal → London VLAN 20)
echo ">>> Configuring NAT exclusion for tunnel traffic..."

BEFORE_RULES="/etc/ufw/before.rules"
if ! grep -q "IPsec NAT exclusion" "$BEFORE_RULES" 2>/dev/null; then
    # Insert exclusion rule BEFORE the masquerade rule in the *nat section
    sed -i '/-A POSTROUTING -s 10.0.1.0\/24 -o enp0s3 -j MASQUERADE/i \
# IPsec NAT exclusion — do not masquerade tunnel-bound traffic\
-A POSTROUTING -s 10.0.1.0/26 -d 10.0.1.128/26 -j ACCEPT\
-A POSTROUTING -s 10.0.1.240/28 -d 10.0.1.128/26 -j ACCEPT' "$BEFORE_RULES"
    echo "  NAT exclusion rules added."
else
    echo "  NAT exclusion rules already present."
fi

# ── Step 4: Enable and restart StrongSwan ──
echo ">>> Enabling StrongSwan..."
systemctl enable strongswan-starter 2>/dev/null || systemctl enable strongswan 2>/dev/null || true
systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true

# Reload UFW to pick up before.rules changes
ufw --force enable
ufw reload

echo ">>> Checking IPsec status..."
ipsec statusall || true

DEPLOY_EOF

echo ""
echo "====================================================="
echo " IPsec VPN Deployed to VM1!"
echo ""
echo " NOTE: The tunnel will not establish until:"
echo "   1. London's gateway is configured with matching config"
echo "   2. The 'right=' IP in ipsec.conf is updated from %any"
echo "      to London's actual router IP on the shared LAN"
echo ""
echo " Useful commands on VM1:"
echo "   sudo ipsec statusall    — Full status"
echo "   sudo ipsec up stockholm-london   — Initiate tunnel"
echo "   sudo ipsec restart      — Restart daemon"
echo "   sudo journalctl -u strongswan-starter -f  — Live logs"
echo "====================================================="

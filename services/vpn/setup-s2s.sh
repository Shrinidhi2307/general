#!/bin/bash
# =============================================================================
# Setup Site-to-Site IPsec VPN — London (VM4)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/setup-s2s.sh
#
# Prerequisites:
#   - VM4 is up:  vagrant up vm4-gw
#   - Certs exist: bash services/vpn/setup-ca.sh   (if not already done)
#
# This script:
#   1. Verifies certificates exist in services/vpn/certs/
#   2. Deploys certs + config to VM4 (London)
#   3. Adds NAT exclusions on VM4
#   4. Enables StrongSwan on VM4
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

CERT_DIR="services/vpn/certs"

echo "====================================================="
echo " Site-to-Site IPsec VPN Setup — London (VM4)"
echo "====================================================="

# ── Pre-flight: verify certs ──
echo ""
echo ">>> Pre-flight: checking certificates..."
MISSING=0
for f in ca.crt london.crt london.key; do
    if [ ! -f "$CERT_DIR/$f" ]; then
        echo "  MISSING: $CERT_DIR/$f"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "ERROR: Certificates not found. Run first:"
    echo "  bash services/vpn/setup-ca.sh"
    exit 1
fi
echo "  All certificates present."

# ═════════════════════════════════════════════════════════════
# London (VM4)
# ═════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────────────────"
echo " Deploying to VM4 (London Gateway)"
echo "─────────────────────────────────────────────────────"

vagrant ssh vm4-gw -- sudo bash -s << 'VM4_EOF'
set -euo pipefail

SRC="/vagrant/services/vpn"
CERT_SRC="$SRC/certs"
IPSEC_DIR="/etc/ipsec.d"

# ── WAN interface (acme-wan) ──
echo ">>> Configuring WAN interface..."
WAN_IFACE=""
for iface in $(ls /sys/class/net/ | grep -v '^lo$'); do
    ADDR=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "$ADDR" ]; then
        WAN_IFACE="$iface"
    fi
done

if [ -n "$WAN_IFACE" ]; then
    echo "  Found unconfigured interface: $WAN_IFACE — assigning 10.100.0.2/30"
    ip addr add 10.100.0.2/30 dev "$WAN_IFACE" 2>/dev/null || true
    ip link set "$WAN_IFACE" up
    ip route replace 10.0.1.0/26 via 10.100.0.1 dev "$WAN_IFACE" || true
    ip route replace 10.0.1.128/26 via 10.100.0.1 dev "$WAN_IFACE" || true
    ip route replace 10.0.1.240/28 via 10.100.0.1 dev "$WAN_IFACE" || true
    echo "  WAN interface $WAN_IFACE configured."
else
    if ip -4 addr show | grep -q "10.100.0.2"; then
        echo "  WAN IP 10.100.0.2 already configured."
        WAN_IFACE=$(ip -4 -o addr show | grep "10.100.0.2" | awk '{print $2}')
        ip route replace 10.0.1.0/26 via 10.100.0.1 dev "$WAN_IFACE" || true
        ip route replace 10.0.1.128/26 via 10.100.0.1 dev "$WAN_IFACE" || true
        ip route replace 10.0.1.240/28 via 10.100.0.1 dev "$WAN_IFACE" || true
    else
        echo "  ⚠ WARNING: Could not find WAN interface! Is the acme-wan NIC attached?"
        echo "  Run: vagrant halt vm4-gw && VBoxManage modifyvm acme-vm4-gw --nic4 intnet --intnet4 acme-wan --nictype4 82540EM && vagrant up vm4-gw"
    fi
fi

# ── Certificates ──
echo ">>> Installing certificates..."
cp "$CERT_SRC/ca.crt"       "$IPSEC_DIR/cacerts/ca.crt"
cp "$CERT_SRC/london.crt"   "$IPSEC_DIR/certs/london.crt"
cp "$CERT_SRC/london.key"   "$IPSEC_DIR/private/london.key"
chmod 644 "$IPSEC_DIR/cacerts/ca.crt"
chmod 644 "$IPSEC_DIR/certs/london.crt"
chmod 600 "$IPSEC_DIR/private/london.key"
chown root:root "$IPSEC_DIR/private/london.key"

# ── IPsec config ──
echo ">>> Installing ipsec.conf and ipsec.secrets..."
cp "$SRC/london/ipsec.conf"    /etc/ipsec.conf
cp "$SRC/london/ipsec.secrets" /etc/ipsec.secrets
chmod 644 /etc/ipsec.conf
chmod 600 /etc/ipsec.secrets

# ── NAT exclusion ──
echo ">>> Configuring NAT exclusion for tunnel traffic..."
EXCL_MARK="# IPsec S2S NAT exclusion"
if ! grep -q "$EXCL_MARK" /etc/ufw/before.rules 2>/dev/null; then
    if grep -q "\*nat" /etc/ufw/before.rules 2>/dev/null; then
        sed -i "/-A POSTROUTING.*MASQUERADE/i \\
$EXCL_MARK\\
-A POSTROUTING -s 10.0.2.0/26 -d 10.0.1.0/24 -j ACCEPT\\
-A POSTROUTING -s 10.0.2.128/26 -d 10.0.1.0/24 -j ACCEPT" /etc/ufw/before.rules
        echo "  NAT exclusion added to before.rules"
    fi
fi
iptables -t nat -C POSTROUTING -s 10.0.2.0/24 -d 10.0.1.0/24 -j ACCEPT 2>/dev/null || \
    iptables -t nat -I POSTROUTING 1 -s 10.0.2.0/24 -d 10.0.1.0/24 -j ACCEPT

# ── IP forwarding (should already be set by provisioner, but ensure) ──
sysctl -w net.ipv4.ip_forward=1

# ── Start StrongSwan ──
echo ">>> Enabling StrongSwan..."
systemctl enable strongswan-starter 2>/dev/null || systemctl enable strongswan 2>/dev/null || true
systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true

echo ">>> VM4 deployment complete."
VM4_EOF

# ═════════════════════════════════════════════════════════════
# Verify tunnel status
# ═════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────────────────"
echo " Checking tunnel status"
echo "─────────────────────────────────────────────────────"

sleep 3

echo ">>> Verifying StrongSwan is running..."
vagrant ssh vm4-gw -- "sudo ipsec status" &>/dev/null && echo "  VM4: StrongSwan running" || echo "  ⚠ VM4: StrongSwan NOT running"

echo ""
echo ">>> Checking tunnel status on VM4..."
vagrant ssh vm4-gw -- "sudo ipsec status" || true

echo ""
echo "====================================================="
echo " Site-to-Site VPN Setup Complete!"
echo ""
echo " Verify with:  bash services/vpn/test-s2s.sh"
echo "====================================================="

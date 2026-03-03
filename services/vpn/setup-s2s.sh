#!/bin/bash
# =============================================================================
# Setup Site-to-Site IPsec VPN — Stockholm (VM1) ↔ London (VM4)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/setup-s2s.sh
#
# Prerequisites:
#   - VMs are up:  vagrant up vm1-gw vm4-gw
#   - Certs exist: bash services/vpn/setup-ca.sh   (if not already done)
#
# This script:
#   1. Verifies certificates exist in services/vpn/certs/
#   2. Deploys certs + config to VM1 (Stockholm)
#   3. Deploys certs + config to VM4 (London)
#   4. Adds NAT exclusions on both gateways
#   5. Enables StrongSwan on both sides
#   6. Initiates the tunnel and verifies establishment
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

CERT_DIR="services/vpn/certs"

echo "====================================================="
echo " Site-to-Site IPsec VPN Setup"
echo " Stockholm (VM1) ↔ London (VM4)"
echo "====================================================="

# ── Pre-flight: verify certs ──
echo ""
echo ">>> Pre-flight: checking certificates..."
MISSING=0
for f in ca.crt stockholm.crt stockholm.key london.crt london.key; do
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
# Stockholm (VM1)
# ═════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────────────────"
echo " Deploying to VM1 (Stockholm Gateway)"
echo "─────────────────────────────────────────────────────"

vagrant ssh vm1-gw -- sudo bash -s << 'VM1_EOF'
set -euo pipefail

SRC="/vagrant/services/vpn"
CERT_SRC="$SRC/certs"
IPSEC_DIR="/etc/ipsec.d"

# ── WAN interface (acme-wan) ──
# VirtualBox NIC5 may appear as enp0s16 (PCI slot 0x10) not enp0s11.
# Find the interface that doesn't yet have 10.0.1.x or 10.0.2.x and isn't lo/enp0s3.
echo ">>> Configuring WAN interface..."
WAN_IFACE=""
for iface in $(ls /sys/class/net/ | grep -v '^lo$'); do
    # Skip the management (enp0s3) and already-configured VLAN interfaces
    ADDR=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "$ADDR" ]; then
        # Unconfigured interface — this is likely the WAN
        WAN_IFACE="$iface"
    fi
done

if [ -n "$WAN_IFACE" ]; then
    echo "  Found unconfigured interface: $WAN_IFACE — assigning 10.100.0.1/30"
    ip addr add 10.100.0.1/30 dev "$WAN_IFACE" 2>/dev/null || true
    ip link set "$WAN_IFACE" up
    # Route to London subnets via WAN
    ip route replace 10.0.2.0/26 via 10.100.0.2 dev "$WAN_IFACE" || true
    ip route replace 10.0.2.128/26 via 10.100.0.2 dev "$WAN_IFACE" || true
    echo "  WAN interface $WAN_IFACE configured."
else
    # Check if 10.100.0.1 is already configured on some interface
    if ip -4 addr show | grep -q "10.100.0.1"; then
        echo "  WAN IP 10.100.0.1 already configured."
        WAN_IFACE=$(ip -4 -o addr show | grep "10.100.0.1" | awk '{print $2}')
        ip route replace 10.0.2.0/26 via 10.100.0.2 dev "$WAN_IFACE" || true
        ip route replace 10.0.2.128/26 via 10.100.0.2 dev "$WAN_IFACE" || true
    else
        echo "  ⚠ WARNING: Could not find WAN interface!"
    fi
fi

# ── Certificates ──
echo ">>> Installing certificates..."
cp "$CERT_SRC/ca.crt"          "$IPSEC_DIR/cacerts/ca.crt"
cp "$CERT_SRC/stockholm.crt"   "$IPSEC_DIR/certs/stockholm.crt"
cp "$CERT_SRC/stockholm.key"   "$IPSEC_DIR/private/stockholm.key"
chmod 644 "$IPSEC_DIR/cacerts/ca.crt"
chmod 644 "$IPSEC_DIR/certs/stockholm.crt"
chmod 600 "$IPSEC_DIR/private/stockholm.key"
chown root:root "$IPSEC_DIR/private/stockholm.key"

# ── IPsec config ──
echo ">>> Installing ipsec.conf and ipsec.secrets..."
cp "$SRC/ipsec.conf"    /etc/ipsec.conf
cp "$SRC/ipsec.secrets" /etc/ipsec.secrets
chmod 644 /etc/ipsec.conf
chmod 600 /etc/ipsec.secrets

# ── NAT exclusion ──
# Don't masquerade traffic destined for London subnets (goes through tunnel)
echo ">>> Configuring NAT exclusion for tunnel traffic..."
EXCL_MARK="# IPsec S2S NAT exclusion"
if ! grep -q "$EXCL_MARK" /etc/ufw/before.rules 2>/dev/null; then
    # Add to *nat table if UFW before.rules has one, otherwise use raw iptables
    if grep -q "\*nat" /etc/ufw/before.rules 2>/dev/null; then
        sed -i "/-A POSTROUTING.*MASQUERADE/i \\
$EXCL_MARK\\
-A POSTROUTING -s 10.0.1.0/26 -d 10.0.2.0/24 -j ACCEPT\\
-A POSTROUTING -s 10.0.1.128/26 -d 10.0.2.0/24 -j ACCEPT\\
-A POSTROUTING -s 10.0.1.240/28 -d 10.0.2.0/24 -j ACCEPT" /etc/ufw/before.rules
        echo "  NAT exclusion added to before.rules"
    fi
fi
# Also add direct iptables rules (work even without UFW)
iptables -t nat -C POSTROUTING -s 10.0.1.0/24 -d 10.0.2.0/24 -j ACCEPT 2>/dev/null || \
    iptables -t nat -I POSTROUTING 1 -s 10.0.1.0/24 -d 10.0.2.0/24 -j ACCEPT

# ── Start StrongSwan ──
echo ">>> Enabling StrongSwan..."
systemctl enable strongswan-starter 2>/dev/null || systemctl enable strongswan 2>/dev/null || true
systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true

echo ">>> VM1 deployment complete."
VM1_EOF

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
# Bring up the tunnel
# ═════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────────────────"
echo " Initiating IPsec tunnel"
echo "─────────────────────────────────────────────────────"

# Small delay to let both daemons stabilise
sleep 3

# ── Pre-flight: verify WAN connectivity ──
echo ">>> Checking WAN link (VM1 → VM4)..."
if ! vagrant ssh vm1-gw -- "ping -c 2 -W 2 10.100.0.2" &>/dev/null; then
    echo "  ⚠ WARNING: VM1 cannot reach VM4 over WAN (10.100.0.2)."
    echo "  Check that both VMs are up and the acme-wan network is attached."
    echo "  Continuing anyway..."
fi

echo ">>> Verifying StrongSwan is running on both sides..."
vagrant ssh vm1-gw -- "sudo ipsec status" &>/dev/null && echo "  VM1: StrongSwan running" || echo "  ⚠ VM1: StrongSwan NOT running"
vagrant ssh vm4-gw -- "sudo ipsec status" &>/dev/null && echo "  VM4: StrongSwan running" || echo "  ⚠ VM4: StrongSwan NOT running"

echo ">>> Reloading IPsec on both gateways..."
vagrant ssh vm4-gw -- "sudo ipsec reload" || true
vagrant ssh vm1-gw -- "sudo ipsec reload" || true
sleep 2

# VM1 has auto=start, so the tunnel initiates automatically on StrongSwan restart.
# We poll ipsec status instead of calling "ipsec up" (which would hang/duplicate).
echo ">>> Waiting for tunnel to establish (auto=start on VM1, polling up to 30s)..."
TUNNEL_UP=0
for i in $(seq 1 15); do
    if vagrant ssh vm1-gw -- "sudo ipsec status 2>/dev/null" | grep -q "ESTABLISHED"; then
        TUNNEL_UP=1
        break
    fi
    echo "  Attempt $i/15 — not yet established, waiting 2s..."
    sleep 2
done

if [ "$TUNNEL_UP" -eq 1 ]; then
    echo "  ✅ Tunnel established successfully."
else
    echo "  ⚠ Tunnel did not establish within 30s."
    echo "  Trying manual initiation with: ipsec up stockholm-london..."
    if vagrant ssh vm1-gw -- "sudo timeout 15 ipsec up stockholm-london" 2>&1; then
        echo "  ✅ Tunnel established after manual initiation."
    else
        echo "  ⚠ Tunnel initiation failed. Checking logs..."
        echo ""
        echo ">>> StrongSwan log (last 30 lines) on VM1:"
        vagrant ssh vm1-gw -- "sudo journalctl -u strongswan-starter --no-pager -n 30 2>/dev/null || sudo journalctl -u strongswan --no-pager -n 30 2>/dev/null || sudo tail -30 /var/log/syslog | grep -i charon" || true
        echo ""
        echo ">>> StrongSwan log (last 30 lines) on VM4:"
        vagrant ssh vm4-gw -- "sudo journalctl -u strongswan-starter --no-pager -n 30 2>/dev/null || sudo journalctl -u strongswan --no-pager -n 30 2>/dev/null || sudo tail -30 /var/log/syslog | grep -i charon" || true
    fi
fi

echo ""
echo ">>> Checking tunnel status on VM1..."
vagrant ssh vm1-gw -- "sudo ipsec status" || true

echo ""
echo ">>> Checking tunnel status on VM4..."
vagrant ssh vm4-gw -- "sudo ipsec status" || true

echo ""
echo "====================================================="
echo " Site-to-Site VPN Setup Complete!"
echo ""
echo " WAN link:  VM1 (10.100.0.1) ←→ VM4 (10.100.0.2)"
echo " Tunnel:    Stockholm subnets ↔ London subnets"
echo ""
echo " Verify with:  bash services/vpn/test-s2s.sh"
echo "====================================================="

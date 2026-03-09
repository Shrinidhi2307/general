#!/bin/bash
# =============================================================================
# Setup OpenVPN Roadwarrior Server on VM4 (London Gateway)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/setup-openvpn.sh
#
# Prerequisites:
#   - VM3 (CA) and VM4 (London GW) are running
#   - PKI initialised:  bash services/vpn/setup-ca.sh  (if not already done)
#
# This script:
#   1. Generates OpenVPN server certificate on VM3 (air-gapped CA)
#   2. Deploys certs to VM4
#   3. Generates DH parameters and TLS-Auth key
#   4. Writes OpenVPN server config (split-tunnel, 10.0.3.0/24 pool)
#   5. Adds iptables NAT for VPN subnet
#   6. Adds Fail2ban OpenVPN jail
#   7. Enables and starts the OpenVPN service
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

CERT_DIR="services/vpn/certs"

echo "====================================================="
echo " OpenVPN Roadwarrior Server Setup"
echo " Server: VM4 (London Gateway)"
echo " Client pool: 10.0.3.0/24"
echo "====================================================="

# ── Pre-flight: check PKI ──
echo ""
echo ">>> Pre-flight: checking CA certificate..."
if [ ! -f "$CERT_DIR/ca.crt" ]; then
    echo "ERROR: CA certificate not found at $CERT_DIR/ca.crt"
    echo "Run first:  bash services/vpn/setup-ca.sh"
    exit 1
fi
echo "  CA certificate present."

# ═════════════════════════════════════════════════════════════
# Step 1: Generate OpenVPN server certificate on VM3
# ═════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────────────────"
echo " Step 1: Generating OpenVPN server certificate (VM3)"
echo "─────────────────────────────────────────────────────"

vagrant ssh vm3-ca -- sudo bash -s << 'CA_EOF'
set -euo pipefail

CA_DIR="/root/easy-rsa"
EXPORT_DIR="/vagrant/services/vpn/certs"

cd "$CA_DIR"

if [ ! -d "pki" ]; then
    echo "ERROR: EasyRSA PKI not initialised. Run services/vpn/setup-ca.sh first."
    exit 1
fi

# Generate server keypair (idempotent)
if [ ! -f "pki/reqs/openvpn-server.req" ]; then
    echo ">>> Generating key and CSR for openvpn-server..."
    EASYRSA_BATCH=1 \
    EASYRSA_REQ_CN="vpn.acme.internal" \
        ./easyrsa gen-req openvpn-server nopass
else
    echo ">>> CSR already exists for openvpn-server, skipping keygen."
fi

# Sign as server certificate (sets extendedKeyUsage=serverAuth)
if [ ! -f "pki/issued/openvpn-server.crt" ]; then
    echo ">>> Signing server certificate..."
    EASYRSA_BATCH=1 ./easyrsa sign-req server openvpn-server
else
    echo ">>> Certificate already signed for openvpn-server."
fi

# Export
echo ">>> Exporting to $EXPORT_DIR..."
cp "pki/issued/openvpn-server.crt"  "$EXPORT_DIR/openvpn-server.crt"
cp "pki/private/openvpn-server.key" "$EXPORT_DIR/openvpn-server.key"
cp "pki/ca.crt"                     "$EXPORT_DIR/ca.crt"
chmod 644 "$EXPORT_DIR/openvpn-server.crt"
chmod 600 "$EXPORT_DIR/openvpn-server.key"

echo "Done. Server certificate files:"
ls -la "$EXPORT_DIR"/openvpn-server.{crt,key}

CA_EOF

# Verify certs landed on host
for f in openvpn-server.crt openvpn-server.key; do
    if [ ! -f "$CERT_DIR/$f" ]; then
        echo "ERROR: $CERT_DIR/$f not found — CA step may have failed."
        exit 1
    fi
done
echo "  Server certificate exported successfully."

# ═════════════════════════════════════════════════════════════
# Step 2: Deploy to VM4 and configure OpenVPN
# ═════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────────────────"
echo " Step 2: Deploying OpenVPN server to VM4"
echo "─────────────────────────────────────────────────────"

vagrant ssh vm4-gw -- sudo bash -s << 'VM4_EOF'
set -euo pipefail

SRC="/vagrant/services/vpn/certs"
OVPN_DIR="/etc/openvpn/server"

# ── Create directories ──
mkdir -p "$OVPN_DIR" /var/log/openvpn

# ── Copy certificates ──
echo ">>> Installing certificates..."
cp "$SRC/ca.crt"              "$OVPN_DIR/ca.crt"
cp "$SRC/openvpn-server.crt"  "$OVPN_DIR/openvpn-server.crt"
cp "$SRC/openvpn-server.key"  "$OVPN_DIR/openvpn-server.key"
chmod 644 "$OVPN_DIR/ca.crt" "$OVPN_DIR/openvpn-server.crt"
chmod 600 "$OVPN_DIR/openvpn-server.key"
chown root:root "$OVPN_DIR/openvpn-server.key"

# ── Generate DH parameters (if not already present) ──
if [ ! -f "$OVPN_DIR/dh.pem" ]; then
    echo ">>> Generating DH parameters (2048-bit, this takes ~1 minute)..."
    openssl dhparam -out "$OVPN_DIR/dh.pem" 2048
    # Export for client config scripts
    cp "$OVPN_DIR/dh.pem" "$SRC/dh.pem"
else
    echo ">>> DH parameters already exist."
fi

# ── Generate TLS-Auth key (if not already present) ──
if [ ! -f "$OVPN_DIR/ta.key" ]; then
    echo ">>> Generating TLS-Auth key..."
    openvpn --genkey secret "$OVPN_DIR/ta.key"
    # Export for client config scripts
    cp "$OVPN_DIR/ta.key" "$SRC/ta.key"
else
    echo ">>> TLS-Auth key already exists."
fi

# ── Write server configuration ──
echo ">>> Writing OpenVPN server config..."
cat > "$OVPN_DIR/roadwarrior.conf" << 'CONF_EOF'
# =============================================================================
# ACME Roadwarrior OpenVPN Server — VM4 (London Gateway)
# =============================================================================
# Split-tunnel: only corporate traffic (10.0.1.0/24, 10.0.2.0/24) through VPN
# Client pool: 10.0.3.0/24
# =============================================================================

port 1194
proto udp
dev tun

# ── Certificates ──
ca       /etc/openvpn/server/ca.crt
cert     /etc/openvpn/server/openvpn-server.crt
key      /etc/openvpn/server/openvpn-server.key
dh       /etc/openvpn/server/dh.pem
tls-auth /etc/openvpn/server/ta.key 0

# ── Network ──
server 10.0.3.0 255.255.255.0
topology subnet

# Split tunnel: push only corporate routes
push "route 10.0.1.0 255.255.255.0"
push "route 10.0.2.0 255.255.255.0"

# Push internal DNS for acme.internal resolution
push "dhcp-option DNS 10.0.1.2"
push "dhcp-option DOMAIN acme.internal"

# ── Security ──
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
remote-cert-tls client

# ── Connection ──
keepalive 10 120
persist-key
persist-tun

# ── Logging ──
status      /var/log/openvpn/roadwarrior-status.log
log-append  /var/log/openvpn/roadwarrior.log
verb 3

# ── Privilege drop ──
user nobody
group nogroup
CONF_EOF

# ── NAT for VPN clients ──
echo ">>> Configuring NAT for VPN subnet (10.0.3.0/24)..."

# Masquerade VPN client traffic going to internet
iptables -t nat -C POSTROUTING -s 10.0.3.0/24 -o enp0s3 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.0.3.0/24 -o enp0s3 -j MASQUERADE

# NAT exclusion: don't masquerade VPN traffic to Stockholm (goes through S2S tunnel)
iptables -t nat -C POSTROUTING -s 10.0.3.0/24 -d 10.0.1.0/24 -j ACCEPT 2>/dev/null || \
    iptables -t nat -I POSTROUTING 1 -s 10.0.3.0/24 -d 10.0.1.0/24 -j ACCEPT

# Allow forwarding from tun to internal interfaces
iptables -C FORWARD -i tun0 -o enp0s8 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i tun0 -o enp0s8 -j ACCEPT
iptables -C FORWARD -i tun0 -o enp0s9 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i tun0 -o enp0s9 -j ACCEPT

# Save iptables
netfilter-persistent save 2>/dev/null || true

# ── Ensure IP forwarding ──
sysctl -w net.ipv4.ip_forward=1

# ── Enable and start OpenVPN ──
echo ">>> Starting OpenVPN server..."
systemctl enable openvpn-server@roadwarrior
systemctl restart openvpn-server@roadwarrior

# Wait for tun0 to come up
sleep 3

if systemctl is-active --quiet openvpn-server@roadwarrior; then
    echo "  ✅ OpenVPN server is running."
    echo "  tun0 interface:"
    ip addr show tun0 2>/dev/null | grep inet || echo "  (tun0 not yet ready)"
else
    echo "  ⚠ OpenVPN server failed to start. Checking logs..."
    journalctl -u openvpn-server@roadwarrior --no-pager -n 20
fi

VM4_EOF

# ═════════════════════════════════════════════════════════════
# Step 3: Add Fail2ban OpenVPN jail on VM4
# ═════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────────────────"
echo " Step 3: Adding Fail2ban OpenVPN jail on VM4"
echo "─────────────────────────────────────────────────────"

vagrant ssh vm4-gw -- sudo bash -s << 'F2B_EOF'
set -euo pipefail

# ── OpenVPN filter ──
cat > /etc/fail2ban/filter.d/openvpn.conf << 'FILTER_EOF'
# Fail2ban filter for OpenVPN authentication failures
[Definition]
failregex = ^.*<HOST>.*TLS Auth Error.*$
            ^.*<HOST>.*VERIFY ERROR.*$
            ^.*<HOST>.*TLS Error.*$
            ^.*<HOST>.*AUTH_FAILED.*$
ignoreregex =
FILTER_EOF

# ── Add OpenVPN jail to existing config ──
# Check if openvpn jail already exists
if grep -q "\[openvpn\]" /etc/fail2ban/jail.d/acme.conf 2>/dev/null; then
    echo ">>> OpenVPN jail already configured in acme.conf"
else
    echo ">>> Adding OpenVPN jail to acme.conf..."
    cat >> /etc/fail2ban/jail.d/acme.conf << 'JAIL_EOF'

[openvpn]
enabled  = true
port     = 1194
protocol = udp
filter   = openvpn
logpath  = /var/log/openvpn/roadwarrior.log
maxretry = 5
JAIL_EOF
fi

# Restart fail2ban to pick up new jail
systemctl restart fail2ban
sleep 2

echo ">>> Fail2ban jails on VM4:"
fail2ban-client status

F2B_EOF

echo ""
echo "====================================================="
echo " OpenVPN Roadwarrior Setup Complete!"
echo ""
echo " Server:      VM4 (10.0.2.1:1194/udp)"
echo " Client pool: 10.0.3.0/24"
echo " Mode:        Split-tunnel (corporate routes only)"
echo " DNS:         10.0.1.2 (VM2 BIND9)"
echo ""
echo " Next steps:"
echo "   1. Issue client config:  bash services/vpn/issue-vpn-client.sh <name>"
echo "   2. Run tests:            bash test-vpn-roadwarrior.sh"
echo "   3. Import .ovpn into Tunnelblick/OpenVPN Connect"
echo "====================================================="

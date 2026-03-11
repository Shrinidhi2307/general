#!/bin/bash
# =============================================================================
# VM5 (London RADIUS Proxy) — Provisioner
# Installs: freeradius (proxy mode)
# Networking: bridged to London router LAN via enp0s9
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM5 (London RADIUS Proxy)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    freeradius freeradius-utils

# ── FreeRADIUS: RADIUS clients ──
# Allow the London router (any IP on the LAN) to send auth requests
cat >> /etc/freeradius/3.0/clients.conf << 'EOF'

client london-router {
    ipaddr = 192.168.1.0/24
    secret = acme_radius_secret
}
EOF

# ── FreeRADIUS: local test users ──
# These mirror VM3's users for standalone testing before proxy is enabled.
cat >> /etc/freeradius/3.0/users << 'EOF'

testuser Cleartext-Password := "testpass123"
alice    Cleartext-Password := "alice_password123"
bob      Cleartext-Password := "bob_password456"
EOF

# ── FreeRADIUS: EAP certs ──
# Default snake-oil certs are used for testing.
# Replace with proper certs for demo:
#   cd /etc/freeradius/3.0/certs && make destroycerts && make

# ── Enable service ──
systemctl restart freeradius
systemctl enable freeradius

echo ">>> VM5 (London RADIUS Proxy) provisioned."

#!/bin/bash
# =============================================================================
# VM4 (London Gateway) — Provisioner
# Installs: strongswan, openvpn, suricata, fail2ban
# Configures: IP forwarding, NAT masquerade, inter-VLAN routing
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM4 (London Gateway)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    strongswan strongswan-pki libcharon-extra-plugins \
    openvpn easy-rsa \
    suricata fail2ban

# ── IP Forwarding (persistent) ──
sysctl -w net.ipv4.ip_forward=1
cat > /etc/sysctl.d/99-acme-forward.conf << 'EOF'
net.ipv4.ip_forward=1
EOF

# ── NAT Masquerade ──
# enp0s3 = Vagrant NAT (internet-facing)
# enp0s8 = London VLAN 10,  enp0s9 = London VLAN 20,  enp0s10 = WAN
iptables -t nat -C POSTROUTING -o enp0s3 -s 10.0.2.0/24 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o enp0s3 -s 10.0.2.0/24 -j MASQUERADE
iptables -C FORWARD -i enp0s8 -o enp0s3 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i enp0s8 -o enp0s3 -j ACCEPT
iptables -C FORWARD -i enp0s9 -o enp0s3 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i enp0s9 -o enp0s3 -j ACCEPT
iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── Route to Stockholm subnets via WAN link ──
# WAN interface is configured by services/vpn/setup-s2s.sh (auto-detects name)

# Persist iptables across reboots
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
netfilter-persistent save

echo ">>> VM4 (London Gateway) provisioned."

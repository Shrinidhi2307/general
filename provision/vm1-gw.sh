#!/bin/bash
# =============================================================================
# VM1 (Stockholm Gateway) — Provisioner
# Installs: strongswan, suricata, fail2ban
# Configures: IP forwarding, NAT masquerade, inter-VLAN routing, DMZ Firewall
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM1 (Gateway)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    strongswan strongswan-pki libcharon-extra-plugins \
    suricata fail2ban

# ── IP Forwarding (persistent) ──
sysctl -w net.ipv4.ip_forward=1
cat > /etc/sysctl.d/99-acme-forward.conf << 'EOF'
net.ipv4.ip_forward=1
EOF

# ── NAT Masquerade & Firewall ──
# enp0s3 = Vagrant NAT (internet-facing)
# enp0s8 = VLAN 10,  enp0s9 = VLAN 20,  enp0s10 = DMZ (10.0.1.240/28)
# WAN interface name varies (enp0s11 or enp0s16 depending on VBox PCI slot)

iptables -t nat -C PREROUTING -i enp0s3 -p tcp --dport 80 -j DNAT --to-destination 10.0.1.242:80 2>/dev/null || \
    iptables -t nat -A PREROUTING -i enp0s3 -p tcp --dport 80 -j DNAT --to-destination 10.0.1.242:80
iptables -t nat -C PREROUTING -i enp0s3 -p tcp --dport 443 -j DNAT --to-destination 10.0.1.242:443 2>/dev/null || \
    iptables -t nat -A PREROUTING -i enp0s3 -p tcp --dport 443 -j DNAT --to-destination 10.0.1.242:443
iptables -t nat -C POSTROUTING -o enp0s3 -s 10.0.1.0/24 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o enp0s3 -s 10.0.1.0/24 -j MASQUERADE
iptables -t nat -C POSTROUTING -o enp0s10 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o enp0s10 -j MASQUERADE
iptables -C FORWARD -i enp0s8 -o enp0s3 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i enp0s8 -o enp0s3 -j ACCEPT
iptables -C FORWARD -i enp0s10 -o enp0s3 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i enp0s10 -o enp0s3 -j ACCEPT
iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C FORWARD -d 10.0.1.240/28 -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -d 10.0.1.240/28 -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -C FORWARD -s 10.0.1.240/28 -d 10.0.1.0/24 -j DROP 2>/dev/null || \
    iptables -A FORWARD -s 10.0.1.240/28 -d 10.0.1.0/24 -j DROP


# ── Route to London subnets via WAN link ──
# WAN interface is configured by services/vpn/setup-s2s.sh (auto-detects name)

# Persist iptables across reboots
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
netfilter-persistent save

echo ">>> VM1 (Gateway) provisioned."

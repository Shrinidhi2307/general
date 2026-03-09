#!/bin/bash
# =============================================================================
# Configure UFW for ACME London VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash configure-ufw-london.sh
#
# Interface mapping (VirtualBox):
#   enp0s3  = Vagrant NAT (management/internet)
#   enp0s8  = First private_network (London VLAN 10)
#   enp0s9  = Second private_network (VM4 only: London VLAN 20)
# =============================================================================
set -euo pipefail


echo "====================================================="
echo " Configuring UFW for ACME London VMs"
echo "====================================================="

# Helper to run a command on a VM via vagrant ssh
run_on() {
    local vm="$1"
    shift
    vagrant ssh "$vm" -c "sudo $*"
}

# ─────────────────────────────────────────────────────────
# 1. Configure VM4 (London Gateway) — Routing Firewall
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM4 (London Gateway) UFW rules..."

run_on vm4-gw "ufw --force reset"

# Set default forward policy to DROP (zero-trust routing)
run_on vm4-gw "sed -i 's/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/DEFAULT_FORWARD_POLICY=\"DROP\"/g' /etc/default/ufw"

# Patch before.rules: inject NAT masquerade
vagrant ssh vm4-gw -- sudo bash -s << 'RULES_EOF'
# Remove any existing NAT section
sed -i '/^\*nat/,/^COMMIT/d' /etc/ufw/before.rules
# Inject NAT at top of file (masquerade London + VPN subnets, exclude S2S traffic)
sed -i '1i *nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.0.2.0/24 -d 10.0.1.0/24 -j ACCEPT\n-A POSTROUTING -s 10.0.3.0/24 -d 10.0.1.0/24 -j ACCEPT\n-A POSTROUTING -s 10.0.2.0/24 -o enp0s3 -j MASQUERADE\n-A POSTROUTING -s 10.0.3.0/24 -o enp0s3 -j MASQUERADE\nCOMMIT\n' /etc/ufw/before.rules
# Remove blanket ICMP echo-request from FORWARD chain
sed -i '/ufw-before-forward.*icmp.*echo-request/d' /etc/ufw/before.rules
RULES_EOF

# Baseline policies
run_on vm4-gw "ufw default deny incoming"
run_on vm4-gw "ufw default allow outgoing"
run_on vm4-gw "ufw default deny routed"

# Host-level ingress
run_on vm4-gw "ufw limit ssh comment 'Rate limit SSH (6/30s)'"
run_on vm4-gw "ufw allow 500,4500/udp comment 'IKEv2/IPsec S2S tunnel'"
run_on vm4-gw "ufw allow proto esp from any to any comment 'IPsec ESP traffic'"
run_on vm4-gw "ufw allow 1194/udp comment 'OpenVPN server'"

# ─── ROUTING POLICIES ───

# 1. Allow outbound internet from London internal networks
run_on vm4-gw "ufw route allow in on enp0s8 out on enp0s3 from 10.0.2.0/26 to any comment 'London VLAN 10 to Internet'"
run_on vm4-gw "ufw route allow in on enp0s9 out on enp0s3 from 10.0.2.128/26 to any comment 'London VLAN 20 to Internet'"

# 2. Inter-VLAN: Client VLAN 20 → Server VLAN 10 (limited ports)
run_on vm4-gw "ufw route allow from 10.0.2.128/26 to 10.0.2.0/26 port 443,8384 proto tcp comment 'London VLAN 20 to VLAN 10 (HTTPS, Syncthing)'"
run_on vm4-gw "ufw route allow from 10.0.2.128/26 to 10.0.2.0/26 port 53 comment 'London VLAN 20 to VLAN 10 (DNS)'"
run_on vm4-gw "ufw route allow from 10.0.2.128/26 to 10.0.2.0/26 port 1812,1813 proto udp comment 'London VLAN 20 to RADIUS'"

# 3. VPN Roadwarrior clients (10.0.3.0/24) — split-tunnel access
#    Block VPN to CA (VM3) first, then allow limited services
run_on vm4-gw "ufw route deny from 10.0.3.0/24 to 10.0.1.3 comment 'Block VPN to VM3 (CA)'"
run_on vm4-gw "ufw route allow from 10.0.3.0/24 to 10.0.1.0/26 port 443,8384 proto tcp comment 'VPN to Stockholm VLAN 10 (HTTPS, Syncthing)'"
run_on vm4-gw "ufw route allow from 10.0.3.0/24 to 10.0.1.0/26 port 53 comment 'VPN to Stockholm VLAN 10 (DNS)'"
run_on vm4-gw "ufw route allow from 10.0.3.0/24 to 10.0.2.0/26 port 443 proto tcp comment 'VPN to London VLAN 10 (HTTPS)'"

# Enable UFW
run_on vm4-gw "ufw --force enable"


# ─────────────────────────────────────────────────────────
# 2. Configure VM5 (London RADIUS Proxy)
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM5 (London RADIUS Proxy) UFW rules..."

run_on vm5-radius "ufw --force reset"
run_on vm5-radius "ufw default deny incoming"
run_on vm5-radius "ufw default allow outgoing"

run_on vm5-radius "ufw limit ssh comment 'Rate limit SSH'"
run_on vm5-radius "ufw allow 1812,1813/udp comment 'FreeRADIUS proxy'"
run_on vm5-radius "ufw --force enable"


echo "====================================================="
echo " London UFW configuration complete!"
echo " Verify with: vagrant ssh <vm> -c 'sudo ufw status verbose'"
echo "====================================================="

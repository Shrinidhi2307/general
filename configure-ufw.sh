#!/bin/bash
# =============================================================================
# Configure UFW for ACME Stockholm VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash configure-ufw.sh
#
# Interface mapping (VirtualBox):
#   enp0s3  = Vagrant NAT (management/internet)
#   enp0s8  = First private_network (VLAN interface)
#   enp0s9  = Second private_network (VM1 only: VLAN 20)
#   enp0s10 = Third private_network  (VM1 only: VLAN 30)
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Configuring UFW for ACME Stockholm VMs"
echo "====================================================="

# Helper to run a command on a VM via vagrant ssh
run_on() {
    local vm="$1"
    shift
    vagrant ssh "$vm" -c "sudo $*"
}

# ─────────────────────────────────────────────────────────
# 1. Configure VM1 (Gateway) — Core Routing Firewall
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM1 (Gateway) UFW rules..."

run_on vm1-gw "ufw --force reset"

# Set default forward policy to DROP (zero-trust routing)
run_on vm1-gw "sed -i 's/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/DEFAULT_FORWARD_POLICY=\"DROP\"/g' /etc/default/ufw"

# Patch before.rules: inject NAT masquerade and remove blanket ICMP forwarding
vagrant ssh vm1-gw -- sudo bash -s << 'RULES_EOF'
# Remove any existing NAT section
sed -i '/^\*nat/,/^COMMIT/d' /etc/ufw/before.rules
# Inject NAT at top of file
sed -i '1i *nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.0.1.0/24 -o enp0s3 -j MASQUERADE\nCOMMIT\n' /etc/ufw/before.rules
# Remove blanket ICMP echo-request from FORWARD chain
# (without this, pings bypass all user deny rules including DMZ isolation)
sed -i '/ufw-before-forward.*icmp.*echo-request/d' /etc/ufw/before.rules
RULES_EOF

# Baseline policies
run_on vm1-gw "ufw default deny incoming"
run_on vm1-gw "ufw default allow outgoing"
run_on vm1-gw "ufw default deny routed"

# Host-level ingress
run_on vm1-gw "ufw limit ssh comment 'Rate limit SSH (6/30s)'"
run_on vm1-gw "ufw allow 500,4500/udp comment 'IKEv2/IPsec S2S tunnel'"
run_on vm1-gw "ufw allow proto esp from any to any comment 'IPsec ESP traffic'"

# ─── ROUTING POLICIES ───

# 1. Deny DMZ → Internal (Defense in Depth — evaluated first)
run_on vm1-gw "ufw route deny from 10.0.1.240/28 to 10.0.1.0/26 comment 'Block: DMZ to Server VLAN'"
run_on vm1-gw "ufw route deny from 10.0.1.240/28 to 10.0.1.128/25 comment 'Block: DMZ to Client VLAN'"

# 2. Allow outbound internet from internal networks
run_on vm1-gw "ufw route allow in on enp0s8 out on enp0s3 from 10.0.1.0/26 to any comment 'VLAN 10 to Internet'"
run_on vm1-gw "ufw route allow in on enp0s9 out on enp0s3 from 10.0.1.128/25 to any comment 'VLAN 20 to Internet'"
run_on vm1-gw "ufw route allow in on enp0s10 out on enp0s3 from 10.0.1.240/28 to any comment 'VLAN 30 (DMZ) to Internet'"

# 3. DMZ Ingress (Internet → Spin-off Web Servers)
run_on vm1-gw "ufw route allow in on enp0s3 out on enp0s10 to 10.0.1.242 port 80,443 proto tcp comment 'HTTP/HTTPS to DMZ'"

# 4. Inter-VLAN constraints (VLAN 20 → VLAN 10)
run_on vm1-gw "ufw route deny from 10.0.1.128/25 to 10.0.1.3 comment 'VLAN 20 to VM3 (CA) blocked'"
run_on vm1-gw "ufw route allow from 10.0.1.128/25 to 10.0.1.0/26 port 443,8384 proto tcp comment 'VLAN 20 to VLAN 10 (HTTPS, Syncthing)'"
run_on vm1-gw "ufw route allow from 10.0.1.128/25 to 10.0.1.0/26 port 53 comment 'VLAN 20 to VLAN 10 (DNS)'"

# Enable UFW
run_on vm1-gw "ufw --force enable"


# ─────────────────────────────────────────────────────────
# 2. Configure VM2 (Server)
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM2 (Server) UFW rules..."

run_on vm2-srv "ufw --force reset"
run_on vm2-srv "ufw default deny incoming"
run_on vm2-srv "ufw default allow outgoing"

run_on vm2-srv "ufw limit ssh comment 'Rate limit SSH'"
run_on vm2-srv "ufw allow 80,443/tcp comment 'Nginx Web Services'"
run_on vm2-srv "ufw allow 53 comment 'BIND9 DNS'"
run_on vm2-srv "ufw allow 8384/tcp comment 'Syncthing GUI/API'"
run_on vm2-srv "ufw allow 22000/tcp comment 'Syncthing Sync'"
run_on vm2-srv "ufw --force enable"


# ─────────────────────────────────────────────────────────
# 3. Configure VM3 (CA Server)
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM3 (CA) UFW rules..."

run_on vm3-ca "ufw --force reset"
run_on vm3-ca "ufw default deny incoming"
run_on vm3-ca "ufw default allow outgoing"

run_on vm3-ca "ufw limit ssh comment 'Rate limit SSH'"
run_on vm3-ca "ufw allow 1812,1813/udp comment 'FreeRADIUS auth'"
run_on vm3-ca "ufw --force enable"


# ─────────────────────────────────────────────────────────
# 4. Configure VM6 (DMZ)
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM6 (DMZ) UFW rules..."

run_on vm6-dmz "ufw --force reset"
run_on vm6-dmz "ufw default deny incoming"
run_on vm6-dmz "ufw default allow outgoing"

run_on vm6-dmz "ufw limit ssh comment 'Rate limit SSH'"
run_on vm6-dmz "ufw allow 80,443/tcp comment 'Spin-off Web (Docker) & Certbot'"
run_on vm6-dmz "ufw --force enable"


echo "====================================================="
echo " UFW configuration complete!"
echo " Verify with: vagrant ssh <vm> -c 'sudo ufw status verbose'"
echo "====================================================="

#!/bin/bash
# =============================================================================
# Configure UFW for ACME Stockholm VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash configure-ufw-stockholm.sh
#
# Interface mapping (VirtualBox):
#   enp0s3  = Vagrant NAT (management/internet)
#   enp0s8  = First private_network (VLAN interface)
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
# 1. Configure VM2 (Server)
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
# 2. Configure VM3 (CA Server)
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM3 (CA) UFW rules..."

run_on vm3-ca "ufw --force reset"
run_on vm3-ca "ufw default deny incoming"
run_on vm3-ca "ufw default allow outgoing"

run_on vm3-ca "ufw limit ssh comment 'Rate limit SSH'"
run_on vm3-ca "ufw allow 1812,1813/udp comment 'FreeRADIUS auth'"
run_on vm3-ca "ufw --force enable"


# ─────────────────────────────────────────────────────────
# 3. Configure VM6 (DMZ)
# ─────────────────────────────────────────────────────────
echo ">>> Setting up VM6 (DMZ) UFW rules..."

run_on vm6-dmz "ufw --force reset"
run_on vm6-dmz "ufw default deny incoming"
run_on vm6-dmz "ufw default allow outgoing"

run_on vm6-dmz "ufw limit ssh comment 'Rate limit SSH'"
run_on vm6-dmz "ufw allow 80,443/tcp comment 'Spin-off Web (Docker) & Certbot'"
run_on vm6-dmz "ufw --force enable"


echo "====================================================="
echo " Stockholm UFW configuration complete!"
echo " Verify with: vagrant ssh <vm> -c 'sudo ufw status verbose'"
echo "====================================================="

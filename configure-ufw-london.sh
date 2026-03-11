#!/bin/bash
# =============================================================================
# Configure UFW for ACME London VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash configure-ufw-london.sh
#
# Interface mapping (VirtualBox):
#   enp0s3  = Vagrant NAT (management/internet)
#   enp0s8  = First private_network (London LAN)
#   enp0s9  = Bridged adapter (VM5: London router LAN)
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
# 1. Configure VM5 (London RADIUS Proxy)
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

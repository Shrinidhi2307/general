#!/bin/bash
# =============================================================================
# Reset UFW on ACME London VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory:
#   bash reset-ufw-london.sh
# =============================================================================
set -euo pipefail


echo "====================================================="
echo " Resetting UFW on ACME London VMs"
echo "====================================================="

run_on() {
    local vm="$1"
    shift
    vagrant ssh "$vm" -c "sudo $*"
}

for vm in vm5-radius; do
    echo ">>> Resetting $vm..."
    run_on "$vm" "ufw --force reset"
    run_on "$vm" "ufw --force disable"
done

echo "====================================================="
echo " London UFW rules reset. Firewalls are disabled."
echo " Run test-firewall-london.sh — all tests should FAIL."
echo "====================================================="

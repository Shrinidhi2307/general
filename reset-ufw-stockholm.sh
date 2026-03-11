#!/bin/bash
# =============================================================================
# Reset UFW on ACME Stockholm VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory:
#   bash reset-ufw-stockholm.sh
# =============================================================================
set -euo pipefail


echo "====================================================="
echo " Resetting UFW on ACME Stockholm VMs"
echo "====================================================="

run_on() {
    local vm="$1"
    shift
    vagrant ssh "$vm" -c "sudo $*"
}

for vm in vm2-srv vm3-ca vm6-dmz; do
    echo ">>> Resetting $vm..."
    run_on "$vm" "ufw --force reset"
    run_on "$vm" "ufw --force disable"
done

echo "====================================================="
echo " Stockholm UFW rules reset. Firewalls are disabled."
echo " Run test-firewall-stockholm.sh — all tests should FAIL."
echo "====================================================="

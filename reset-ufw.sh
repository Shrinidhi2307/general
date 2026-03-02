#!/bin/bash
# =============================================================================
# Reset UFW on all ACME Stockholm VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash reset-ufw.sh
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Resetting UFW on all ACME Stockholm VMs"
echo "====================================================="

run_on() {
    local vm="$1"
    shift
    vagrant ssh "$vm" -c "sudo $*"
}

for vm in vm1-gw vm2-srv vm3-ca vm6-dmz; do
    echo ">>> Resetting $vm..."
    run_on "$vm" "ufw --force reset"
    run_on "$vm" "ufw --force disable"
done

# Flush iptables FORWARD chain on gateway
run_on vm1-gw "iptables -F FORWARD"
run_on vm1-gw "iptables -P FORWARD ACCEPT"

echo "====================================================="
echo " All UFW rules reset. Firewalls are disabled."
echo " Run test-firewall.sh now — all tests should FAIL."
echo "====================================================="

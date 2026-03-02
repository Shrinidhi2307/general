#!/bin/bash
# =============================================================================
# Add UFW Routing Rules for IPsec VPN Traffic on VM1
# =============================================================================
# Run from the project directory:
#   bash services/vpn/ufw-vpn.sh
#
# Adds route allow rules so traffic between Stockholm VLANs and London
# (VLAN 20) can pass through the IPsec tunnel.
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Adding VPN routing rules to VM1 UFW"
echo "====================================================="

# Helper
run_on() {
    local vm="$1"
    shift
    vagrant ssh "$vm" -c "sudo $*"
}

# ── Route rules: Stockholm ↔ London through IPsec tunnel ──

# Allow Stockholm Server VLAN (10) → London Client VLAN (20)
run_on vm1-gw "ufw route allow from 10.0.1.0/26 to 10.0.1.128/26 comment 'IPsec: VLAN 10 → London VLAN 20'"

# Allow London Client VLAN (20) → Stockholm Server VLAN (10)
# (This supplements the existing limited VLAN 20 → VLAN 10 rules)
run_on vm1-gw "ufw route allow from 10.0.1.128/26 to 10.0.1.0/26 comment 'IPsec: London VLAN 20 → VLAN 10'"

# Allow Stockholm DMZ (30) → London Client VLAN (20) — if needed
run_on vm1-gw "ufw route allow from 10.0.1.240/28 to 10.0.1.128/26 comment 'IPsec: DMZ → London VLAN 20'"

# Allow London Client VLAN (20) → Stockholm DMZ (30) — web access
run_on vm1-gw "ufw route allow from 10.0.1.128/26 to 10.0.1.240/28 port 80,443 proto tcp comment 'IPsec: London → DMZ web'"

# Reload
run_on vm1-gw "ufw reload"

echo ""
echo "====================================================="
echo " VPN UFW rules added. Verify with:"
echo "   vagrant ssh vm1-gw -c 'sudo ufw status numbered'"
echo "====================================================="

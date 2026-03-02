#!/bin/bash
# =============================================================================
# Test Firewall Policies for ACME Stockholm VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash test-firewall.sh
# =============================================================================

echo "=========================================================="
echo " Running Firewall Policy Tests for ACME Stockholm"
echo "=========================================================="

PASS=0
FAIL=0

check_ping() {
    local from_vm=$1
    local target_ip=$2
    local expected=$3
    local description=$4

    printf "  %-55s" "$description"

    if vagrant ssh "$from_vm" -c "ping -c 1 -W 2 $target_ip" > /dev/null 2>&1; then
        if [ "$expected" = "SUCCESS" ]; then
            echo "PASS"
            ((PASS++))
        else
            echo "FAIL (Succeeded, but expected to FAIL)"
            ((FAIL++))
        fi
    else
        if [ "$expected" = "FAIL" ]; then
            echo "PASS (Blocked as expected)"
            ((PASS++))
        else
            echo "FAIL (Blocked, but expected to SUCCEED)"
            ((FAIL++))
        fi
    fi
}

echo ""
echo "--- 1. Testing Outbound Internet Access ---"
check_ping vm2-srv 8.8.8.8 SUCCESS "VM2 (Server) can reach the Internet"
check_ping vm6-dmz 8.8.8.8 SUCCESS "VM6 (DMZ) can reach the Internet"

echo ""
echo "--- 2. Testing CA Server Air-Gap ---"
check_ping vm3-ca 8.8.8.8 FAIL "VM3 (CA) cannot reach the Internet"

echo ""
echo "--- 3. Testing DMZ Isolation ---"
check_ping vm6-dmz 10.0.1.2 FAIL "VM6 (DMZ) cannot reach VM2 (Server VLAN)"
check_ping vm6-dmz 10.0.1.3 FAIL "VM6 (DMZ) cannot reach VM3 (CA Server)"

echo ""
echo "--- 4. Testing Internal Base Connectivity ---"
check_ping vm2-srv 10.0.1.1 SUCCESS "VM2 (Server) can reach Gateway"
check_ping vm3-ca 10.0.1.1 SUCCESS "VM3 (CA) can reach Gateway"

echo ""
echo "=========================================================="
echo " Results: $PASS passed, $FAIL failed"
echo " Note: Port-specific tests (VLAN 20 to VLAN 10 on port 443/53)"
echo " require client endpoints to be deployed first."
echo "=========================================================="

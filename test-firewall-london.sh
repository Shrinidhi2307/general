#!/bin/bash
# =============================================================================
# Test Firewall Policies for ACME London VMs (Vagrant/VirtualBox)
# =============================================================================
# Run from the project directory:
#   bash test-firewall-london.sh
# =============================================================================


echo "=========================================================="
echo " Running Firewall Policy Tests — London"
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
echo "--- 1. Testing London Outbound Internet Access ---"
check_ping vm5-radius 8.8.8.8 SUCCESS "VM5 (RADIUS) can reach the Internet"

echo ""
echo "--- 2. Testing London Internal Connectivity ---"
check_ping vm5-radius 10.0.2.1 SUCCESS "VM5 (RADIUS) can reach London Router"

echo ""
echo "=========================================================="
echo " Results: $PASS passed, $FAIL failed"
echo " Note: Port-specific tests (VLAN 20 to VLAN 10 on port 443/53)"
echo " require client endpoints to be deployed first."
echo "=========================================================="

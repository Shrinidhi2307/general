#!/bin/bash
# =============================================================================
# Test Site-to-Site IPsec VPN — London (VM4)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/test-s2s.sh
#
# Tests:
#   1. StrongSwan running on VM4
#   2. Certificates installed on VM4
#   3. IPsec configuration present
#   4. Tunnel state
#   5. NAT exclusion
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0; WARN=0

result() {
    local status="$1" desc="$2"
    case "$status" in
        PASS) printf "  ✅ PASS: %s\n" "$desc"; PASS=$((PASS+1)) ;;
        FAIL) printf "  ❌ FAIL: %s\n" "$desc"; FAIL=$((FAIL+1)) ;;
        WARN) printf "  ⚠️  WARN: %s\n" "$desc"; WARN=$((WARN+1)) ;;
    esac
}

echo "====================================================="
echo " Site-to-Site IPsec VPN Tests — London (VM4)"
echo "====================================================="

# ═════════════════════════════════════════════════════════════
# Section 1: StrongSwan Service
# ═════════════════════════════════════════════════════════════
echo ""
echo "── StrongSwan Service ──"

VM4_SS=$(vagrant ssh vm4-gw -- "systemctl is-active strongswan-starter 2>/dev/null || systemctl is-active strongswan 2>/dev/null || echo inactive" || echo "inactive")
if echo "$VM4_SS" | grep -q "^active"; then
    result PASS "StrongSwan running on VM4"
else
    result FAIL "StrongSwan NOT running on VM4"
fi

# ═════════════════════════════════════════════════════════════
# Section 2: Certificates
# ═════════════════════════════════════════════════════════════
echo ""
echo "── Certificates ──"

VM4_CERTS=$(vagrant ssh vm4-gw -- "sudo bash -c '
    OK=0; BAD=0
    [ -f /etc/ipsec.d/cacerts/ca.crt ]     && OK=\$((OK+1)) || BAD=\$((BAD+1))
    [ -f /etc/ipsec.d/certs/london.crt ]    && OK=\$((OK+1)) || BAD=\$((BAD+1))
    [ -f /etc/ipsec.d/private/london.key ]  && OK=\$((OK+1)) || BAD=\$((BAD+1))
    echo \"\$OK \$BAD\"
'" || echo "0 3")
VM4_OK=$(echo "$VM4_CERTS" | awk '{print $1}')
VM4_BAD=$(echo "$VM4_CERTS" | awk '{print $2}')
if [ "$VM4_BAD" -eq 0 ] 2>/dev/null; then
    result PASS "VM4 certificates installed ($VM4_OK/3)"
else
    result FAIL "VM4 certificates incomplete ($VM4_OK/3 present)"
fi

# ═════════════════════════════════════════════════════════════
# Section 3: IPsec Configuration
# ═════════════════════════════════════════════════════════════
echo ""
echo "── IPsec Configuration ──"

VM4_CONF=$(vagrant ssh vm4-gw -- "grep -c 'london-stockholm' /etc/ipsec.conf 2>/dev/null || echo 0")
if [ "${VM4_CONF//[[:space:]]/}" -gt 0 ] 2>/dev/null; then
    result PASS "VM4: connection 'london-stockholm' defined"
else
    result FAIL "VM4: connection 'london-stockholm' missing"
fi

# ═════════════════════════════════════════════════════════════
# Section 4: Tunnel State
# ═════════════════════════════════════════════════════════════
echo ""
echo "── Tunnel State ──"

VM4_STATUS=$(vagrant ssh vm4-gw -- "sudo ipsec status 2>&1" || true)
echo ""
echo "  VM4 ipsec status:"
echo "$VM4_STATUS" | sed 's/^/    /'
echo ""

if echo "$VM4_STATUS" | grep -q "ESTABLISHED"; then
    result PASS "VM4: IKE SA ESTABLISHED"
else
    result FAIL "VM4: IKE SA not established"
fi

if echo "$VM4_STATUS" | grep -q "INSTALLED"; then
    result PASS "VM4: Child SA (tunnel) INSTALLED"
else
    result FAIL "VM4: Child SA not installed"
fi

# ═════════════════════════════════════════════════════════════
# Section 5: NAT Exclusion
# ═════════════════════════════════════════════════════════════
echo ""
echo "── NAT Exclusion ──"

VM4_NAT=$(vagrant ssh vm4-gw -- "sudo iptables -t nat -L POSTROUTING -n 2>/dev/null" || true)
if echo "$VM4_NAT" | grep -q "10.0.1.0"; then
    result PASS "VM4: NAT exclusion for tunnel traffic"
else
    result WARN "VM4: NAT exclusion rule not detected"
fi

# ═════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════
echo ""
echo "====================================================="
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "====================================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo " Useful commands:"
    echo "   sudo ipsec statusall              — Full SA details"
    echo "   sudo ipsec up london-stockholm    — Initiate from London"
    echo "   sudo journalctl -u strongswan-starter -f  — Live logs"
    exit 1
fi

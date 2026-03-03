#!/bin/bash
# =============================================================================
# Test Site-to-Site IPsec VPN — Stockholm (VM1) ↔ London (VM4)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/test-s2s.sh
#
# Tests:
#   1. WAN link connectivity (10.100.0.1 ↔ 10.100.0.2)
#   2. StrongSwan running on both gateways
#   3. Certificates installed on both sides
#   4. IPsec tunnel established
#   5. Cross-site pings through tunnel
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
echo " Site-to-Site IPsec VPN Tests"
echo " Stockholm (VM1) ↔ London (VM4)"
echo "====================================================="

# ═════════════════════════════════════════════════════════════
# Section 1: WAN Link
# ═════════════════════════════════════════════════════════════
echo ""
echo "── WAN Link (acme-wan 10.100.0.0/30) ──"

# VM1 → VM4 over WAN
WAN_V1_TO_V4=$(vagrant ssh vm1-gw -- "ping -c 2 -W 2 10.100.0.2 2>&1" || true)
if echo "$WAN_V1_TO_V4" | grep -q "bytes from"; then
    result PASS "VM1 (10.100.0.1) → VM4 (10.100.0.2) WAN ping"
else
    result FAIL "VM1 (10.100.0.1) → VM4 (10.100.0.2) WAN ping"
fi

# VM4 → VM1 over WAN
WAN_V4_TO_V1=$(vagrant ssh vm4-gw -- "ping -c 2 -W 2 10.100.0.1 2>&1" || true)
if echo "$WAN_V4_TO_V1" | grep -q "bytes from"; then
    result PASS "VM4 (10.100.0.2) → VM1 (10.100.0.1) WAN ping"
else
    result FAIL "VM4 (10.100.0.2) → VM1 (10.100.0.1) WAN ping"
fi

# ═════════════════════════════════════════════════════════════
# Section 2: StrongSwan Service
# ═════════════════════════════════════════════════════════════
echo ""
echo "── StrongSwan Service ──"

VM1_SS=$(vagrant ssh vm1-gw -- "systemctl is-active strongswan-starter 2>/dev/null || systemctl is-active strongswan 2>/dev/null || echo inactive" || echo "inactive")
if echo "$VM1_SS" | grep -q "^active"; then
    result PASS "StrongSwan running on VM1"
else
    result FAIL "StrongSwan NOT running on VM1"
fi

VM4_SS=$(vagrant ssh vm4-gw -- "systemctl is-active strongswan-starter 2>/dev/null || systemctl is-active strongswan 2>/dev/null || echo inactive" || echo "inactive")
if echo "$VM4_SS" | grep -q "^active"; then
    result PASS "StrongSwan running on VM4"
else
    result FAIL "StrongSwan NOT running on VM4"
fi

# ═════════════════════════════════════════════════════════════
# Section 3: Certificates
# ═════════════════════════════════════════════════════════════
echo ""
echo "── Certificates ──"

# VM1
VM1_CERTS=$(vagrant ssh vm1-gw -- "sudo bash -c '
    OK=0; BAD=0
    [ -f /etc/ipsec.d/cacerts/ca.crt ]       && OK=\$((OK+1)) || BAD=\$((BAD+1))
    [ -f /etc/ipsec.d/certs/stockholm.crt ]   && OK=\$((OK+1)) || BAD=\$((BAD+1))
    [ -f /etc/ipsec.d/private/stockholm.key ] && OK=\$((OK+1)) || BAD=\$((BAD+1))
    echo \"\$OK \$BAD\"
'" || echo "0 3")
VM1_OK=$(echo "$VM1_CERTS" | awk '{print $1}')
VM1_BAD=$(echo "$VM1_CERTS" | awk '{print $2}')
if [ "$VM1_BAD" -eq 0 ] 2>/dev/null; then
    result PASS "VM1 certificates installed ($VM1_OK/3)"
else
    result FAIL "VM1 certificates incomplete ($VM1_OK/3 present)"
fi

# VM4
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
# Section 4: IPsec Configuration
# ═════════════════════════════════════════════════════════════
echo ""
echo "── IPsec Configuration ──"

VM1_CONF=$(vagrant ssh vm1-gw -- "grep -c 'stockholm-london' /etc/ipsec.conf 2>/dev/null || echo 0")
if [ "${VM1_CONF//[[:space:]]/}" -gt 0 ] 2>/dev/null; then
    result PASS "VM1: connection 'stockholm-london' defined"
else
    result FAIL "VM1: connection 'stockholm-london' missing"
fi

VM4_CONF=$(vagrant ssh vm4-gw -- "grep -c 'london-stockholm' /etc/ipsec.conf 2>/dev/null || echo 0")
if [ "${VM4_CONF//[[:space:]]/}" -gt 0 ] 2>/dev/null; then
    result PASS "VM4: connection 'london-stockholm' defined"
else
    result FAIL "VM4: connection 'london-stockholm' missing"
fi

# Verify WAN IPs are set (not %any or %defaultroute)
VM1_RIGHT=$(vagrant ssh vm1-gw -- "grep 'right=10.100.0.2' /etc/ipsec.conf 2>/dev/null || echo missing")
if echo "$VM1_RIGHT" | grep -q "10.100.0.2"; then
    result PASS "VM1: right=10.100.0.2 (London WAN IP set)"
else
    result FAIL "VM1: right= not set to London WAN IP"
fi

VM4_RIGHT=$(vagrant ssh vm4-gw -- "grep 'right=10.100.0.1' /etc/ipsec.conf 2>/dev/null || echo missing")
if echo "$VM4_RIGHT" | grep -q "10.100.0.1"; then
    result PASS "VM4: right=10.100.0.1 (Stockholm WAN IP set)"
else
    result FAIL "VM4: right= not set to Stockholm WAN IP"
fi

# ═════════════════════════════════════════════════════════════
# Section 5: Tunnel State
# ═════════════════════════════════════════════════════════════
echo ""
echo "── Tunnel State ──"

TUNNEL_UP=false

VM1_STATUS=$(vagrant ssh vm1-gw -- "sudo ipsec status 2>&1" || true)
echo ""
echo "  VM1 ipsec status:"
echo "$VM1_STATUS" | sed 's/^/    /'
echo ""

if echo "$VM1_STATUS" | grep -q "ESTABLISHED"; then
    result PASS "VM1: IKE SA ESTABLISHED"
    TUNNEL_UP=true
else
    result FAIL "VM1: IKE SA not established"
fi

if echo "$VM1_STATUS" | grep -q "INSTALLED"; then
    result PASS "VM1: Child SA (tunnel) INSTALLED"
else
    result FAIL "VM1: Child SA not installed"
fi

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
# Section 6: Cross-Site Connectivity (through tunnel)
# ═════════════════════════════════════════════════════════════
echo ""
echo "── Cross-Site Connectivity ──"

if [ "$TUNNEL_UP" = true ]; then
    # Stockholm VLAN 10 → London VLAN 10
    PING1=$(vagrant ssh vm1-gw -- "ping -c 2 -W 3 -I 10.0.1.1 10.0.2.1 2>&1" || true)
    if echo "$PING1" | grep -q "bytes from"; then
        result PASS "Stockholm (10.0.1.1) → London (10.0.2.1) via tunnel"
    else
        result FAIL "Stockholm (10.0.1.1) → London (10.0.2.1) via tunnel"
    fi

    # London VLAN 10 → Stockholm VLAN 10
    PING2=$(vagrant ssh vm4-gw -- "ping -c 2 -W 3 -I 10.0.2.1 10.0.1.1 2>&1" || true)
    if echo "$PING2" | grep -q "bytes from"; then
        result PASS "London (10.0.2.1) → Stockholm (10.0.1.1) via tunnel"
    else
        result FAIL "London (10.0.2.1) → Stockholm (10.0.1.1) via tunnel"
    fi

    # Stockholm VLAN 10 → London VLAN 20
    PING3=$(vagrant ssh vm1-gw -- "ping -c 2 -W 3 -I 10.0.1.1 10.0.2.129 2>&1" || true)
    if echo "$PING3" | grep -q "bytes from"; then
        result PASS "Stockholm (10.0.1.1) → London VLAN20 (10.0.2.129) via tunnel"
    else
        result WARN "Stockholm (10.0.1.1) → London VLAN20 (10.0.2.129) — may need firewall rule"
    fi

    # London VLAN 10 → Stockholm DMZ
    PING4=$(vagrant ssh vm4-gw -- "ping -c 2 -W 3 -I 10.0.2.1 10.0.1.241 2>&1" || true)
    if echo "$PING4" | grep -q "bytes from"; then
        result PASS "London (10.0.2.1) → Stockholm DMZ (10.0.1.241) via tunnel"
    else
        result WARN "London (10.0.2.1) → Stockholm DMZ (10.0.1.241) — may need firewall rule"
    fi
else
    result WARN "Skipping cross-site ping tests (tunnel not established)"
    echo ""
    echo "  Troubleshooting:"
    echo "    vagrant ssh vm1-gw -- 'sudo ipsec up stockholm-london'"
    echo "    vagrant ssh vm1-gw -- 'sudo journalctl -u strongswan-starter --no-pager -n 30'"
    echo "    vagrant ssh vm4-gw -- 'sudo journalctl -u strongswan-starter --no-pager -n 30'"
fi

# ═════════════════════════════════════════════════════════════
# Section 7: NAT Exclusion
# ═════════════════════════════════════════════════════════════
echo ""
echo "── NAT Exclusion ──"

VM1_NAT=$(vagrant ssh vm1-gw -- "sudo iptables -t nat -L POSTROUTING -n 2>/dev/null" || true)
if echo "$VM1_NAT" | grep -q "10.0.2.0"; then
    result PASS "VM1: NAT exclusion for tunnel traffic"
else
    result WARN "VM1: NAT exclusion rule not detected"
fi

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
    echo "   sudo ipsec up stockholm-london    — Initiate from Stockholm"
    echo "   sudo ipsec up london-stockholm    — Initiate from London"
    echo "   sudo journalctl -u strongswan-starter -f  — Live logs"
    echo "   sudo tcpdump -ni enp0s10 esp or udp port 500 or udp port 4500"
    exit 1
fi

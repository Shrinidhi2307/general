#!/bin/bash
# =============================================================================
# Test OpenVPN Roadwarrior Server — VM4 (London Gateway)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash test-vpn-roadwarrior.sh
#
# Prerequisites:
#   - OpenVPN set up:  bash services/vpn/setup-openvpn.sh
# =============================================================================

PASS=0
FAIL=0
SKIP=0

check() {
    local desc="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo "  ✅ PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

skip() {
    local desc="$1"
    echo "  ⏭  SKIP: $desc"
    SKIP=$((SKIP + 1))
}

echo "====================================================="
echo " Testing OpenVPN Roadwarrior Server (VM4)"
echo "====================================================="
echo ""

# ─────────────────────────────────────────────────────────
# Test 1: OpenVPN service is active
# ─────────────────────────────────────────────────────────
echo "── Test 1: OpenVPN service status ──"
vagrant ssh vm4-gw -c "sudo systemctl is-active openvpn-server@roadwarrior" 2>/dev/null | grep -q "active"
check "OpenVPN service is active on VM4" $?

# ─────────────────────────────────────────────────────────
# Test 2: Server certificates present
# ─────────────────────────────────────────────────────────
echo "── Test 2: Server certificates ──"
CERT_CHECK=$(vagrant ssh vm4-gw -c "
    test -f /etc/openvpn/server/ca.crt && \
    test -f /etc/openvpn/server/openvpn-server.crt && \
    test -f /etc/openvpn/server/openvpn-server.key && \
    test -f /etc/openvpn/server/dh.pem && \
    test -f /etc/openvpn/server/ta.key && \
    echo OK" 2>/dev/null)
echo "$CERT_CHECK" | grep -q "OK"
check "All server certificates present in /etc/openvpn/server/" $?

# ─────────────────────────────────────────────────────────
# Test 3: tun0 interface exists with correct IP
# ─────────────────────────────────────────────────────────
echo "── Test 3: tun0 interface ──"
TUN_CHECK=$(vagrant ssh vm4-gw -c "ip addr show tun0 2>/dev/null | grep '10.0.3.1'" 2>/dev/null)
echo "$TUN_CHECK" | grep -q "10.0.3.1"
check "tun0 interface has 10.0.3.1" $?

# ─────────────────────────────────────────────────────────
# Test 4: Port 1194/udp is listening
# ─────────────────────────────────────────────────────────
echo "── Test 4: Listening port ──"
PORT_CHECK=$(vagrant ssh vm4-gw -c "sudo ss -ulnp | grep 1194" 2>/dev/null)
echo "$PORT_CHECK" | grep -q "1194"
check "UDP port 1194 is listening" $?

# ─────────────────────────────────────────────────────────
# Test 5: OpenVPN log exists and shows initialization
# ─────────────────────────────────────────────────────────
echo "── Test 5: OpenVPN log ──"
LOG_CHECK=$(vagrant ssh vm4-gw -c "sudo grep -c 'Initialization Sequence Completed' /var/log/openvpn/roadwarrior.log 2>/dev/null" 2>/dev/null)
if echo "$LOG_CHECK" | grep -qE '^[1-9]'; then
    check "OpenVPN initialization completed in log" 0
else
    check "OpenVPN initialization completed in log" 1
fi

# ─────────────────────────────────────────────────────────
# Test 6: Fail2ban OpenVPN jail
# ─────────────────────────────────────────────────────────
echo "── Test 6: Fail2ban OpenVPN jail ──"
F2B_CHECK=$(vagrant ssh vm4-gw -c "sudo fail2ban-client status openvpn 2>/dev/null" 2>/dev/null)
if echo "$F2B_CHECK" | grep -q "openvpn"; then
    check "Fail2ban openvpn jail is loaded" 0
else
    # Fail2ban may not be configured yet (setup-fail2ban.sh not run)
    if vagrant ssh vm4-gw -c "sudo systemctl is-active fail2ban" 2>/dev/null | grep -q "active"; then
        check "Fail2ban openvpn jail is loaded" 1
    else
        skip "Fail2ban not active (run services/ids/setup-fail2ban.sh first)"
    fi
fi

# ─────────────────────────────────────────────────────────
# Test 7: UFW allows 1194/udp
# ─────────────────────────────────────────────────────────
echo "── Test 7: UFW OpenVPN rule ──"
UFW_STATUS=$(vagrant ssh vm4-gw -c "sudo ufw status 2>/dev/null" 2>/dev/null)
if echo "$UFW_STATUS" | grep -q "inactive"; then
    skip "UFW is inactive (run configure-ufw-london.sh first)"
else
    echo "$UFW_STATUS" | grep -q "1194/udp"
    check "UFW allows 1194/udp" $?
fi

# ─────────────────────────────────────────────────────────
# Test 8: NAT masquerade for VPN subnet
# ─────────────────────────────────────────────────────────
echo "── Test 8: NAT rules for VPN subnet ──"
NAT_CHECK=$(vagrant ssh vm4-gw -c "sudo iptables -t nat -L POSTROUTING -n 2>/dev/null | grep '10.0.3.0/24'" 2>/dev/null)
echo "$NAT_CHECK" | grep -q "10.0.3.0/24"
check "iptables NAT masquerade for 10.0.3.0/24" $?

# ─────────────────────────────────────────────────────────
# Test 9: Server config correctness
# ─────────────────────────────────────────────────────────
echo "── Test 9: Server config validation ──"
CONFIG_CHECK=$(vagrant ssh vm4-gw -c "
    grep -q 'server 10.0.3.0' /etc/openvpn/server/roadwarrior.conf && \
    grep -q 'push.*route 10.0.1.0' /etc/openvpn/server/roadwarrior.conf && \
    grep -q 'push.*route 10.0.2.0' /etc/openvpn/server/roadwarrior.conf && \
    grep -q 'AES-256-GCM' /etc/openvpn/server/roadwarrior.conf && \
    grep -q 'tls-auth' /etc/openvpn/server/roadwarrior.conf && \
    echo OK" 2>/dev/null)
echo "$CONFIG_CHECK" | grep -q "OK"
check "Server config has correct pool, routes, and crypto" $?

# ─────────────────────────────────────────────────────────
# Test 10: Client .ovpn generation
# ─────────────────────────────────────────────────────────
echo "── Test 10: Client config generation ──"
OVPN_FILE="services/vpn/clients/testuser.ovpn"
if [ -f "$OVPN_FILE" ]; then
    # Verify it contains all embedded sections
    if grep -q "<ca>" "$OVPN_FILE" && \
       grep -q "<cert>" "$OVPN_FILE" && \
       grep -q "<key>" "$OVPN_FILE" && \
       grep -q "<tls-auth>" "$OVPN_FILE"; then
        check "Client .ovpn file has embedded certs" 0
    else
        check "Client .ovpn file has embedded certs" 1
    fi
else
    skip "No .ovpn file found (run: bash services/vpn/issue-vpn-client.sh testuser)"
fi

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
echo ""
echo "====================================================="
echo " Results: ${PASS} PASS, ${FAIL} FAIL, ${SKIP} SKIP"
echo "====================================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

#!/bin/bash
# =============================================================================
# IPsec VPN Test Script — Stockholm Gateway (VM1)
# =============================================================================
# Run from the project directory:
#   bash services/vpn/test-vpn.sh
#
# Tests:
#   1. StrongSwan service is running
#   2. Certificates are installed correctly
#   3. IPsec configuration is loaded
#   4. Tunnel status (will show connecting/up/down)
#   5. Connectivity across tunnel (if tunnel is established)
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
WARN=0

result() {
    local status="$1" desc="$2"
    case "$status" in
        PASS) echo "  ✅ PASS: $desc"; ((PASS++)) ;;
        FAIL) echo "  ❌ FAIL: $desc"; ((FAIL++)) ;;
        WARN) echo "  ⚠️  WARN: $desc"; ((WARN++)) ;;
    esac
}

echo "====================================================="
echo " IPsec VPN Tests — VM1 (Stockholm Gateway)"
echo "====================================================="

vagrant ssh vm1-gw -- sudo bash -s << 'TEST_EOF'

PASS=0; FAIL=0; WARN=0
result() {
    local status="$1" desc="$2"
    case "$status" in
        PASS) echo "  ✅ PASS: $desc"; PASS=$((PASS+1)) ;;
        FAIL) echo "  ❌ FAIL: $desc"; FAIL=$((FAIL+1)) ;;
        WARN) echo "  ⚠️  WARN: $desc"; WARN=$((WARN+1)) ;;
    esac
}

# ── 1. StrongSwan Service ──
echo ""
echo "── Service Status ──"
if systemctl is-active --quiet strongswan-starter 2>/dev/null || systemctl is-active --quiet strongswan 2>/dev/null; then
    result PASS "StrongSwan service is running"
else
    result FAIL "StrongSwan service is NOT running"
fi

# ── 2. Certificates ──
echo ""
echo "── Certificate Files ──"
[ -f /etc/ipsec.d/cacerts/ca.crt ]          && result PASS "CA cert installed"           || result FAIL "CA cert missing"
[ -f /etc/ipsec.d/certs/stockholm.crt ]      && result PASS "Stockholm cert installed"    || result FAIL "Stockholm cert missing"
[ -f /etc/ipsec.d/private/stockholm.key ]    && result PASS "Stockholm key installed"     || result FAIL "Stockholm key missing"

# Check key permissions
PERMS=$(stat -c '%a' /etc/ipsec.d/private/stockholm.key 2>/dev/null || echo "N/A")
[ "$PERMS" = "600" ] && result PASS "Key permissions correct (600)" || result WARN "Key permissions: $PERMS (expected 600)"

# Verify cert chain
if openssl verify -CAfile /etc/ipsec.d/cacerts/ca.crt /etc/ipsec.d/certs/stockholm.crt >/dev/null 2>&1; then
    result PASS "Certificate chain validates"
else
    result WARN "Certificate chain validation failed (may need EasyRSA format)"
fi

# ── 3. Configuration ──
echo ""
echo "── Configuration ──"
[ -f /etc/ipsec.conf ]    && result PASS "ipsec.conf present"    || result FAIL "ipsec.conf missing"
[ -f /etc/ipsec.secrets ] && result PASS "ipsec.secrets present" || result FAIL "ipsec.secrets missing"

if grep -q "stockholm-london" /etc/ipsec.conf 2>/dev/null; then
    result PASS "Connection 'stockholm-london' defined"
else
    result FAIL "Connection 'stockholm-london' not found in config"
fi

# ── 4. IPsec Status ──
echo ""
echo "── IPsec Status ──"
echo ""
ipsec statusall 2>&1 || true
echo ""

CONNS=$(ipsec status 2>/dev/null | grep -c "stockholm-london" || true)
if [ "$CONNS" -gt 0 ]; then
    if ipsec status 2>/dev/null | grep -q "ESTABLISHED"; then
        result PASS "Tunnel is ESTABLISHED"
    else
        result WARN "Connection loaded but tunnel not established (London side may not be configured yet)"
    fi
else
    result WARN "No active connection found (expected if London side is not yet up)"
fi

# ── 5. UFW / Firewall ──
echo ""
echo "── Firewall (VPN-related) ──"
if ufw status 2>/dev/null | grep -q "500,4500/udp"; then
    result PASS "UFW allows IKE (UDP 500/4500)"
else
    result FAIL "UFW does not allow IKE traffic"
fi

if grep -q "IPsec NAT exclusion" /etc/ufw/before.rules 2>/dev/null; then
    result PASS "NAT exclusion for tunnel traffic configured"
else
    result WARN "NAT exclusion not found in before.rules"
fi

# ── 6. Tunnel connectivity (only if tunnel is up) ──
echo ""
echo "── Tunnel Connectivity ──"
if ipsec status 2>/dev/null | grep -q "ESTABLISHED"; then
    ping -c 2 -W 2 10.0.1.130 >/dev/null 2>&1 && result PASS "Ping London (10.0.1.130)" || result FAIL "Cannot ping London (10.0.1.130)"
else
    result WARN "Skipping tunnel ping tests (tunnel not established)"
fi

# ── Summary ──
echo ""
echo "====================================================="
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "====================================================="

TEST_EOF

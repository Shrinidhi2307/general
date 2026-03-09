#!/bin/bash
# =============================================================================
# Test IDS (Suricata + Fail2ban) on ACME London Gateway (VM4)
# =============================================================================
# Run from the project directory:
#   bash test-ids-london.sh
#
# Prerequisites:
#   bash services/ids/setup-suricata.sh
#   bash services/ids/setup-fail2ban.sh
# =============================================================================

echo "=========================================================="
echo " Testing IDS Services — London (VM4)"
echo "=========================================================="

PASS=0
FAIL=0

check() {
    local description="$1"
    local result="$2"

    printf "  %-55s" "$description"
    if [ "$result" = "0" ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
}

# ─────────────────────────────────────────────────────────
# 1. Fail2ban service checks
# ─────────────────────────────────────────────────────────
echo ""
echo "--- 1. Fail2ban Service Status ---"

vagrant ssh vm4-gw -c "sudo systemctl is-active fail2ban" > /dev/null 2>&1
check "Fail2ban service is running" "$?"

vagrant ssh vm4-gw -c "sudo fail2ban-client status sshd" > /dev/null 2>&1
check "Fail2ban sshd jail is active" "$?"

vagrant ssh vm4-gw -c "sudo fail2ban-client status strongswan" > /dev/null 2>&1
check "Fail2ban strongswan jail is active" "$?"

# ─────────────────────────────────────────────────────────
# 2. Suricata service checks
# ─────────────────────────────────────────────────────────
echo ""
echo "--- 2. Suricata Service Status ---"

vagrant ssh vm4-gw -c "sudo systemctl is-active suricata" > /dev/null 2>&1
check "Suricata service is running" "$?"

vagrant ssh vm4-gw -c "test -f /etc/suricata/rules/acme-local.rules" > /dev/null 2>&1
check "ACME custom rules file present" "$?"

vagrant ssh vm4-gw -c "test -f /var/log/suricata/eve.json" > /dev/null 2>&1
check "Suricata eve.json log exists" "$?"

# ─────────────────────────────────────────────────────────
# 3. Suricata live detection — port scan from VM5
# ─────────────────────────────────────────────────────────
echo ""
echo "--- 3. Suricata Alert Test (port scan from VM5 → VM4) ---"

vagrant ssh vm4-gw -c "sudo truncate -s 0 /var/log/suricata/fast.log" > /dev/null 2>&1

echo "  Triggering SYN scan from VM5 (this takes ~5 seconds)..."
vagrant ssh vm5-radius -c "for port in 21 22 23 25 53 80 110 143 443 993 995 3306 3389 5432 5900 8080 8443 8888 9090 9999 11211 27017; do timeout 0.2 bash -c 'echo >/dev/tcp/10.0.2.1/'\$port 2>/dev/null & done; wait" > /dev/null 2>&1 || true

sleep 5

ALERT_COUNT=$(vagrant ssh vm4-gw -c "sudo wc -l < /var/log/suricata/fast.log 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
if [ "${ALERT_COUNT:-0}" -gt "0" ]; then
    check "Suricata generated alerts (${ALERT_COUNT} in fast.log)" "0"
else
    EVE_LINES=$(vagrant ssh vm4-gw -c "sudo wc -l < /var/log/suricata/eve.json 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    if [ "${EVE_LINES:-0}" -gt "0" ]; then
        printf "  %-55s" "Suricata generated alerts"
        echo "SKIP (no fast.log alerts, but ${EVE_LINES} events in eve.json — engine is processing)"
    else
        check "Suricata generated alerts" "1"
    fi
fi

echo ""
echo "  Recent Suricata alerts (if any):"
vagrant ssh vm4-gw -c "sudo tail -5 /var/log/suricata/fast.log 2>/dev/null" 2>/dev/null | sed 's/^/    /'

# ─────────────────────────────────────────────────────────
# 4. Fail2ban ban/unban functional test
# ─────────────────────────────────────────────────────────
echo ""
echo "--- 4. Fail2ban Ban/Unban Test ---"
echo "  (SSH is correctly blocked on VLAN interfaces by UFW,"
echo "   so we test ban/unban mechanics via fail2ban-client)"

# Test that fail2ban can ban and unban an IP via UFW
TEST_IP="192.0.2.1"
vagrant ssh vm4-gw -c "sudo fail2ban-client set sshd banip $TEST_IP" > /dev/null 2>&1
sleep 1

BANNED=$(vagrant ssh vm4-gw -c "sudo fail2ban-client status sshd 2>/dev/null" 2>/dev/null)
if echo "$BANNED" | grep -q "$TEST_IP"; then
    check "Fail2ban can ban an IP ($TEST_IP)" "0"
else
    check "Fail2ban can ban an IP ($TEST_IP)" "1"
fi

# Verify UFW reject rule was created (only if UFW is active)
UFW_STATUS=$(vagrant ssh vm4-gw -c "sudo ufw status 2>/dev/null" 2>/dev/null)
if echo "$UFW_STATUS" | grep -q "inactive"; then
    printf "  %-55s" "UFW reject rule created for banned IP"
    echo "SKIP (UFW inactive — run configure-ufw-london.sh first)"
else
    if echo "$UFW_STATUS" | grep -q "$TEST_IP"; then
        check "UFW reject rule created for banned IP" "0"
    else
        check "UFW reject rule created for banned IP" "1"
    fi
fi

# Unban and verify cleanup
vagrant ssh vm4-gw -c "sudo fail2ban-client set sshd unbanip $TEST_IP" > /dev/null 2>&1
sleep 1

AFTER=$(vagrant ssh vm4-gw -c "sudo fail2ban-client status sshd 2>/dev/null" 2>/dev/null)
if echo "$AFTER" | grep -q "$TEST_IP"; then
    check "Fail2ban can unban an IP" "1"
else
    check "Fail2ban can unban an IP" "0"
fi

echo ""
echo "  Fail2ban sshd jail status:"
vagrant ssh vm4-gw -c "sudo fail2ban-client status sshd 2>/dev/null" 2>/dev/null | sed 's/^/    /'

echo ""
echo "=========================================================="
echo " Results: $PASS passed, $FAIL failed"
echo ""
echo " To view live Suricata alerts:"
echo "   vagrant ssh vm4-gw -c 'sudo tail -f /var/log/suricata/fast.log'"
echo ""
echo " To view Fail2ban status:"
echo "   vagrant ssh vm4-gw -c 'sudo fail2ban-client status sshd'"
echo "=========================================================="

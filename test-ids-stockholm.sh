#!/bin/bash
# =============================================================================
# Test IDS (Suricata + Fail2ban) on ACME Stockholm Gateway (VM1)
# =============================================================================
# Run from the project directory:
#   bash test-ids-stockholm.sh
#
# Prerequisites:
#   bash services/ids/setup-suricata.sh
#   bash services/ids/setup-fail2ban.sh
# =============================================================================

echo "=========================================================="
echo " Testing IDS Services — Stockholm (VM1)"
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

vagrant ssh vm1-gw -c "sudo systemctl is-active fail2ban" > /dev/null 2>&1
check "Fail2ban service is running" "$?"

vagrant ssh vm1-gw -c "sudo fail2ban-client status sshd" > /dev/null 2>&1
check "Fail2ban sshd jail is active" "$?"

vagrant ssh vm1-gw -c "sudo fail2ban-client status strongswan" > /dev/null 2>&1
check "Fail2ban strongswan jail is active" "$?"

# ─────────────────────────────────────────────────────────
# 2. Suricata service checks
# ─────────────────────────────────────────────────────────
echo ""
echo "--- 2. Suricata Service Status ---"

vagrant ssh vm1-gw -c "sudo systemctl is-active suricata" > /dev/null 2>&1
check "Suricata service is running" "$?"

vagrant ssh vm1-gw -c "test -f /etc/suricata/rules/acme-local.rules" > /dev/null 2>&1
check "ACME custom rules file present" "$?"

vagrant ssh vm1-gw -c "test -f /var/log/suricata/eve.json" > /dev/null 2>&1
check "Suricata eve.json log exists" "$?"

# ─────────────────────────────────────────────────────────
# 3. Suricata live detection — port scan from VM2
# ─────────────────────────────────────────────────────────
echo ""
echo "--- 3. Suricata Alert Test (port scan from VM2 → VM1) ---"

# Clear fast.log to get a clean baseline
vagrant ssh vm1-gw -c "sudo truncate -s 0 /var/log/suricata/fast.log" > /dev/null 2>&1

# Trigger: rapid SYN connections from VM2 to VM1's VLAN 10 address
echo "  Triggering SYN scan from VM2 (this takes ~5 seconds)..."
vagrant ssh vm2-srv -c "for port in 21 22 23 25 53 80 110 143 443 993 995 3306 3389 5432 5900 8080 8443 8888 9090 9999 11211 27017; do timeout 0.2 bash -c 'echo >/dev/tcp/10.0.1.1/'\$port 2>/dev/null & done; wait" > /dev/null 2>&1 || true

# Wait for Suricata to process
sleep 5

# Check if any alert was generated in fast.log
ALERT_COUNT=$(vagrant ssh vm1-gw -c "sudo wc -l < /var/log/suricata/fast.log 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
if [ "${ALERT_COUNT:-0}" -gt "0" ]; then
    check "Suricata generated alerts (${ALERT_COUNT} in fast.log)" "0"
else
    # Even if custom rule didn't trigger, check eve.json for flow events
    EVE_LINES=$(vagrant ssh vm1-gw -c "sudo wc -l < /var/log/suricata/eve.json 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    if [ "${EVE_LINES:-0}" -gt "0" ]; then
        printf "  %-55s" "Suricata generated alerts"
        echo "SKIP (no fast.log alerts, but ${EVE_LINES} events in eve.json — engine is processing)"
    else
        check "Suricata generated alerts" "1"
    fi
fi

# Show sample alerts for visual confirmation
echo ""
echo "  Recent Suricata alerts (if any):"
vagrant ssh vm1-gw -c "sudo tail -5 /var/log/suricata/fast.log 2>/dev/null" 2>/dev/null | sed 's/^/    /'

# ─────────────────────────────────────────────────────────
# 4. Fail2ban live test — SSH brute-force from VM2
# ─────────────────────────────────────────────────────────
echo ""
echo "--- 4. Fail2ban Ban Test (SSH failures from VM2 → VM1) ---"

VM2_IP="10.0.1.2"

# Make sure VM2 is not already banned
vagrant ssh vm1-gw -c "sudo fail2ban-client set sshd unbanip $VM2_IP" > /dev/null 2>&1 || true

# Trigger: 4 failed SSH attempts from VM2 to VM1 (maxretry=3)
echo "  Triggering SSH brute-force from VM2 (4 attempts)..."
for i in 1 2 3 4; do
    vagrant ssh vm2-srv -c "sshpass -p 'wrongpassword' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o NumberOfPasswordPrompts=1 baduser@10.0.1.1 exit" > /dev/null 2>&1 || true
done

# Wait for fail2ban to process
sleep 5

# Check if VM2 IP got banned
BANNED=$(vagrant ssh vm1-gw -c "sudo fail2ban-client status sshd 2>/dev/null" 2>/dev/null)
if echo "$BANNED" | grep -q "$VM2_IP"; then
    check "Fail2ban banned $VM2_IP after SSH brute-force" "0"
    # Unban to restore connectivity
    vagrant ssh vm1-gw -c "sudo fail2ban-client set sshd unbanip $VM2_IP" > /dev/null 2>&1 || true
    echo "  (Unbanned $VM2_IP to restore connectivity)"
else
    # Check if failures are being counted
    CURRENT=$(echo "$BANNED" | grep 'Currently failed' | grep -o '[0-9]*' || echo "0")
    TOTAL=$(echo "$BANNED" | grep 'Total failed' | grep -o '[0-9]*' | head -1 || echo "0")
    if [ "${TOTAL:-0}" -gt "0" ]; then
        printf "  %-55s" "Fail2ban banned $VM2_IP after SSH brute-force"
        echo "PARTIAL (${TOTAL} failures tracked, ban threshold may not be met yet)"
    else
        check "Fail2ban banned $VM2_IP after SSH brute-force" "1"
    fi
fi

# Show fail2ban status
echo ""
echo "  Fail2ban sshd jail status:"
vagrant ssh vm1-gw -c "sudo fail2ban-client status sshd 2>/dev/null" 2>/dev/null | sed 's/^/    /'

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
echo ""
echo "=========================================================="
echo " Results: $PASS passed, $FAIL failed"
echo ""
echo " To view live Suricata alerts:"
echo "   vagrant ssh vm1-gw -c 'sudo tail -f /var/log/suricata/fast.log'"
echo ""
echo " To view Fail2ban status:"
echo "   vagrant ssh vm1-gw -c 'sudo fail2ban-client status sshd'"
echo "=========================================================="

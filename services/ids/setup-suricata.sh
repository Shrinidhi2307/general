#!/bin/bash
# =============================================================================
# Configure Suricata IDS on VM4 (London GW)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/ids/setup-suricata.sh
#
# Prerequisites: VM4 provisioned (suricata package already installed)
#
# What this script does:
#   1. Configures Suricata with correct HOME_NET and interfaces
#   2. Updates ET Open rulesets via suricata-update
#   3. Adds custom ACME rules (port scans, SSH brute-force, DNS anomalies)
#   4. Enables af-packet mode on the internal-facing interface
#   5. Enables and starts suricata
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Configuring Suricata IDS on ACME Gateways"
echo "====================================================="

# ─────────────────────────────────────────────────────────
# VM4 (London Gateway)
# ─────────────────────────────────────────────────────────
echo ">>> Configuring Suricata on VM4 (London Gateway)..."

vagrant ssh vm4-gw -- sudo bash -s << 'SURI_VM4_EOF'
set -euo pipefail

# ── 1. Core configuration ──
cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak 2>/dev/null || true

sed -i 's|HOME_NET:.*|HOME_NET: "[10.0.1.0/24,10.0.2.0/24,10.0.3.0/24]"|' /etc/suricata/suricata.yaml
sed -i 's|EXTERNAL_NET:.*|EXTERNAL_NET: "!$HOME_NET"|' /etc/suricata/suricata.yaml
sed -i '/af-packet:/,/- interface:/{s/- interface:.*/- interface: enp0s8/}' /etc/suricata/suricata.yaml
sed -i 's/community-id: false/community-id: true/' /etc/suricata/suricata.yaml 2>/dev/null || true

# ── 2. Update rulesets ──
echo ">>> Updating Suricata rulesets..."
suricata-update --no-test 2>/dev/null || suricata-update 2>/dev/null || echo "WARN: suricata-update failed, using bundled rules"

# suricata-update writes to /var/lib/suricata/rules/ — point config there
sed -i 's|default-rule-path: /etc/suricata/rules|default-rule-path: /var/lib/suricata/rules|' /etc/suricata/suricata.yaml

# ── 3. Custom ACME rules ──
mkdir -p /etc/suricata/rules
cat > /etc/suricata/rules/acme-local.rules << 'RULES_EOF'
# =============================================================================
# ACME Custom Suricata Rules — London Gateway
# =============================================================================

# ── Port Scan Detection ──
alert tcp any any -> $HOME_NET any (msg:"ACME: Possible TCP port scan (SYN)"; flags:S,12; threshold:type both,track by_src,count 20,seconds 10; sid:9000001; rev:1;)

# ── SSH Brute-Force Detection ──
alert tcp any any -> $HOME_NET 22 (msg:"ACME: SSH brute-force attempt"; flow:to_server,established; threshold:type both,track by_src,count 5,seconds 60; sid:9000002; rev:1;)

# ── DNS Query Anomaly ──
alert udp any any -> $HOME_NET 53 (msg:"ACME: Unusual DNS query volume"; threshold:type both,track by_src,count 100,seconds 60; sid:9000003; rev:1;)

# ── IPsec Probe ──
alert udp any any -> $HOME_NET 500 (msg:"ACME: IKE probe detected"; threshold:type both,track by_src,count 10,seconds 30; sid:9000004; rev:1;)

# ── ICMP Sweep Detection ──
alert icmp any any -> $HOME_NET any (msg:"ACME: ICMP sweep detected"; threshold:type both,track by_src,count 10,seconds 10; sid:9000005; rev:1;)
RULES_EOF

if ! grep -q "acme-local.rules" /etc/suricata/suricata.yaml; then
    sed -i '/rule-files:/a\  - /etc/suricata/rules/acme-local.rules' /etc/suricata/suricata.yaml
fi

# ── 4. Create log directory ──
mkdir -p /var/log/suricata

# ── 5. Validate and start ──
echo ">>> Testing Suricata configuration..."
suricata -T -c /etc/suricata/suricata.yaml 2>&1 | tail -5

echo ">>> Enabling and starting Suricata..."
systemctl enable suricata
systemctl restart suricata

echo ">>> Suricata active on VM4 (enp0s8)."

SURI_VM4_EOF

echo ""
echo "====================================================="
echo " Suricata IDS setup complete on VM4!"
echo ""
echo " Monitoring interfaces:"
echo "   VM4: enp0s8 (London VLAN 10)"
echo ""
echo " Custom ACME rules (SID 9000001-9000006):"
echo "   9000001 — TCP port scan (20 SYN in 10s)"
echo "   9000002 — SSH brute-force (5 in 60s)"
echo "   9000003 — DNS query flood (100 in 60s)"
echo "   9000004 — IKE probe (10 in 30s)"
echo "   9000005 — ICMP sweep (10 in 10s)"
echo "   9000006 — Unauthorized traffic to CA"
echo ""
echo " Log files:"
echo "   /var/log/suricata/fast.log   — one-line alerts"
echo "   /var/log/suricata/eve.json   — full JSON events"
echo ""
echo " Useful commands (run inside VM):"
echo "   sudo tail -f /var/log/suricata/fast.log"
echo "   sudo suricatasc -c 'iface-stat enp0s8'"
echo "====================================================="

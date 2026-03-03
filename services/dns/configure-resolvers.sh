#!/bin/bash
# =============================================================================
# Configure all Stockholm VMs to use VM2 (10.0.1.2) as DNS resolver
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/dns/configure-resolvers.sh
#
# Prerequisites:
#   bash services/dns/setup-dns.sh  (BIND9 running on VM2)
#
# Uses a systemd-resolved drop-in so that:
#   - acme.internal queries  → VM2 (10.0.1.2)
#   - everything else        → existing upstream (unchanged)
# =============================================================================
set -euo pipefail

configure_vm() {
    local vm="$1"
    local self_dns="$2"   # "yes" if this VM IS the DNS server (use 127.0.0.1)

    echo ">>> Configuring DNS resolver on ${vm}..."

    local dns_addr="10.0.1.2"
    [ "$self_dns" = "yes" ] && dns_addr="127.0.0.1"

    vagrant ssh "$vm" -- sudo bash -s << DNS_EOF
set -euo pipefail

mkdir -p /etc/systemd/resolved.conf.d

cat > /etc/systemd/resolved.conf.d/acme-dns.conf << 'CONF_EOF'
[Resolve]
# Route acme.internal queries to VM2 (internal BIND9)
DNS=${dns_addr}
Domains=acme.internal
CONF_EOF

systemctl restart systemd-resolved

echo "  Resolver configured. Testing..."
resolvectl query vm2.acme.internal 2>/dev/null \
    && echo "  OK: vm2.acme.internal resolved" \
    || echo "  WARN: could not resolve vm2.acme.internal yet (bind9 may need a moment)"

DNS_EOF
}

echo "====================================================="
echo " Configuring DNS resolvers — Stockholm VMs"
echo "====================================================="

configure_vm "vm1-gw"  "no"
configure_vm "vm2-srv" "yes"   # VM2 is the DNS server; use loopback
configure_vm "vm3-ca"  "no"
configure_vm "vm6-dmz" "no"

echo ""
echo "====================================================="
echo " Done. Verify from each VM with:"
echo "   vagrant ssh vm1-gw -c 'dig critical.acme.internal'"
echo "   vagrant ssh vm1-gw -c 'curl -k https://critical.acme.internal'"
echo "====================================================="

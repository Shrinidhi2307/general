#!/bin/bash
# =============================================================================
# Configure BIND9 + DNSSEC on VM2 (Stockholm Server)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/dns/setup-dns.sh
#
# Prerequisites:
#   - VM2 provisioned (bind9 + bind9utils installed)
#
# What this script does:
#   1. Writes named.conf.options  (listen-on, ACLs, forwarders, DNSSEC)
#   2. Writes named.conf.local    (zone declarations with inline-signing)
#   3. Creates zone files         (acme.internal + reverse)
#   4. Generates DNSSEC keys      (KSK + ZSK, ECDSAP256SHA256)
#   5. Validates config + restarts bind9
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Setting up BIND9 + DNSSEC on VM2"
echo "====================================================="

vagrant ssh vm2-srv -- sudo bash -s << 'DNS_EOF'
set -euo pipefail

ZONE="acme.internal"
ZONE_DIR="/etc/bind/zones"
KEY_DIR="/etc/bind/keys/${ZONE}"
SERIAL="2026030301"

# ── 1. named.conf.options ──────────────────────────────────────────────────
echo ">>> Writing named.conf.options..."
cat > /etc/bind/named.conf.options << 'CONF_EOF'
acl "internal" {
    127.0.0.0/8;
    10.0.1.0/24;   /* Stockholm */
    10.0.2.0/24;   /* London */
    10.0.3.0/24;   /* VPN pool */
};

options {
    directory "/var/cache/bind";

    /* Only listen on internal interface and loopback */
    listen-on { 127.0.0.1; 10.0.1.2; };
    listen-on-v6 { none; };

    /* Allow queries only from internal networks */
    allow-query     { internal; };
    allow-recursion { internal; };

    /* Forward external queries upstream */
    forwarders { 1.1.1.1; 8.8.8.8; };
    forward first;

    /* DNSSEC */
    dnssec-validation auto;

    /* Disable zone transfers (no secondary DNS in this setup) */
    allow-transfer { none; };
};
CONF_EOF

# ── 2. named.conf.local ───────────────────────────────────────────────────
echo ">>> Writing named.conf.local..."
cat > /etc/bind/named.conf.local << 'LOCAL_EOF'
/* Forward zone */
zone "acme.internal" {
    type master;
    file "/etc/bind/zones/db.acme.internal";
    key-directory "/etc/bind/keys/acme.internal";
    dnssec-policy default;
    inline-signing yes;
    allow-query { internal; };
};

/* Reverse zone for 10.0.1.0/26 (Stockholm VLAN 10) */
zone "1.0.10.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.10.0.1";
    key-directory "/etc/bind/keys/acme.internal";
    dnssec-policy default;
    inline-signing yes;
    allow-query { internal; };
};
LOCAL_EOF

# ── 3. Zone files ─────────────────────────────────────────────────────────
echo ">>> Creating zone directory and zone files..."
mkdir -p "$ZONE_DIR"

# Forward zone
cat > "${ZONE_DIR}/db.acme.internal" << ZONE_EOF
\$ORIGIN acme.internal.
\$TTL 300

@ IN SOA vm2.acme.internal. admin.acme.internal. (
    ${SERIAL} ; serial (YYYYMMDDNN)
    3600       ; refresh
    900        ; retry
    604800     ; expire
    300        ; minimum TTL / negative cache TTL
)

; Name servers
@       IN NS  vm2.acme.internal.

; Stockholm hosts
vm1     IN A   10.0.1.1
vm2     IN A   10.0.1.2
vm3     IN A   10.0.1.3
vm6     IN A   10.0.1.242

; London hosts
vm4     IN A   10.0.2.1
vm5     IN A   10.0.2.2

; Web vhosts (both on VM2)
critical    IN A   10.0.1.2
portal      IN A   10.0.1.2
ZONE_EOF

# Reverse zone
cat > "${ZONE_DIR}/db.10.0.1" << REV_EOF
\$ORIGIN 1.0.10.in-addr.arpa.
\$TTL 300

@ IN SOA vm2.acme.internal. admin.acme.internal. (
    ${SERIAL} ; serial
    3600
    900
    604800
    300
)

@   IN NS  vm2.acme.internal.

1   IN PTR vm1.acme.internal.
2   IN PTR vm2.acme.internal.
3   IN PTR vm3.acme.internal.
242 IN PTR vm6.acme.internal.
REV_EOF

# Correct ownership so bind can read zone files
chown -R bind:bind "$ZONE_DIR"

# ── 4. DNSSEC key directory ───────────────────────────────────────────────
# With dnssec-policy, BIND 9.16+ manages key generation and rotation itself.
# We only need to create the directory with correct ownership.
echo ">>> Creating DNSSEC key directory..."
mkdir -p "$KEY_DIR"
chown -R bind:bind "$KEY_DIR"
chmod 750 "$KEY_DIR"

# ── 5. Validate config + restart ──────────────────────────────────────────
echo ">>> Validating named configuration..."
named-checkconf
named-checkzone "$ZONE" "${ZONE_DIR}/db.acme.internal"
named-checkzone "1.0.10.in-addr.arpa" "${ZONE_DIR}/db.10.0.1"

echo ">>> Restarting bind9..."
systemctl restart named
systemctl enable named

echo ""
echo ">>> BIND9 + DNSSEC setup complete."
echo "    Test with:"
echo "      dig @10.0.1.2 vm2.acme.internal"
echo "      dig +dnssec @10.0.1.2 acme.internal SOA"

DNS_EOF

echo ""
echo "====================================================="
echo " DNS setup complete!"
echo " Run these from the host to verify:"
echo "   vagrant ssh vm2-srv -c 'dig @10.0.1.2 critical.acme.internal'"
echo "   vagrant ssh vm2-srv -c 'dig +dnssec @10.0.1.2 acme.internal SOA | grep RRSIG'"
echo "====================================================="

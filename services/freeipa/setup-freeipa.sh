#!/bin/bash
# =============================================================================
# Install and configure FreeIPA on VM2 (Stockholm Server)
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/freeipa/setup-freeipa.sh
#
# ⚠️  WARNING: This takes 10-15 minutes and is NOT idempotent.
#             Do not re-run on an already-configured server.
#             To start over: vagrant destroy vm2-srv && vagrant up vm2-srv
#
# Prerequisites:
#   - DNS must be working: bash services/dns/setup-dns.sh
#   - DNS resolvers configured: bash services/dns/configure-resolvers.sh
#   - VM2 provisioned with at least 8 GB RAM
#
# What this script does:
#   Phase 1 — Install
#     1. Sets hostname to vm2.acme.internal
#     2. Installs freeipa-server package (~500 MB)
#     3. Runs ipa-server-install (unattended, no IPA-managed DNS)
#   Phase 2 — Bootstrap
#     4. Creates employee groups: acme-employees, acme-admins
#     5. Creates HBAC rules: employees can SSH to VM2, VM3, VM6
#     6. Creates a sample user (alice) to verify enrollment works
#   Phase 3 — Integrate
#     7. Adds VM2 DNS SRV records for Kerberos/LDAP so IPA clients
#        can discover the server via our existing BIND9
# =============================================================================
set -euo pipefail

# Change these before deploying in a real environment
IPA_ADMIN_PASSWORD="ACMEipa2026!"
IPA_DS_PASSWORD="ACMEipa2026!"
IPA_REALM="ACME.INTERNAL"
IPA_DOMAIN="acme.internal"
IPA_HOSTNAME="vm2.acme.internal"
IPA_IP="10.0.1.2"

echo "====================================================="
echo " Installing FreeIPA on VM2"
echo " Realm:  ${IPA_REALM}"
echo " Domain: ${IPA_DOMAIN}"
echo " This will take 10-15 minutes..."
echo "====================================================="

# ── Phase 1: Install ──────────────────────────────────────────────────────
vagrant ssh vm2-srv -- sudo bash -s << INSTALL_EOF
set -euo pipefail

# ── 1. Hostname ───────────────────────────────────────────────────────────
echo ">>> Setting hostname to ${IPA_HOSTNAME}..."
hostnamectl set-hostname "${IPA_HOSTNAME}"

# Ensure /etc/hosts has the FQDN (ipa-server-install checks this)
if ! grep -q "${IPA_IP}.*${IPA_HOSTNAME}" /etc/hosts; then
    echo "${IPA_IP} ${IPA_HOSTNAME} vm2" >> /etc/hosts
fi

# Verify forward resolution works (DNS must be up)
echo ">>> Verifying DNS resolution..."
host "${IPA_HOSTNAME}" 127.0.0.1 || {
    echo "ERROR: ${IPA_HOSTNAME} does not resolve."
    echo "Run services/dns/setup-dns.sh and services/dns/configure-resolvers.sh first."
    exit 1
}

# ── 2. Install packages ───────────────────────────────────────────────────
echo ">>> Installing freeipa-server (this will take a few minutes)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    freeipa-server \
    freeipa-server-common \
    python3-ipaserver

# ── 3. Run ipa-server-install ─────────────────────────────────────────────
# --no-ntp          : Vagrant VMs sync time via the host, no chrony needed
# No --setup-dns    : We keep our own BIND9; FreeIPA uses it for resolution
# --no-host-dns     : Skip reverse DNS check (our reverse zone may not have PTR yet)
echo ">>> Running ipa-server-install (unattended)..."
ipa-server-install \
    --unattended \
    --realm="${IPA_REALM}" \
    --domain="${IPA_DOMAIN}" \
    --hostname="${IPA_HOSTNAME}" \
    --ip-address="${IPA_IP}" \
    --admin-password="${IPA_ADMIN_PASSWORD}" \
    --ds-password="${IPA_DS_PASSWORD}" \
    --no-ntp \
    --no-host-dns \
    --mkhomedir

echo ">>> ipa-server-install complete."

INSTALL_EOF

echo ""
echo ">>> Phase 1 complete. Moving to bootstrap..."

# ── Phase 2: Bootstrap users, groups, HBAC ───────────────────────────────
vagrant ssh vm2-srv -- sudo bash -s << BOOTSTRAP_EOF
set -euo pipefail

# Authenticate as IPA admin
echo "${IPA_ADMIN_PASSWORD}" | kinit admin 2>/dev/null || {
    echo "ERROR: kinit failed — IPA may not have started correctly."
    echo "Check: ipactl status"
    exit 1
}

echo ">>> IPA authenticated. Bootstrapping..."

# ── Groups ────────────────────────────────────────────────────────────────
echo ">>> Creating groups..."

ipa group-add acme-employees \
    --desc="All ACME Scandinavia employees" 2>/dev/null \
    || echo "  group acme-employees already exists"

ipa group-add acme-admins \
    --desc="ACME IT administrators" 2>/dev/null \
    || echo "  group acme-admins already exists"

# Make acme-admins a member of acme-employees
ipa group-add-member acme-employees --groups=acme-admins 2>/dev/null || true

# ── HBAC rules ────────────────────────────────────────────────────────────
# First disable the default catch-all "allow_all" rule (zero-trust)
echo ">>> Disabling default allow_all HBAC rule..."
ipa hbacrule-disable allow_all 2>/dev/null || true

echo ">>> Creating HBAC rules..."

# Employees can SSH to vm2 (this server)
ipa hbacrule-add allow-employees-vm2 \
    --desc="Employees can SSH to the main server" \
    --servicecat=all 2>/dev/null \
    || echo "  hbacrule allow-employees-vm2 already exists"
ipa hbacrule-add-user  allow-employees-vm2 --groups=acme-employees 2>/dev/null || true
ipa hbacrule-add-host  allow-employees-vm2 --hosts="${IPA_HOSTNAME}"  2>/dev/null || true

# Admins can SSH to vm3 (CA — air-gapped)
ipa hbacrule-add allow-admins-vm3 \
    --desc="Admins can SSH to the CA server" \
    --servicecat=all 2>/dev/null \
    || echo "  hbacrule allow-admins-vm3 already exists"
ipa hbacrule-add-user allow-admins-vm3 --groups=acme-admins 2>/dev/null || true
ipa hbacrule-add-host allow-admins-vm3 --hosts="vm3.acme.internal" 2>/dev/null || true

# ── Sample user: alice ────────────────────────────────────────────────────
echo ">>> Creating sample user: alice..."
ipa user-add alice \
    --first="Alice" \
    --last="ACME" \
    --email="alice@acme.internal" \
    --password 2>/dev/null << 'PASS_EOF' \
    || echo "  user alice already exists"
TempPass2026!
TempPass2026!
PASS_EOF

ipa group-add-member acme-employees --users=alice 2>/dev/null || true

echo ""
echo "IPA users:"
ipa user-find --all | grep "User login:"
echo ""
echo "IPA groups:"
ipa group-find | grep "Group name:"
echo ""
echo "HBAC rules:"
ipa hbacrule-find | grep "Rule name:"

kdestroy 2>/dev/null || true

BOOTSTRAP_EOF

echo ""
echo ">>> Phase 2 complete. Adding DNS service records..."

# ── Phase 3: Add Kerberos/LDAP SRV records to BIND9 so IPA clients ────────
# can discover the IPA server through our existing DNS.
vagrant ssh vm2-srv -- sudo bash -s << 'DNS_EOF'
set -euo pipefail

ZONE_FILE="/etc/bind/zones/db.acme.internal"

# Check if SRV records already added
if grep -q "_kerberos" "$ZONE_FILE"; then
    echo ">>> IPA SRV records already in zone file."
else
    echo ">>> Adding Kerberos/LDAP SRV records to BIND9 zone..."

    # Bump the serial (increment last two digits)
    CURRENT_SERIAL=$(grep -oP '\d{10}(?=\s*; serial)' "$ZONE_FILE")
    NEW_SERIAL=$((CURRENT_SERIAL + 1))
    sed -i "s/${CURRENT_SERIAL}/${NEW_SERIAL}/" "$ZONE_FILE"

    # Append SRV records before end of file
    cat >> "$ZONE_FILE" << 'SRV_EOF'

; FreeIPA service discovery records
_kerberos._tcp      IN SRV 0 100 88  vm2.acme.internal.
_kerberos._udp      IN SRV 0 100 88  vm2.acme.internal.
_kerberos-master._tcp IN SRV 0 100 88 vm2.acme.internal.
_kerberos-master._udp IN SRV 0 100 88 vm2.acme.internal.
_kpasswd._tcp       IN SRV 0 100 464 vm2.acme.internal.
_kpasswd._udp       IN SRV 0 100 464 vm2.acme.internal.
_ldap._tcp          IN SRV 0 100 389 vm2.acme.internal.
_kerberos           IN TXT "ACME.INTERNAL"
SRV_EOF

    named-checkzone acme.internal "$ZONE_FILE" \
        && systemctl reload named \
        && echo ">>> BIND9 zone updated with IPA service records." \
        || echo "WARN: Zone check failed — check $ZONE_FILE"
fi

DNS_EOF

echo ""
echo "====================================================="
echo " FreeIPA setup complete!"
echo ""
echo " IPA Web UI:  https://${IPA_HOSTNAME}/ipa/ui"
echo "   (accessible from host via port-forward or inside VM)"
echo " Admin user:  admin / ${IPA_ADMIN_PASSWORD}"
echo ""
echo " Sample user created: alice (password: TempPass2026!)"
echo " She must change it on first login."
echo ""
echo " Enroll other VMs as IPA clients:"
echo "   vagrant ssh vm3-ca -- sudo ipa-client-install \\"
echo "     --domain=${IPA_DOMAIN} --server=${IPA_HOSTNAME} \\"
echo "     --principal=admin --password='${IPA_ADMIN_PASSWORD}' \\"
echo "     --mkhomedir --unattended"
echo ""
echo " Verify HBAC (from VM2 as admin):"
echo "   vagrant ssh vm2-srv -c 'echo ${IPA_ADMIN_PASSWORD} | kinit admin'"
echo "   vagrant ssh vm2-srv -c 'ipa hbacrule-find'"
echo "====================================================="

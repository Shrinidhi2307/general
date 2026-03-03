#!/bin/bash
# =============================================================================
# Issue a client certificate for an ACME employee
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/certs/issue-client.sh <name>
#
# Example:
#   bash services/certs/issue-client.sh alice
#   bash services/certs/issue-client.sh testuser
#
# Output (in services/certs/clients/):
#   <name>.crt   — client certificate
#   <name>.key   — private key
#   <name>.p12   — PKCS#12 bundle for browser/OS import
#
# The .p12 has no password (suitable for lab/demo use).
# For production, add: -passout pass:<password> to the openssl pkcs12 command.
# =============================================================================
set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
    echo "Usage: bash services/certs/issue-client.sh <name>"
    echo "  e.g: bash services/certs/issue-client.sh alice"
    exit 1
fi

CLIENT_DIR="services/certs/clients"
mkdir -p "$CLIENT_DIR"

echo "====================================================="
echo " Issuing client certificate for: ${NAME}"
echo "====================================================="

vagrant ssh vm3-ca -- sudo bash -s << CA_EOF
set -euo pipefail

CA_DIR="/root/easy-rsa"
EXPORT_DIR="/vagrant/services/certs/clients"
CERT_NAME="${NAME}"

mkdir -p "\$EXPORT_DIR"
cd "\$CA_DIR"

if [ ! -d "pki" ]; then
    echo "ERROR: EasyRSA PKI not initialised. Run services/vpn/setup-ca.sh first."
    exit 1
fi

# Generate client key + CSR
if [ ! -f "pki/reqs/\${CERT_NAME}.req" ]; then
    echo ">>> Generating key and CSR for \${CERT_NAME}..."
    EASYRSA_BATCH=1 \
    EASYRSA_REQ_CN="\${CERT_NAME}" \
        ./easyrsa gen-req "\${CERT_NAME}" nopass
else
    echo ">>> CSR already exists for \${CERT_NAME}, skipping keygen."
fi

# Sign as client certificate
if [ ! -f "pki/issued/\${CERT_NAME}.crt" ]; then
    echo ">>> Signing client certificate..."
    EASYRSA_BATCH=1 ./easyrsa sign-req client "\${CERT_NAME}"
else
    echo ">>> Certificate already signed for \${CERT_NAME}."
fi

# Export
echo ">>> Exporting to \${EXPORT_DIR}..."
cp "pki/issued/\${CERT_NAME}.crt"  "\${EXPORT_DIR}/\${CERT_NAME}.crt"
cp "pki/private/\${CERT_NAME}.key" "\${EXPORT_DIR}/\${CERT_NAME}.key"
chmod 644 "\${EXPORT_DIR}/\${CERT_NAME}.crt"
chmod 600 "\${EXPORT_DIR}/\${CERT_NAME}.key"

echo "Done. Files:"
ls -la "\${EXPORT_DIR}/\${CERT_NAME}".{crt,key}

CA_EOF

# Verify export landed
for f in "${NAME}.crt" "${NAME}.key"; do
    if [ ! -f "${CLIENT_DIR}/${f}" ]; then
        echo "ERROR: ${CLIENT_DIR}/${f} not found — CA step may have failed."
        exit 1
    fi
done

# Build a .p12 bundle for browser/OS import (no password for lab use)
echo ">>> Building PKCS#12 bundle..."
openssl pkcs12 -export \
    -in  "${CLIENT_DIR}/${NAME}.crt" \
    -inkey "${CLIENT_DIR}/${NAME}.key" \
    -certfile "services/certs/vm2/ca.crt" \
    -out "${CLIENT_DIR}/${NAME}.p12" \
    -passout pass: \
    -name "${NAME}@acme.internal" 2>/dev/null \
|| echo "Note: .p12 creation skipped (openssl not on host or ca.crt missing — run issue-vm2.sh first)"

echo ""
echo "====================================================="
echo " Client certificate ready for: ${NAME}"
echo ""
echo " Files in ${CLIENT_DIR}/:"
ls -la "${CLIENT_DIR}/${NAME}".* 2>/dev/null || true
echo ""
echo " Test mTLS against the portal (run from inside any VM on VLAN 10/20):"
echo "   curl --cacert /vagrant/services/certs/vm2/ca.crt \\"
echo "        --cert   /vagrant/services/certs/clients/${NAME}.crt \\"
echo "        --key    /vagrant/services/certs/clients/${NAME}.key \\"
echo "        https://critical.acme.internal"
echo ""
echo " Test that VPN clients are blocked from critical:"
echo "   curl ... --interface 10.0.3.x https://critical.acme.internal  → 403"
echo ""
echo " Import ${NAME}.p12 into your browser/OS keychain to test in a browser"
echo "   (also add the CA to your trust store: services/certs/vm2/ca.crt)"
echo "====================================================="

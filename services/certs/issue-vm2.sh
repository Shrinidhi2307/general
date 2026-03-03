#!/bin/bash
# =============================================================================
# Issue TLS server certificate for VM2 (Nginx) from VM3 CA
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/certs/issue-vm2.sh
#
# Prerequisites:
#   - VM3 CA must be set up: bash services/vpn/setup-ca.sh
#   - VM2 must be provisioned
#
# What this script does:
#   1. On VM3: generates a key + CSR for vm2.acme.internal
#              (SANs: vm2.acme.internal, critical.acme.internal, portal.acme.internal)
#   2. On VM3: signs the cert with the EasyRSA issuing CA
#   3. Exports to services/certs/vm2/ on the host (via /vagrant shared folder)
#   4. On VM2: deploys cert, key, and CA chain to /etc/nginx/certs/
# =============================================================================
set -euo pipefail

CERT_DIR="services/certs/vm2"

echo "====================================================="
echo " Issuing VM2 server certificate from VM3 CA"
echo "====================================================="

mkdir -p "$CERT_DIR"

# ── Step 1 & 2: Generate and sign cert on VM3 ────────────────────────────
echo ">>> Running on VM3 (CA)..."

vagrant ssh vm3-ca -- sudo bash -s << 'CA_EOF'
set -euo pipefail

CA_DIR="/root/easy-rsa"
EXPORT_DIR="/vagrant/services/certs/vm2"
CERT_NAME="vm2-server"

mkdir -p "$EXPORT_DIR"
cd "$CA_DIR"

if [ ! -d "pki" ]; then
    echo "ERROR: EasyRSA PKI not initialised on VM3."
    echo "Run: bash services/vpn/setup-ca.sh first."
    exit 1
fi

# Generate key + CSR for vm2-server (if not already done)
if [ ! -f "pki/reqs/${CERT_NAME}.req" ]; then
    echo ">>> Generating key and CSR for vm2-server..."
    EASYRSA_BATCH=1 \
    EASYRSA_REQ_CN="vm2.acme.internal" \
        ./easyrsa \
        --subject-alt-name="DNS:vm2.acme.internal,DNS:critical.acme.internal,DNS:portal.acme.internal" \
        gen-req "$CERT_NAME" nopass
else
    echo ">>> CSR already exists for ${CERT_NAME}, skipping keygen."
fi

# Sign the CSR as a server certificate
if [ ! -f "pki/issued/${CERT_NAME}.crt" ]; then
    echo ">>> Signing certificate..."
    EASYRSA_BATCH=1 \
        ./easyrsa \
        --subject-alt-name="DNS:vm2.acme.internal,DNS:critical.acme.internal,DNS:portal.acme.internal" \
        sign-req server "$CERT_NAME"
else
    echo ">>> Certificate already signed, skipping."
fi

# Export to shared folder
echo ">>> Exporting to ${EXPORT_DIR}..."
cp "pki/issued/${CERT_NAME}.crt"  "${EXPORT_DIR}/${CERT_NAME}.crt"
cp "pki/private/${CERT_NAME}.key" "${EXPORT_DIR}/${CERT_NAME}.key"
cp "pki/ca.crt"                   "${EXPORT_DIR}/ca.crt"

chmod 644 "${EXPORT_DIR}/${CERT_NAME}.crt"
chmod 644 "${EXPORT_DIR}/ca.crt"
chmod 600 "${EXPORT_DIR}/${CERT_NAME}.key"

echo ""
echo "Exported files:"
ls -la "$EXPORT_DIR"

CA_EOF

# Verify host-side export landed correctly
echo ""
echo ">>> Verifying exported files on host..."
for f in vm2-server.crt vm2-server.key ca.crt; do
    if [ -f "${CERT_DIR}/${f}" ]; then
        echo "  OK: ${CERT_DIR}/${f}"
    else
        echo "  ERROR: ${CERT_DIR}/${f} not found — CA step may have failed."
        exit 1
    fi
done

# Show cert details for verification
echo ""
echo ">>> Certificate details:"
openssl x509 -noout -subject -issuer -dates -ext subjectAltName \
    -in "${CERT_DIR}/vm2-server.crt" 2>/dev/null || true

# ── Step 4: Deploy to VM2 ─────────────────────────────────────────────────
echo ""
echo ">>> Deploying certificates to VM2..."

vagrant ssh vm2-srv -- sudo bash -s << 'DEPLOY_EOF'
set -euo pipefail

NGINX_CERT_DIR="/etc/nginx/certs"
SRC_DIR="/vagrant/services/certs/vm2"

# Create cert directory with strict permissions
mkdir -p "$NGINX_CERT_DIR"
chown root:www-data "$NGINX_CERT_DIR"
chmod 750 "$NGINX_CERT_DIR"

# Deploy cert and CA (readable by nginx)
cp "${SRC_DIR}/vm2-server.crt" "${NGINX_CERT_DIR}/vm2-server.crt"
cp "${SRC_DIR}/ca.crt"         "${NGINX_CERT_DIR}/ca.crt"
chown root:www-data "${NGINX_CERT_DIR}/vm2-server.crt" "${NGINX_CERT_DIR}/ca.crt"
chmod 640 "${NGINX_CERT_DIR}/vm2-server.crt" "${NGINX_CERT_DIR}/ca.crt"

# Deploy private key (root only — nginx reads via root-run master process)
cp "${SRC_DIR}/vm2-server.key" "${NGINX_CERT_DIR}/vm2-server.key"
chown root:root "${NGINX_CERT_DIR}/vm2-server.key"
chmod 600 "${NGINX_CERT_DIR}/vm2-server.key"

echo ""
echo "Deployed to ${NGINX_CERT_DIR}:"
ls -la "$NGINX_CERT_DIR"

# Verify cert is readable and valid
echo ""
echo "Certificate subject:"
openssl x509 -noout -subject -issuer -dates \
    -in "${NGINX_CERT_DIR}/vm2-server.crt"

echo ""
echo "SANs:"
openssl x509 -noout -ext subjectAltName \
    -in "${NGINX_CERT_DIR}/vm2-server.crt"

DEPLOY_EOF

echo ""
echo "====================================================="
echo " VM2 certificate deployment complete!"
echo ""
echo " Files on VM2 at /etc/nginx/certs/:"
echo "   vm2-server.crt  — TLS server certificate (SANs: critical + portal)"
echo "   vm2-server.key  — Private key (root:root, 600)"
echo "   ca.crt          — ACME CA certificate (for mTLS client verification)"
echo ""
echo " Local copies in: ${CERT_DIR}/"
echo ""
echo " Next step: configure Nginx vhosts (step 4 in plan-vm2.md)"
echo "====================================================="

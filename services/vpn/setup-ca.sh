#!/bin/bash
# =============================================================================
# Setup PKI on VM3 (Air-gapped CA) using EasyRSA
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/setup-ca.sh
#
# This script:
#   1. Initialises EasyRSA PKI on VM3
#   2. Builds a root CA (ACME-CA)
#   3. Generates & signs certs for Stockholm (VM1) and London gateways
#   4. Exports certs + keys to /vagrant/services/vpn/certs/ (shared folder)
# =============================================================================
set -euo pipefail

CERT_DIR="services/vpn/certs"

echo "====================================================="
echo " Setting up PKI on VM3 (CA) for IPsec"
echo "====================================================="

# Create local cert output directory
mkdir -p "$CERT_DIR"

# Run all PKI operations on VM3
vagrant ssh vm3-ca -- sudo bash -s << 'CA_EOF'
set -euo pipefail

CA_DIR="/root/easy-rsa"
EXPORT_DIR="/vagrant/services/vpn/certs"

# ── Create CA working directory (Ubuntu way) ──
if [ ! -d "$CA_DIR" ]; then
    echo ">>> Creating EasyRSA working directory..."
    make-cadir "$CA_DIR"
fi

cd "$CA_DIR"
PKI_DIR="$CA_DIR/pki"

# ── Initialise PKI ──
if [ ! -d "$PKI_DIR" ]; then
    echo ">>> Initialising EasyRSA PKI..."
    EASYRSA_BATCH=1 ./easyrsa init-pki
fi

# ── Build CA ──
if [ ! -f "$PKI_DIR/ca.crt" ]; then
    echo ">>> Building CA (CN=ACME-CA)..."
    EASYRSA_BATCH=1 EASYRSA_REQ_CN="ACME-CA" ./easyrsa build-ca nopass
else
    echo ">>> CA already exists, skipping..."
fi

# ── Generate & Sign Stockholm Gateway Cert ──
if [ ! -f "$PKI_DIR/issued/stockholm.crt" ]; then
    echo ">>> Generating Stockholm gateway certificate..."
    EASYRSA_BATCH=1 EASYRSA_REQ_CN="stockholm.acme.corp" ./easyrsa gen-req stockholm nopass
    EASYRSA_BATCH=1 ./easyrsa sign-req server stockholm
else
    echo ">>> Stockholm cert already exists, skipping..."
fi

# ── Generate & Sign London Gateway Cert ──
if [ ! -f "$PKI_DIR/issued/london.crt" ]; then
    echo ">>> Generating London gateway certificate..."
    EASYRSA_BATCH=1 EASYRSA_REQ_CN="london.acme.corp" ./easyrsa gen-req london nopass
    EASYRSA_BATCH=1 ./easyrsa sign-req server london
else
    echo ">>> London cert already exists, skipping..."
fi

# ── Export Certificates and Keys ──
echo ">>> Exporting certificates to shared folder..."
mkdir -p "$EXPORT_DIR"

cp "$PKI_DIR/ca.crt"                "$EXPORT_DIR/ca.crt"
cp "$PKI_DIR/issued/stockholm.crt"  "$EXPORT_DIR/stockholm.crt"
cp "$PKI_DIR/private/stockholm.key" "$EXPORT_DIR/stockholm.key"
cp "$PKI_DIR/issued/london.crt"     "$EXPORT_DIR/london.crt"
cp "$PKI_DIR/private/london.key"    "$EXPORT_DIR/london.key"

chmod 644 "$EXPORT_DIR"/*.crt
chmod 600 "$EXPORT_DIR"/*.key

echo ">>> PKI setup complete. Certificates exported to $EXPORT_DIR"
ls -la "$EXPORT_DIR"

CA_EOF

echo ""
echo "====================================================="
echo " CA Setup Complete!"
echo " Certificates are in: $CERT_DIR/"
echo "   ca.crt          — Root CA certificate"
echo "   stockholm.crt   — Stockholm gateway certificate"
echo "   stockholm.key   — Stockholm gateway private key"
echo "   london.crt      — London gateway certificate"
echo "   london.key      — London gateway private key"
echo "====================================================="

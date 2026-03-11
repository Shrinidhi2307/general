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
#   3. Exports CA cert to /vagrant/services/vpn/certs/ (shared folder)
# =============================================================================
set -euo pipefail

CERT_DIR="services/vpn/certs"

echo "====================================================="
echo " Setting up PKI on VM3 (CA)"
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

# ── Export CA Certificate ──
echo ">>> Exporting CA certificate to shared folder..."
mkdir -p "$EXPORT_DIR"

cp "$PKI_DIR/ca.crt" "$EXPORT_DIR/ca.crt"
chmod 644 "$EXPORT_DIR/ca.crt"

echo ">>> PKI setup complete. CA certificate exported to $EXPORT_DIR"
ls -la "$EXPORT_DIR/ca.crt"

CA_EOF

echo ""
echo "====================================================="
echo " CA Setup Complete!"
echo " CA certificate is in: $CERT_DIR/ca.crt"
echo "====================================================="

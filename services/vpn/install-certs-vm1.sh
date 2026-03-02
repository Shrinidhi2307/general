#!/bin/bash
# =============================================================================
# Install IPsec Certificates on VM1 (Stockholm Gateway)
# =============================================================================
# Copies CA cert, Stockholm cert/key to the correct StrongSwan directories.
# Run from the project directory:
#   bash services/vpn/install-certs-vm1.sh
# =============================================================================
set -euo pipefail

CERT_DIR="services/vpn/certs"

echo ">>> Installing IPsec certificates on VM1..."

# Verify certs exist locally
for f in ca.crt stockholm.crt stockholm.key; do
    if [ ! -f "$CERT_DIR/$f" ]; then
        echo "ERROR: $CERT_DIR/$f not found. Run setup-ca.sh first."
        exit 1
    fi
done

vagrant ssh vm1-gw -- sudo bash -s << 'CERT_EOF'
set -euo pipefail

IPSEC_DIR="/etc/ipsec.d"
SRC="/vagrant/services/vpn/certs"

echo ">>> Copying CA certificate..."
cp "$SRC/ca.crt" "$IPSEC_DIR/cacerts/ca.crt"
chmod 644 "$IPSEC_DIR/cacerts/ca.crt"

echo ">>> Copying Stockholm certificate..."
cp "$SRC/stockholm.crt" "$IPSEC_DIR/certs/stockholm.crt"
chmod 644 "$IPSEC_DIR/certs/stockholm.crt"

echo ">>> Copying Stockholm private key..."
cp "$SRC/stockholm.key" "$IPSEC_DIR/private/stockholm.key"
chmod 600 "$IPSEC_DIR/private/stockholm.key"
chown root:root "$IPSEC_DIR/private/stockholm.key"

echo ">>> Verifying installation..."
echo "  cacerts:"
ls -la "$IPSEC_DIR/cacerts/"
echo "  certs:"
ls -la "$IPSEC_DIR/certs/"
echo "  private:"
ls -la "$IPSEC_DIR/private/"

echo ">>> Certificates installed on VM1."

CERT_EOF

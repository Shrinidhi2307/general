#!/bin/bash
# =============================================================================
# Issue a VPN client certificate and generate .ovpn config
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/vpn/issue-vpn-client.sh <name>
#
# Example:
#   bash services/vpn/issue-vpn-client.sh alice
#   bash services/vpn/issue-vpn-client.sh bob
#
# Output (in services/vpn/clients/):
#   <name>.ovpn  — Self-contained OpenVPN config (embeds certs + keys)
#   <name>.crt   — Client certificate
#   <name>.key   — Client private key
#
# The .ovpn file can be imported directly into Tunnelblick (macOS),
# OpenVPN Connect (Windows/iOS/Android), or any OpenVPN client.
#
# Prerequisites:
#   - VM3 (CA) is running
#   - OpenVPN server set up: bash services/vpn/setup-openvpn.sh
# =============================================================================
set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
    echo "Usage: bash services/vpn/issue-vpn-client.sh <name>"
    echo "  e.g: bash services/vpn/issue-vpn-client.sh alice"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

CERT_DIR="services/vpn/certs"
CLIENT_DIR="services/vpn/clients"
mkdir -p "$CLIENT_DIR"

echo "====================================================="
echo " Issuing VPN client certificate for: ${NAME}"
echo "====================================================="

# ── Pre-flight ──
for f in ca.crt ta.key; do
    if [ ! -f "$CERT_DIR/$f" ]; then
        echo "ERROR: $CERT_DIR/$f not found."
        echo "Run first:  bash services/vpn/setup-openvpn.sh"
        exit 1
    fi
done

# ═════════════════════════════════════════════════════════════
# Step 1: Generate client certificate on VM3
# ═════════════════════════════════════════════════════════════
echo ""
echo ">>> Generating client certificate on VM3 (CA)..."

vagrant ssh vm3-ca -- sudo bash -s << CA_EOF
set -euo pipefail

CA_DIR="/root/easy-rsa"
EXPORT_DIR="/vagrant/services/vpn/clients"
CERT_NAME="${NAME}"

mkdir -p "\$EXPORT_DIR"
cd "\$CA_DIR"

if [ ! -d "pki" ]; then
    echo "ERROR: EasyRSA PKI not initialised. Run services/vpn/setup-ca.sh first."
    exit 1
fi

# Generate client key + CSR (idempotent)
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

echo "Done."
ls -la "\${EXPORT_DIR}/\${CERT_NAME}".{crt,key}

CA_EOF

# Verify export landed
for f in "${NAME}.crt" "${NAME}.key"; do
    if [ ! -f "${CLIENT_DIR}/${f}" ]; then
        echo "ERROR: ${CLIENT_DIR}/${f} not found — CA step may have failed."
        exit 1
    fi
done

# ═════════════════════════════════════════════════════════════
# Step 2: Build self-contained .ovpn config
# ═════════════════════════════════════════════════════════════
echo ""
echo ">>> Building .ovpn config file..."

OVPN_FILE="${CLIENT_DIR}/${NAME}.ovpn"

cat > "$OVPN_FILE" << 'OVPN_HEADER'
# =============================================================================
# ACME Roadwarrior VPN — Client Configuration
# =============================================================================
# Import this file into your OpenVPN client:
#   macOS:   Tunnelblick (drag & drop)
#   Windows: OpenVPN Connect (File → Import)
#   Linux:   sudo openvpn --config <this-file>
#   Mobile:  OpenVPN Connect app (import from Files)
# =============================================================================
client
dev tun
proto udp
remote 127.0.0.1 1194
resolv-retry infinite
nobind

persist-key
persist-tun

remote-cert-tls server
cipher AES-256-GCM
auth SHA256
key-direction 1
verb 3

OVPN_HEADER

# Embed CA certificate
echo "<ca>" >> "$OVPN_FILE"
cat "$CERT_DIR/ca.crt" >> "$OVPN_FILE"
echo "</ca>" >> "$OVPN_FILE"
echo "" >> "$OVPN_FILE"

# Embed client certificate
echo "<cert>" >> "$OVPN_FILE"
cat "${CLIENT_DIR}/${NAME}.crt" >> "$OVPN_FILE"
echo "</cert>" >> "$OVPN_FILE"
echo "" >> "$OVPN_FILE"

# Embed client key
echo "<key>" >> "$OVPN_FILE"
cat "${CLIENT_DIR}/${NAME}.key" >> "$OVPN_FILE"
echo "</key>" >> "$OVPN_FILE"
echo "" >> "$OVPN_FILE"

# Embed TLS-Auth key
echo "<tls-auth>" >> "$OVPN_FILE"
cat "$CERT_DIR/ta.key" >> "$OVPN_FILE"
echo "</tls-auth>" >> "$OVPN_FILE"

chmod 600 "$OVPN_FILE"

echo ""
echo "====================================================="
echo " VPN client config ready for: ${NAME}"
echo ""
echo " File: ${OVPN_FILE}"
echo ""
echo " To connect:"
echo "   macOS:    Open ${NAME}.ovpn with Tunnelblick"
echo "   Linux:    sudo openvpn --config ${OVPN_FILE}"
echo "   Windows:  Import into OpenVPN Connect"
echo ""
echo " After connecting, test access:"
echo "   curl --cacert ${CERT_DIR}/ca.crt \\"
echo "        --cert ${CLIENT_DIR}/${NAME}.crt \\"
echo "        --key ${CLIENT_DIR}/${NAME}.key \\"
echo "        https://portal.acme.internal"
echo ""
echo " NOTE: Update the 'remote' line in the .ovpn file to match"
echo "       the actual server address for your deployment."
echo "====================================================="

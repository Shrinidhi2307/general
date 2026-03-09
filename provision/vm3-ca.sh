#!/bin/bash
# =============================================================================
# VM3 (CA Server & FreeRADIUS) — Provisioner
# Purpose now:
# - internal CA
# - employee/device certificates
# - pseudonym credential demo
# - FreeRADIUS ready for future router integration
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM3 (CA Server & RADIUS)..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    freeradius freeradius-utils openssl easy-rsa

echo ">>> Initializing PKI and building certificates..."
PKI_DIR="/root/easy-rsa"
rm -rf "$PKI_DIR"
make-cadir "$PKI_DIR"
cd "$PKI_DIR"

./easyrsa init-pki

export EASYRSA_REQ_COUNTRY="SE"
export EASYRSA_REQ_PROVINCE="Stockholm"
export EASYRSA_REQ_CITY="Stockholm"
export EASYRSA_REQ_ORG="ACME Scandinavia"
export EASYRSA_REQ_EMAIL="admin@acme.com"
export EASYRSA_REQ_OU="Security"
export EASYRSA_REQ_CN="ACME-Internal-CA"

./easyrsa --batch --days=3650 build-ca nopass

# Server certs
./easyrsa --batch build-server-full vm2-srv nopass
./easyrsa --batch build-server-full vm3-ca nopass

# Router/device/client certs
./easyrsa --batch build-client-full sthlm-router nopass
./easyrsa --batch build-client-full london-router nopass
./easyrsa --batch build-client-full alice nopass

# Pseudonym / short-lived credential
./easyrsa --batch --days=30 build-client-full pseudo-alice-001 nopass

echo ">>> Exporting certificates to shared folder..."
DEST_DIR="/vagrant/shared_certs"
mkdir -p "$DEST_DIR"
rm -f "$DEST_DIR"/*

cp pki/ca.crt "$DEST_DIR/"
cp pki/issued/vm2-srv.crt pki/private/vm2-srv.key "$DEST_DIR/"
cp pki/issued/vm3-ca.crt pki/private/vm3-ca.key "$DEST_DIR/"
cp pki/issued/sthlm-router.crt pki/private/sthlm-router.key "$DEST_DIR/"
cp pki/issued/london-router.crt pki/private/london-router.key "$DEST_DIR/"
cp pki/issued/alice.crt pki/private/alice.key "$DEST_DIR/"
cp pki/issued/pseudo-alice-001.crt pki/private/pseudo-alice-001.key "$DEST_DIR/"

chmod -R 644 "$DEST_DIR"/*

echo ">>> Configuring FreeRADIUS..."
cat >> /etc/freeradius/3.0/users << 'EOF'

alice Cleartext-Password := "alice_password123"
bob   Cleartext-Password := "bob_password456"
EOF

cat >> /etc/freeradius/3.0/clients.conf << 'EOF'

client sthlm-router {
    ipaddr = 10.0.1.130
    secret = acme_radius_secret
}

client london-router {
    ipaddr = 10.0.2.130
    secret = acme_radius_secret
}

client london-proxy {
    ipaddr = 10.0.2.2
    secret = acme_radius_secret
}
EOF

systemctl restart freeradius
systemctl enable freeradius

echo ">>> Applying controlled routing..."
cat > /etc/netplan/99-acme-airgap.yaml << 'YAML'
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
    enp0s8:
      routes:
        - to: 10.0.1.128/26
          via: 10.0.1.1
        - to: 10.0.1.240/28
          via: 10.0.1.1
        - to: 10.0.2.0/24
          via: 10.0.1.1
YAML
netplan apply 2>/dev/null || true

echo ">>> VM3 provisioned successfully."
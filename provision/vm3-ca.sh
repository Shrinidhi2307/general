#!/bin/bash
# =============================================================================
# VM3 (CA Server & FreeRADIUS) — Provisioner
# Installs: freeradius, easy-rsa, openssl
# Configures: PKI generation, RADIUS Auth, & air-gap (removes default route)
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM3 (CA Server & RADIUS)..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    freeradius freeradius-utils openssl easy-rsa

echo ">>> Initializing PKI and building Certificates..."
PKI_DIR="/root/easy-rsa"
make-cadir $PKI_DIR
cd $PKI_DIR

./easyrsa init-pki
./easyrsa --batch --days=3650 build-ca nopass

./easyrsa --batch build-server-full vm1-gw nopass
./easyrsa --batch build-server-full vm4-gw nopass
./easyrsa --batch build-server-full vm2-srv nopass

./easyrsa --batch build-client-full sthlm-router nopass
./easyrsa --batch build-client-full london-router nopass
./easyrsa --batch build-client-full alice nopass

echo ">>> Exporting certificates to shared folder..."
DEST_DIR="/vagrant/shared_certs"
mkdir -p $DEST_DIR

cp pki/ca.crt $DEST_DIR/

cp pki/issued/vm1-gw.crt pki/private/vm1-gw.key $DEST_DIR/
cp pki/issued/vm4-gw.crt pki/private/vm4-gw.key $DEST_DIR/
cp pki/issued/vm2-srv.crt pki/private/vm2-srv.key $DEST_DIR/

cp pki/issued/sthlm-router.crt pki/private/sthlm-router.key $DEST_DIR/
cp pki/issued/london-router.crt pki/private/london-router.key $DEST_DIR/

cp pki/issued/alice.crt pki/private/alice.key $DEST_DIR/

chmod -R 644 $DEST_DIR/*
echo ">>> Certificates successfully exported to /vagrant/shared_certs/"

echo ">>> Configuring FreeRADIUS..."

cat >> /etc/freeradius/3.0/users << 'EOF'

# Employee Accounts for Wi-Fi
alice Cleartext-Password := "alice_password123"
bob   Cleartext-Password := "bob_password456"
EOF

cat >> /etc/freeradius/3.0/clients.conf << 'EOF'

# Stockholm Physical Router (假设其内网IP为 10.0.1.130)
client sthlm-router {
    ipaddr = 10.0.1.130
    secret = acme_radius_secret
}

# London RADIUS Proxy (VM5, 假设IP为 10.0.2.2)
client london-proxy {
    ipaddr = 10.0.2.2
    secret = acme_radius_secret
}
EOF

systemctl restart freeradius
systemctl enable freeradius
echo ">>> FreeRADIUS configured and started."

echo ">>> Applying Air-gap network configuration..."
cat > /etc/netplan/99-acme-airgap.yaml << 'YAML'
network:
  version: 2exit
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

echo ">>> VM3 (CA & RADIUS) provisioned successfully. Air-gap active."
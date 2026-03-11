#!/bin/bash
# =============================================================================
# VM5 (London RADIUS Proxy) — Provisioner
# Installs: freeradius (proxy mode)
# Networking: bridged to London router LAN via enp0s9
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM5 (London RADIUS Proxy)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    freeradius freeradius-utils

# ── FreeRADIUS: RADIUS clients ──
# Allow the London router (any IP on the LAN) to send auth requests
cat >> /etc/freeradius/3.0/clients.conf << 'EOF'

client london-router {
    ipaddr = 10.0.2.0/24
    secret = acme_radius_secret
}
EOF

# ── FreeRADIUS: Deploy certs from shared folder ──
RADIUS_CERT_DIR="/etc/freeradius/3.0/certs"
cp /vagrant/shared_certs/ca.crt "$RADIUS_CERT_DIR/ca.pem"
cp /vagrant/shared_certs/radius-srv.crt "$RADIUS_CERT_DIR/server.pem"
cp /vagrant/shared_certs/radius-srv.key "$RADIUS_CERT_DIR/server.key"
chown freerad:freerad "$RADIUS_CERT_DIR"/{ca.pem,server.pem,server.key}
chmod 640 "$RADIUS_CERT_DIR"/{ca.pem,server.pem,server.key}

# Generate DH params if missing
if [ ! -f "$RADIUS_CERT_DIR/dh" ]; then
    openssl dhparam -out "$RADIUS_CERT_DIR/dh" 2048
    chown freerad:freerad "$RADIUS_CERT_DIR/dh"
fi

# ── FreeRADIUS: EAP-TLS only ──
cat > /etc/freeradius/3.0/mods-available/eap << 'EAPCONF'
eap {
    default_eap_type = tls
    timer_expire = 60
    ignore_unknown_eap_types = no
    cisco_accounting_username_bug = no
    max_sessions = ${max_requests}

    tls-config tls-common {
        private_key_file = /etc/freeradius/3.0/certs/server.key
        certificate_file = /etc/freeradius/3.0/certs/server.pem
        ca_file = /etc/freeradius/3.0/certs/ca.pem
        dh_file = /etc/freeradius/3.0/certs/dh
        random_file = /dev/urandom
        cipher_list = "DEFAULT"
        cipher_server_preference = no
        tls_min_version = "1.2"
        ecdh_curve = "prime256v1"
    }

    tls {
        tls = tls-common
    }
}
EAPCONF

# ── Enable service ──
systemctl restart freeradius
systemctl enable freeradius

echo ">>> VM5 (London RADIUS Proxy) provisioned."

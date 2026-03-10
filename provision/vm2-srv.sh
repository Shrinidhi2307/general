#!/bin/bash
# =============================================================================
# VM2 (Stockholm Server) — Provisioner
# Installs: nginx, bind9, docker, python3
# Purpose now: make internal web + DNS independently testable
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM2 (Server)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl dnsutils \
    nginx bind9 bind9utils \
    docker.io python3-pip python3-venv

# ── Route fix: prefer bridged adapter (enp0s9) for the physical LAN ──
# Both enp0s8 (intnet) and enp0s9 (bridged) share 10.0.1.0/26. Without this fix,
# enp0s8 wins and traffic to the router goes into the VirtualBox internal network.
if ip link show enp0s9 >/dev/null 2>&1; then
    ip route del 10.0.1.0/26 dev enp0s8 2>/dev/null || true
    ip route replace 10.0.1.0/26 dev enp0s9 src 10.0.1.50 metric 50
    # Re-add enp0s8 route with higher metric so VM3 is still reachable via intnet
    ip route add 10.0.1.0/26 dev enp0s8 src 10.0.1.2 metric 200 2>/dev/null || true
    # Route to Employee/Client subnet via the router
    ip route add 10.0.1.128/26 via 10.0.1.1 dev enp0s9 2>/dev/null || true
fi

echo ">>> 1. Importing Certificates from VM3..."
mkdir -p /etc/nginx/ssl

# Copy certs if present; do not fail hard if VM3/shared_certs is not ready yet
if [ -f /vagrant/shared_certs/ca.crt ]; then
    cp /vagrant/shared_certs/ca.crt /etc/nginx/ssl/
fi

if [ -f /vagrant/shared_certs/vm2-srv.crt ] && [ -f /vagrant/shared_certs/vm2-srv.key ]; then
    cp /vagrant/shared_certs/vm2-srv.crt /etc/nginx/ssl/
    cp /vagrant/shared_certs/vm2-srv.key /etc/nginx/ssl/
    chmod 600 /etc/nginx/ssl/*.key
else
    echo ">>> VM3 certs not found, generating temporary self-signed cert for VM2..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/vm2-srv.key \
        -out /etc/nginx/ssl/vm2-srv.crt \
        -subj "/C=SE/ST=Stockholm/L=Stockholm/O=ACME/OU=IT/CN=secure.acme.com" >/dev/null 2>&1
    chmod 600 /etc/nginx/ssl/vm2-srv.key
fi

echo ">>> 2. Configuring BIND9 (Internal DNS)..."
cat > /etc/bind/named.conf.local << 'EOF'
zone "acme.com" {
    type master;
    file "/etc/bind/zones/db.acme.com";
};
EOF

mkdir -p /etc/bind/zones
cat > /etc/bind/zones/db.acme.com << 'EOF'
$TTL    604800
@       IN      SOA     ns1.acme.com. admin.acme.com. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.acme.com.
ns1     IN      A       10.0.1.50
secure  IN      A       10.0.1.50
EOF

systemctl restart named
systemctl enable named

echo ">>> 3. Configuring Nginx (Internal HTTPS Web Server)..."
cat > /etc/nginx/sites-available/secure_site << 'EOF'
server {
    listen 443 ssl default_server;
    server_name secure.acme.com 10.0.1.50 _;

    ssl_certificate /etc/nginx/ssl/vm2-srv.crt;
    ssl_certificate_key /etc/nginx/ssl/vm2-srv.key;

    # Demo phase: normal HTTPS only.
    # Access control should be enforced later by router/VPN/firewall rules.
    ssl_verify_client off;

    location / {
        root /var/www/html/secure;
        index index.html;
    }
}
EOF

mkdir -p /var/www/html/secure
cat > /var/www/html/secure/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>ACME Secure Portal</title>
</head>
<body>
    <h1>Welcome to ACME Secure Internal Portal</h1>
    <p>This VM2-hosted internal site is ready for testing.</p>
    <p>In the final setup, access should only be allowed from Employee networks or via VPN.</p>
</body>
</html>
EOF

ln -sf /etc/nginx/sites-available/secure_site /etc/nginx/sites-enabled/secure_site
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx
systemctl enable nginx

echo ">>> VM2 Provisioning Complete!"
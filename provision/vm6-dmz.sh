#!/bin/bash
# =============================================================================
# VM6 (DMZ) — Provisioner
# Installs: docker, certbot, nginx
# Configures: inter-VLAN routes through VM1, Docker Web App, Nginx Reverse Proxy
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM6 (DMZ)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    docker.io certbot nginx

# ── Inter-VLAN routes via VM1 gateway ──
# VM6 is on VLAN 30 (10.0.1.240/28). Route to other VLANs through VM1
# so that firewall rules are enforced (DMZ isolation).
cat > /etc/netplan/99-acme-routes.yaml << 'YAML'
network:
  version: 2
  ethernets:
    enp0s8:
      routes:
        - to: 10.0.1.0/26
          via: 10.0.1.241
        - to: 10.0.1.128/26
          via: 10.0.1.241
YAML
netplan apply 2>/dev/null || true

# Sleep 5 to allow netplan to stabilize. Otherwise docker pull might fail
sleep 5

# ── Docker Web Service ──
echo ">>> Setting up Docker Web Service..."
docker rm -f my-web 2>/dev/null || true

docker pull nginx

# NOTE: This nginx is just an example of the "spin-off web"
# The real nginx doing the reverse proxy is installed through apt earlier
docker run -d --name my-web -p 8080:80 nginx

# ── HTTPS Certificate (Self-Signed) ──
echo ">>> Generating Self-Signed SSL Certificate..."
mkdir -p /etc/nginx/ssl/acme/
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/acme/nginx-proxy.key.pem \
    -out /etc/nginx/ssl/acme/nginx-proxy.cert.pem \
    -subj "/C=SE/ST=Stockholm/L=Stockholm/O=ACME Corp/OU=IT/CN=dmz.local" 2>/dev/null

# ── Nginx Reverse Proxy & Security Config ──
echo ">>> Configuring Nginx Reverse Proxy..."
cat > /etc/nginx/sites-available/default << 'EOF'

limit_req_zone $binary_remote_addr zone=acme_limit:10m rate=10r/s;

server {
    listen 80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name _;

    ssl_certificate /etc/nginx/ssl/acme/nginx-proxy.cert.pem;
    ssl_certificate_key /etc/nginx/ssl/acme/nginx-proxy.key.pem;

    limit_req zone=acme_limit burst=20 nodelay;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

systemctl restart nginx

echo ">>> VM6 (DMZ) provisioned completely."
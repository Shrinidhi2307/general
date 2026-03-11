#!/bin/bash
# =============================================================================
# VM6 (DMZ) — Provisioner
# Installs: docker, certbot, nginx
# Configures: inter-VLAN routes, Docker Spinoff Websites, Nginx Reverse Proxy
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM6 (DMZ)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    docker.io certbot nginx

# ── Routing via Stockholm router ──
# VM6 reaches the router (10.0.1.1) via the bridged adapter (enp0s9).
# Route to other subnets through the router so firewall rules are enforced.
cat > /etc/netplan/99-acme-routes.yaml << 'YAML'
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
    enp0s9:
      routes:
        - to: 10.0.1.0/26
          via: 10.0.1.1
        - to: 10.0.1.128/26
          via: 10.0.1.1
        - to: 10.0.2.0/24
          via: 10.0.1.1
YAML
netplan apply 2>/dev/null || true

# Sleep 5 to allow netplan to stabilize. Otherwise docker pull might fail
sleep 5

# ── Spinoff Web Content ──
# Copy static HTML/CSS from synced folder into serving directories.
# Vagrant syncs the repo to /vagrant on the VM.
echo ">>> Setting up spinoff web content..."
SPINOFF_SRC="/vagrant/services/spinoff"
SPINOFF1_DIR="/srv/spinoff1"
SPINOFF2_DIR="/srv/spinoff2"

mkdir -p "$SPINOFF1_DIR" "$SPINOFF2_DIR"

cp "$SPINOFF_SRC/spinoff1/index.html" "$SPINOFF1_DIR/index.html"
cp "$SPINOFF_SRC/style.css"           "$SPINOFF1_DIR/style.css"
cp "$SPINOFF_SRC/spinoff2/index.html" "$SPINOFF2_DIR/index.html"
cp "$SPINOFF_SRC/style.css"           "$SPINOFF2_DIR/style.css"

# ── Docker Spinoff Containers ──
echo ">>> Setting up Docker Web Services..."
docker rm -f spinoff1-web spinoff2-web 2>/dev/null || true
docker pull nginx:alpine

# Spinoff 1 on port 8081, Spinoff 2 on port 8082
docker run -d --name spinoff1-web -p 8081:80 \
    -v "$SPINOFF1_DIR":/usr/share/nginx/html:ro \
    nginx:alpine

docker run -d --name spinoff2-web -p 8082:80 \
    -v "$SPINOFF2_DIR":/usr/share/nginx/html:ro \
    nginx:alpine

# ── TLS Certificates ──
# Priority: 1) certbot-issued certs in /etc/letsencrypt  2) repo-bundled certs  3) self-signed fallback
echo ">>> Configuring TLS certificates..."
mkdir -p /etc/nginx/ssl/acme/

install_repo_cert() {
    # Install bundled Let's Encrypt certs from the repo into /etc/letsencrypt
    local domain="$1"
    local repo_cert="/vagrant/services/spinoff/certs/${domain}/fullchain.pem"
    local repo_key="/vagrant/services/spinoff/certs/${domain}/privkey.pem"
    local le_dir="/etc/letsencrypt/live/${domain}"

    if [ ! -f "${le_dir}/fullchain.pem" ] && [ -f "$repo_cert" ] && [ -f "$repo_key" ]; then
        echo ">>> Installing bundled Let's Encrypt cert for ${domain} from repo..." >&2
        mkdir -p "$le_dir"
        cp "$repo_cert" "${le_dir}/fullchain.pem"
        cp "$repo_key"  "${le_dir}/privkey.pem"
        chmod 600 "${le_dir}/privkey.pem"
    fi
}

resolve_cert() {
    local domain="$1" ss_cn="$2"
    local le_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local le_key="/etc/letsencrypt/live/${domain}/privkey.pem"
    local ss_cert="/etc/nginx/ssl/acme/${domain}.cert.pem"
    local ss_key="/etc/nginx/ssl/acme/${domain}.key.pem"

    # Try installing from repo first
    install_repo_cert "$domain"

    if [ -f "$le_cert" ] && [ -f "$le_key" ]; then
        echo ">>> Using Let's Encrypt certificate for ${domain}" >&2
        echo "$le_cert $le_key"
    else
        echo ">>> Let's Encrypt cert not found for ${domain}, generating self-signed fallback..." >&2
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$ss_key" -out "$ss_cert" \
            -subj "/C=SE/ST=Stockholm/L=Stockholm/O=ACME Corp/OU=IT/CN=${ss_cn}" 2>/dev/null
        echo "$ss_cert $ss_key"
    fi
}

read -r S1_CERT S1_KEY <<< "$(resolve_cert spinoff1.forkhub.one spinoff1.dmz.local)"
read -r S2_CERT S2_KEY <<< "$(resolve_cert spinoff2.forkhub.one spinoff2.dmz.local)"

# ── Nginx Reverse Proxy & Security Config ──
# SSI (Server Side Includes) is enabled so that the HTML pages can display
# live TLS connection info via Nginx's $ssl_* variables.
echo ">>> Configuring Nginx Reverse Proxy..."
cat > /etc/nginx/sites-available/default << EOF

limit_req_zone \$binary_remote_addr zone=acme_limit:10m rate=10r/s;

# ── Redirect HTTP → HTTPS ──
server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

# ── Spinoff 1 ──
server {
    listen 443 ssl default_server;
    server_name spinoff1.forkhub.one;

    ssl_certificate     ${S1_CERT};
    ssl_certificate_key ${S1_KEY};

    ssi on;
    limit_req zone=acme_limit burst=20 nodelay;

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}

# ── Spinoff 2 ──
server {
    listen 443 ssl;
    server_name spinoff2.forkhub.one;

    ssl_certificate     ${S2_CERT};
    ssl_certificate_key ${S2_KEY};

    ssi on;
    limit_req zone=acme_limit burst=20 nodelay;

    location / {
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

systemctl restart nginx

echo ">>> VM6 (DMZ) provisioned completely."

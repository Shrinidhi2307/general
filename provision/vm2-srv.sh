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
    docker.io python3-pip python3-venv openssl

# ── Route fix: prefer bridged adapter (enp0s9) for the physical LAN ──
if ip link show enp0s9 >/dev/null 2>&1; then
    ip route del 10.0.1.0/26 dev enp0s8 2>/dev/null || true
    ip route replace 10.0.1.0/26 dev enp0s9 src 10.0.1.50 metric 50
    ip route add 10.0.1.0/26 dev enp0s8 src 10.0.1.2 metric 200 2>/dev/null || true
    ip route add 10.0.1.128/26 via 10.0.1.1 dev enp0s9 2>/dev/null || true
fi

echo ">>> 1. Importing certificates from VM3 CA..."
mkdir -p /etc/nginx/ssl

# Prefer CA-issued server certs from VM3
if [ -f /vagrant/shared_certs/issued/vm2-srv/vm2-srv.crt ] && \
   [ -f /vagrant/shared_certs/issued/vm2-srv/vm2-srv.key ]; then

    cp /vagrant/shared_certs/issued/vm2-srv/vm2-srv.crt /etc/nginx/ssl/acme-web.crt
    cp /vagrant/shared_certs/issued/vm2-srv/vm2-srv.key /etc/nginx/ssl/acme-web.key

    if [ -f /vagrant/shared_certs/issued/vm2-srv/ca.crt ]; then
        cp /vagrant/shared_certs/issued/vm2-srv/ca.crt /etc/nginx/ssl/ca.crt
    fi

    chmod 644 /etc/nginx/ssl/acme-web.crt
    chmod 600 /etc/nginx/ssl/acme-web.key
    [ -f /etc/nginx/ssl/ca.crt ] && chmod 644 /etc/nginx/ssl/ca.crt

    echo ">>> Imported CA-issued TLS certificate for VM2."

# Fallback to legacy shared cert path if present
elif [ -f /vagrant/shared_certs/acme-web.crt ] && [ -f /vagrant/shared_certs/acme-web.key ]; then
    cp /vagrant/shared_certs/acme-web.crt /etc/nginx/ssl/acme-web.crt
    cp /vagrant/shared_certs/acme-web.key /etc/nginx/ssl/acme-web.key

    if [ -f /vagrant/shared_certs/ca.crt ]; then
        cp /vagrant/shared_certs/ca.crt /etc/nginx/ssl/ca.crt
        chmod 644 /etc/nginx/ssl/ca.crt
    fi

    chmod 644 /etc/nginx/ssl/acme-web.crt
    chmod 600 /etc/nginx/ssl/acme-web.key
    echo ">>> Imported legacy shared TLS certificate."

else
    echo ">>> No CA-issued web cert found, generating temporary self-signed cert..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/acme-web.key \
        -out /etc/nginx/ssl/acme-web.crt \
        -subj "/C=SE/ST=Stockholm/L=Stockholm/O=ACME/OU=IT/CN=secure.acme.com" \
        -addext "subjectAltName=DNS:secure.acme.com,IP:10.0.1.50" \
        >/dev/null 2>&1
    chmod 644 /etc/nginx/ssl/acme-web.crt
    chmod 600 /etc/nginx/ssl/acme-web.key
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
                              5         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.acme.com.
ns1     IN      A       10.0.1.50
secure  IN      A       10.0.1.50
EOF

named-checkconf
named-checkzone acme.com /etc/bind/zones/db.acme.com
systemctl restart named
systemctl enable named

echo ">>> 3. Configuring Nginx (Internal HTTPS Web Server)..."
mkdir -p /var/www/html/secure

cat > /etc/nginx/sites-available/secure_site << 'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name secure.acme.com 10.0.1.50;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name secure.acme.com 10.0.1.50;

    ssl_certificate /etc/nginx/ssl/acme-web.crt;
    ssl_certificate_key /etc/nginx/ssl/acme-web.key;

    # Optional: publish CA chain location if needed later
    # ssl_client_certificate /etc/nginx/ssl/ca.crt;
    ssl_verify_client off;

    location / {
        root /var/www/html/secure;
        index index.html;
    }
}
EOF

cat > /var/www/html/secure/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ACME Secure Internal Portal</title>
    <style>
        body {
            margin: 0;
            font-family: Arial, sans-serif;
            background: #f4f7fb;
            color: #1f2937;
        }
        .container {
            max-width: 920px;
            margin: 60px auto;
            background: #ffffff;
            padding: 40px;
            border-radius: 18px;
            box-shadow: 0 10px 28px rgba(0, 0, 0, 0.08);
        }
        .badge {
            display: inline-block;
            padding: 8px 14px;
            border-radius: 999px;
            background: #dcfce7;
            color: #166534;
            font-weight: bold;
            margin-bottom: 18px;
        }
        h1 {
            margin-top: 0;
            margin-bottom: 10px;
            font-size: 34px;
            color: #0f172a;
        }
        .subtitle {
            font-size: 18px;
            color: #475569;
            margin-bottom: 28px;
        }
        .section {
            margin-top: 28px;
        }
        .section h2 {
            margin-bottom: 10px;
            font-size: 20px;
            color: #1d4ed8;
        }
        .grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 18px;
            margin-top: 14px;
        }
        .card {
            background: #f8fafc;
            border: 1px solid #e2e8f0;
            border-radius: 14px;
            padding: 18px;
        }
        ul {
            padding-left: 20px;
            margin: 10px 0 0 0;
        }
        li {
            margin-bottom: 8px;
        }
        code {
            background: #eef2ff;
            padding: 2px 6px;
            border-radius: 6px;
        }
        .footer {
            margin-top: 36px;
            font-size: 14px;
            color: #64748b;
        }
        @media (max-width: 700px) {
            .container {
                margin: 20px;
                padding: 24px;
            }
            .grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="badge">Internal Service Active</div>
        <h1>ACME Secure Internal Portal</h1>
        <p class="subtitle">
            Protected internal HTTPS service hosted on VM2 in the Stockholm office network.
        </p>

        <div class="section">
            <h2>Overview</h2>
            <p>
                This portal demonstrates ACME’s internal web service architecture for secure access to company resources.
                In the finalized setup, access should be limited to authorized employee networks or through the secure remote access solution.
            </p>
        </div>

        <div class="grid">
            <div class="card">
                <h2>Security Features</h2>
                <ul>
                    <li>HTTPS-enabled internal web server</li>
                    <li>Certificate-based trust model using internal CA</li>
                    <li>Internal DNS record for the secure service</li>
                    <li>Segregated internal network design</li>
                </ul>
            </div>

            <div class="card">
                <h2>Service Information</h2>
                <p><strong>Server:</strong> VM2 (Stockholm Server)</p>
                <p><strong>Web stack:</strong> Nginx over TLS</p>
                <p><strong>Address:</strong> <code>10.0.1.50</code></p>
                <p><strong>Hostname:</strong> <code>secure.acme.com</code></p>
            </div>
        </div>

        <div class="section">
            <h2>Project Context</h2>
            <p>
                This page is part of the EP2520 ACME network security demonstration environment.
                It is used to verify secure internal service delivery, certificate deployment, and protected access design.
            </p>
        </div>

        <div class="footer">
            ACME Scandinavia — Internal demonstration portal
        </div>
    </div>
</body>
</html>
EOF

ln -sf /etc/nginx/sites-available/secure_site /etc/nginx/sites-enabled/secure_site
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx
systemctl enable nginx

echo ">>> VM2 Provisioning Complete!"
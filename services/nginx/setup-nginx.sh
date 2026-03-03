#!/bin/bash
# =============================================================================
# Configure Nginx on VM2 — two mTLS virtual hosts
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/nginx/setup-nginx.sh
#
# Prerequisites:
#   bash services/vpn/setup-ca.sh     (CA on VM3)
#   bash services/certs/issue-vm2.sh  (server cert deployed to /etc/nginx/certs/)
#
# What this script does:
#   1. Adds a custom log format that includes the client certificate DN
#   2. Adds a geo block to flag VPN-pool clients (needed for step 5 TOTP)
#   3. Creates critical.acme.internal  — mTLS, on-site only (no VPN)
#   4. Creates portal.acme.internal    — mTLS, on-site + VPN pool
#   5. Adds HTTP→HTTPS redirects
#   6. Disables the default site
#   7. Tests config and reloads nginx
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Configuring Nginx vhosts on VM2"
echo "====================================================="

vagrant ssh vm2-srv -- sudo bash -s << 'NGINX_EOF'
set -euo pipefail

CERT_DIR="/etc/nginx/certs"

# Verify certs are present before doing anything
if [ ! -f "${CERT_DIR}/vm2-server.crt" ] || [ ! -f "${CERT_DIR}/vm2-server.key" ]; then
    echo "ERROR: Server certificate not found at ${CERT_DIR}/"
    echo "Run: bash services/certs/issue-vm2.sh first."
    exit 1
fi

# ── 1. Shared SSL settings snippet ────────────────────────────────────────
echo ">>> Writing shared SSL settings..."
cat > /etc/nginx/snippets/acme-ssl.conf << 'SNIPPET_EOF'
# ACME shared SSL settings — included by both vhosts

ssl_certificate     /etc/nginx/certs/vm2-server.crt;
ssl_certificate_key /etc/nginx/certs/vm2-server.key;

# mTLS: require client certificate signed by the ACME CA
ssl_client_certificate /etc/nginx/certs/ca.crt;
ssl_verify_client      on;

ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:!aNULL:!MD5;
ssl_prefer_server_ciphers off;
ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
SNIPPET_EOF

# ── 2. Custom log format + geo block (http-level, loaded via conf.d) ──────
echo ">>> Writing http-level config (log format + geo)..."
cat > /etc/nginx/conf.d/acme-http.conf << 'HTTP_EOF'
# Log format that captures the client certificate subject DN
log_format acme_ssl '$remote_addr - "$ssl_client_s_dn" [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_user_agent"';

# Identify VPN pool clients (10.0.3.0/24) for conditional TOTP (step 5)
# $is_vpn_client = 1 for VPN clients, 0 for on-site
geo $is_vpn_client {
    default          0;
    10.0.3.0/24      1;
}
HTTP_EOF

# ── 3. Web roots ──────────────────────────────────────────────────────────
echo ">>> Creating web roots..."
mkdir -p /var/www/critical /var/www/portal

cat > /var/www/critical/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html>
<head><title>ACME Critical Intranet</title></head>
<body>
  <h1>ACME Critical Intranet</h1>
  <p>Restricted to Stockholm and London on-site networks.</p>
  <p>Client: <strong>__CLIENT_DN__</strong></p>
</body>
</html>
HTML_EOF

cat > /var/www/portal/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html>
<head><title>ACME Employee Portal</title></head>
<body>
  <h1>ACME Employee Portal</h1>
  <p>Accessible from all ACME networks including VPN.</p>
  <p>Client: <strong>__CLIENT_DN__</strong></p>
</body>
</html>
HTML_EOF

chown -R www-data:www-data /var/www/critical /var/www/portal

# ── 4. critical.acme.internal vhost ───────────────────────────────────────
echo ">>> Writing critical.acme.internal vhost..."
cat > /etc/nginx/sites-available/critical.conf << 'VHOST_EOF'
# critical.acme.internal
# Access: on-site Stockholm + London only. VPN pool explicitly denied.
# Auth:   mTLS (client certificate required)

server {
    listen 443 ssl;
    server_name critical.acme.internal;

    include snippets/acme-ssl.conf;

    # On-site networks only — VPN pool (10.0.3.0/24) is not listed
    allow 10.0.1.0/24;
    allow 10.0.2.0/24;
    deny all;

    access_log /var/log/nginx/critical-access.log acme_ssl;
    error_log  /var/log/nginx/critical-error.log;

    root  /var/www/critical;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
VHOST_EOF

# ── 5. portal.acme.internal vhost ─────────────────────────────────────────
echo ">>> Writing portal.acme.internal vhost..."
cat > /etc/nginx/sites-available/portal.conf << 'VHOST_EOF'
# portal.acme.internal
# Access: on-site Stockholm + London + VPN pool
# Auth:   mTLS always; TOTP additionally required for VPN clients (step 5)

server {
    listen 443 ssl;
    server_name portal.acme.internal;

    include snippets/acme-ssl.conf;

    # On-site + VPN pool allowed
    allow 10.0.1.0/24;
    allow 10.0.2.0/24;
    allow 10.0.3.0/24;
    deny all;

    access_log /var/log/nginx/portal-access.log acme_ssl;
    error_log  /var/log/nginx/portal-error.log;

    root  /var/www/portal;
    index index.html;

    # ── TOTP hook (step 5) ──────────────────────────────────────────────
    # Uncomment once services/totp/setup-totp.sh has been run.
    # VPN clients ($is_vpn_client == 1) must pass TOTP in addition to mTLS.
    #
    # auth_request     /auth-totp;
    # auth_request_set $auth_status $upstream_status;
    #
    # location = /auth-totp {
    #     internal;
    #     proxy_pass              http://127.0.0.1:8888;
    #     proxy_pass_request_body off;
    #     proxy_set_header        Content-Length "";
    #     proxy_set_header        X-Is-VPN-Client $is_vpn_client;
    #     proxy_set_header        X-SSL-Client-DN $ssl_client_s_dn;
    # }
    # ────────────────────────────────────────────────────────────────────

    location / {
        try_files $uri $uri/ =404;
    }
}
VHOST_EOF

# ── 6. HTTP → HTTPS redirect for both vhosts ─────────────────────────────
echo ">>> Writing HTTP redirect vhost..."
cat > /etc/nginx/sites-available/acme-redirect.conf << 'REDIR_EOF'
server {
    listen 80;
    server_name critical.acme.internal portal.acme.internal;
    return 301 https://$host$request_uri;
}
REDIR_EOF

# ── 7. Enable sites, disable default ──────────────────────────────────────
echo ">>> Enabling sites..."
ln -sf /etc/nginx/sites-available/critical.conf     /etc/nginx/sites-enabled/critical.conf
ln -sf /etc/nginx/sites-available/portal.conf       /etc/nginx/sites-enabled/portal.conf
ln -sf /etc/nginx/sites-available/acme-redirect.conf /etc/nginx/sites-enabled/acme-redirect.conf

echo ">>> Disabling default site..."
rm -f /etc/nginx/sites-enabled/default

# ── 8. Test + reload ──────────────────────────────────────────────────────
echo ">>> Testing nginx configuration..."
nginx -t

echo ">>> Reloading nginx..."
systemctl reload nginx

echo ""
echo "Nginx vhosts active:"
nginx -T 2>/dev/null | grep "server_name"

NGINX_EOF

echo ""
echo "====================================================="
echo " Nginx setup complete!"
echo ""
echo " Two vhosts are now live on VM2 (10.0.1.2):"
echo "   https://critical.acme.internal  — on-site only, mTLS"
echo "   https://portal.acme.internal    — on-site + VPN, mTLS"
echo ""
echo " To test, you need a client certificate:"
echo "   bash services/certs/issue-client.sh <name>"
echo ""
echo " Then from inside VM2 (or any VLAN 10/20 host):"
echo "   curl --cacert services/certs/vm2/ca.crt \\"
echo "        --cert   services/certs/clients/<name>.crt \\"
echo "        --key    services/certs/clients/<name>.key \\"
echo "        https://critical.acme.internal"
echo "====================================================="

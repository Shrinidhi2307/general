#!/bin/bash
# =============================================================================
# Set up TOTP validator service on VM2 and enable it in portal.conf
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/totp/setup-totp.sh
#
# What this script does:
#   1. Creates a Python venv with Flask + pyotp
#   2. Writes the validator service (127.0.0.1:8888)
#   3. Creates a systemd unit and starts it
#   4. Rewrites portal.conf with the auth_request block enabled
#   5. Reloads nginx
#
# After this, VPN clients (10.0.3.x) hitting portal.acme.internal
# will be prompted for their TOTP code (via HTTP Basic Auth dialog).
# On-site clients are passed through without a TOTP prompt.
#
# Enroll users with:
#   bash services/totp/manage-totp.sh add <name>
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Setting up TOTP validator on VM2"
echo "====================================================="

vagrant ssh vm2-srv -- sudo bash -s << 'TOTP_EOF'
set -euo pipefail

INSTALL_DIR="/opt/totp-validator"
SECRETS_DIR="/etc/totp-validator/secrets"

# ── 1. System user ────────────────────────────────────────────────────────
if ! id totp-validator &>/dev/null; then
    echo ">>> Creating totp-validator system user..."
    useradd --system --no-create-home --shell /usr/sbin/nologin totp-validator
fi

# ── 2. Directories ────────────────────────────────────────────────────────
echo ">>> Creating directories..."
mkdir -p "$INSTALL_DIR" "$SECRETS_DIR"
chown root:totp-validator "$SECRETS_DIR"
chmod 750 "$SECRETS_DIR"

# ── 3. Python venv + dependencies ────────────────────────────────────────
if [ ! -d "${INSTALL_DIR}/venv" ]; then
    echo ">>> Creating Python venv..."
    python3 -m venv "${INSTALL_DIR}/venv"
fi

echo ">>> Installing Flask + pyotp..."
"${INSTALL_DIR}/venv/bin/pip" install --quiet flask pyotp

# ── 4. Validator service ──────────────────────────────────────────────────
echo ">>> Writing validator.py..."
cat > "${INSTALL_DIR}/validator.py" << 'PY_EOF'
#!/usr/bin/env python3
"""
ACME TOTP Validator
Nginx auth_request endpoint on 127.0.0.1:8888

Decision logic:
  - X-Is-VPN-Client: 0  → always 200 (on-site, mTLS is enough)
  - X-Is-VPN-Client: 1  → require TOTP via HTTP Basic Auth
      Username: ignored (identity comes from mTLS client cert CN)
      Password: 6-digit TOTP code from Google Authenticator

Secrets are stored in /etc/totp-validator/secrets/<cn>.secret (base32)
"""
import os
import base64
import logging
from flask import Flask, request, Response
import pyotp

app = Flask(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger(__name__)

SECRETS_DIR = "/etc/totp-validator/secrets"


def get_secret(cn: str):
    path = os.path.join(SECRETS_DIR, f"{cn}.secret")
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def parse_basic_auth(header: str):
    """Returns (username, password) or None."""
    try:
        scheme, encoded = header.split(" ", 1)
        if scheme.lower() != "basic":
            return None
        decoded = base64.b64decode(encoded).decode("utf-8")
        username, code = decoded.split(":", 1)
        return username, code
    except Exception:
        return None


def extract_cn(dn: str):
    """Extract CN value from a DN string like 'CN=alice,O=ACME'."""
    for part in dn.split(","):
        part = part.strip()
        if part.upper().startswith("CN="):
            return part[3:]
    return None


@app.route("/auth-totp", methods=["GET", "POST"])
def auth_totp():
    is_vpn = request.headers.get("X-Is-VPN-Client", "0")

    # On-site clients: mTLS alone is sufficient
    if is_vpn != "1":
        return Response(status=200)

    # Extract identity from mTLS client cert (passed by nginx)
    client_dn = request.headers.get("X-SSL-Client-DN", "")
    cn = extract_cn(client_dn)

    if not cn:
        log.warning("No CN in client DN: %s", client_dn)
        return Response(
            "No client identity",
            status=401,
            headers={"WWW-Authenticate": 'Basic realm="ACME TOTP"'},
        )

    # Check for Basic Auth header carrying the TOTP code
    auth_header = request.headers.get("Authorization", "")
    if not auth_header:
        log.info("TOTP prompt for VPN client: %s", cn)
        return Response(
            "TOTP required",
            status=401,
            headers={"WWW-Authenticate": 'Basic realm="ACME TOTP"'},
        )

    parsed = parse_basic_auth(auth_header)
    if not parsed:
        return Response(
            "Invalid auth header",
            status=401,
            headers={"WWW-Authenticate": 'Basic realm="ACME TOTP"'},
        )

    _, totp_code = parsed  # username field ignored; trust the mTLS CN

    secret = get_secret(cn)
    if not secret:
        log.warning("No TOTP secret enrolled for: %s", cn)
        return Response(
            "User not enrolled for TOTP",
            status=401,
            headers={"WWW-Authenticate": 'Basic realm="ACME TOTP"'},
        )

    totp = pyotp.TOTP(secret)
    if totp.verify(totp_code, valid_window=1):
        log.info("TOTP OK: %s", cn)
        return Response(status=200)
    else:
        log.warning("TOTP FAIL: %s", cn)
        return Response(
            "Invalid TOTP code",
            status=401,
            headers={"WWW-Authenticate": 'Basic realm="ACME TOTP"'},
        )


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8888, debug=False)
PY_EOF

chown root:totp-validator "${INSTALL_DIR}/validator.py"
chmod 640 "${INSTALL_DIR}/validator.py"

# ── 5. Systemd unit ───────────────────────────────────────────────────────
echo ">>> Writing systemd service..."
cat > /etc/systemd/system/totp-validator.service << 'SVC_EOF'
[Unit]
Description=ACME TOTP Validator (nginx auth_request backend)
After=network.target

[Service]
Type=simple
User=totp-validator
Group=totp-validator
WorkingDirectory=/opt/totp-validator
ExecStart=/opt/totp-validator/venv/bin/python /opt/totp-validator/validator.py
Restart=always
RestartSec=3
# Harden: no privileges needed beyond reading secrets
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/etc/totp-validator/secrets

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable totp-validator
systemctl restart totp-validator

sleep 2
systemctl is-active totp-validator && echo ">>> totp-validator is running." \
    || { echo "ERROR: totp-validator failed to start"; journalctl -u totp-validator -n 20; exit 1; }

# ── 6. Enable TOTP hook in portal.conf ───────────────────────────────────
echo ">>> Enabling auth_request block in portal.conf..."
cat > /etc/nginx/sites-available/portal.conf << 'VHOST_EOF'
# portal.acme.internal
# Access: on-site Stockholm + London + VPN pool
# Auth:   mTLS always; TOTP additionally required for VPN clients

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

    # ── TOTP for VPN clients ─────────────────────────────────────────────
    # On-site clients: validator returns 200 immediately (no prompt).
    # VPN clients (10.0.3.x): validator returns 401 until TOTP is provided.
    auth_request     /auth-totp;
    auth_request_set $auth_status $upstream_status;

    location = /auth-totp {
        internal;
        proxy_pass              http://127.0.0.1:8888/auth-totp;
        proxy_pass_request_body off;
        proxy_set_header        Content-Length "";
        proxy_set_header        X-Is-VPN-Client $is_vpn_client;
        proxy_set_header        X-SSL-Client-DN $ssl_client_s_dn;
        # Forward the Authorization header so the TOTP code reaches the validator
        proxy_set_header        Authorization $http_authorization;
    }
    # ─────────────────────────────────────────────────────────────────────

    location / {
        try_files $uri $uri/ =404;
    }
}
VHOST_EOF

nginx -t
systemctl reload nginx
echo ">>> nginx reloaded with TOTP enabled."

TOTP_EOF

echo ""
echo "====================================================="
echo " TOTP setup complete!"
echo ""
echo " Enroll an employee:"
echo "   bash services/totp/manage-totp.sh add alice"
echo ""
echo " Test from a simulated VPN client (on VM2 itself — using loopback"
echo " won't trigger VPN geo, so test from a VPN-connected device):"
echo "   curl --cacert services/certs/vm2/ca.crt \\"
echo "        --cert   services/certs/clients/alice.crt \\"
echo "        --key    services/certs/clients/alice.key \\"
echo "        -u 'alice:<totp-code>' \\"
echo "        https://portal.acme.internal"
echo "====================================================="

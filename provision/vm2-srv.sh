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
        :root {
            --bg: #f4f7fb;
            --panel: #ffffff;
            --text: #1f2937;
            --muted: #64748b;
            --primary: #1d4ed8;
            --primary-dark: #1e40af;
            --primary-soft: #dbeafe;
            --success-bg: #dcfce7;
            --success-text: #166534;
            --border: #e2e8f0;
            --shadow: 0 10px 28px rgba(0, 0, 0, 0.08);
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            font-family: Arial, sans-serif;
            background: linear-gradient(180deg, #eef4ff 0%, var(--bg) 100%);
            color: var(--text);
        }

        .container {
            max-width: 1120px;
            margin: 0 auto;
            padding: 48px 20px 56px;
        }

        .panel {
            background: var(--panel);
            border-radius: 20px;
            box-shadow: var(--shadow);
            border: 1px solid var(--border);
        }

        .hidden {
            display: none;
        }

        .hero {
            display: grid;
            grid-template-columns: 1.3fr 0.85fr;
            gap: 28px;
            padding: 36px;
        }

        .badge {
            display: inline-block;
            padding: 8px 14px;
            border-radius: 999px;
            background: var(--success-bg);
            color: var(--success-text);
            font-weight: bold;
            margin-bottom: 18px;
            font-size: 14px;
        }

        h1 {
            margin: 0 0 12px 0;
            font-size: 38px;
            color: #0f172a;
        }

        h2 {
            margin: 0 0 12px 0;
            color: var(--primary);
        }

        h3 {
            margin-top: 0;
            margin-bottom: 10px;
            font-size: 18px;
            color: #0f172a;
        }

        .subtitle {
            font-size: 18px;
            color: #475569;
            line-height: 1.6;
            margin-bottom: 20px;
        }

        .hero-points {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            margin-top: 16px;
        }

        .pill {
            background: #eef2ff;
            color: #3730a3;
            border-radius: 999px;
            padding: 8px 12px;
            font-size: 14px;
            font-weight: bold;
        }

        .notice {
            margin-top: 18px;
            padding: 16px 18px;
            border-left: 4px solid var(--primary);
            background: #eff6ff;
            border-radius: 12px;
            color: #1e3a8a;
            line-height: 1.6;
        }

        .login-card {
            background: #f8fafc;
            border: 1px solid var(--border);
            border-radius: 18px;
            padding: 22px;
        }

        .login-note {
            font-size: 14px;
            color: var(--muted);
            line-height: 1.6;
            margin-bottom: 18px;
        }

        .field {
            margin-bottom: 14px;
        }

        .field label {
            display: block;
            font-size: 14px;
            font-weight: bold;
            margin-bottom: 6px;
            color: #334155;
        }

        .field input {
            width: 100%;
            padding: 12px 14px;
            border: 1px solid #cbd5e1;
            border-radius: 12px;
            font-size: 15px;
            background: #fff;
        }

        .btn {
            display: inline-block;
            width: 100%;
            padding: 12px 16px;
            border: none;
            border-radius: 12px;
            background: var(--primary);
            color: white;
            font-size: 15px;
            font-weight: bold;
            cursor: pointer;
            transition: 0.2s ease;
        }

        .btn:hover {
            background: var(--primary-dark);
        }

        .btn.secondary {
            background: #e2e8f0;
            color: #1f2937;
        }

        .btn.secondary:hover {
            background: #cbd5e1;
        }

        .mini-status {
            margin-top: 14px;
            background: var(--primary-soft);
            color: #1e3a8a;
            border-radius: 12px;
            padding: 12px 14px;
            font-size: 14px;
            line-height: 1.5;
        }

        .error {
            margin-top: 12px;
            background: #fee2e2;
            color: #991b1b;
            border-radius: 12px;
            padding: 10px 12px;
            font-size: 14px;
            display: none;
        }

        .section-panel {
            padding: 30px;
            margin-top: 24px;
        }

        .section-panel p {
            color: #475569;
            line-height: 1.7;
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 18px;
            margin-top: 18px;
        }

        .card {
            background: #f8fafc;
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 20px;
        }

        .card p, .card li {
            color: #64748b;
            line-height: 1.6;
        }

        .dashboard-top {
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 16px;
            flex-wrap: wrap;
            margin-bottom: 10px;
        }

        .user-chip {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            background: #eff6ff;
            color: #1e3a8a;
            padding: 10px 14px;
            border-radius: 999px;
            font-weight: bold;
        }

        .dashboard {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            margin-top: 20px;
        }

        .stat {
            background: linear-gradient(180deg, #ffffff 0%, #f8fafc 100%);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 18px;
        }

        .stat .label {
            font-size: 13px;
            color: var(--muted);
            margin-bottom: 8px;
        }

        .stat .value {
            font-size: 26px;
            font-weight: bold;
            color: #0f172a;
        }

        .stat .sub {
            margin-top: 8px;
            font-size: 13px;
            color: #475569;
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
            margin-top: 18px;
            font-size: 14px;
            color: #64748b;
            text-align: center;
        }

        @media (max-width: 960px) {
            .hero {
                grid-template-columns: 1fr;
            }

            .grid {
                grid-template-columns: 1fr;
            }

            .dashboard {
                grid-template-columns: 1fr 1fr;
            }
        }

        @media (max-width: 640px) {
            h1 {
                font-size: 30px;
            }

            .dashboard {
                grid-template-columns: 1fr;
            }

            .hero,
            .section-panel {
                padding: 22px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div id="loginView" class="panel hero">
            <div>
                <div class="badge">Internal Service Active</div>
                <h1>ACME Secure Internal Portal</h1>
                <p class="subtitle">
                    Protected internal web portal hosted on VM2 in the Stockholm office network.
                    This service is delivered over HTTPS using a certificate issued by ACME’s internal CA on VM3.
                </p>

                <div class="hero-points">
                    <span class="pill">Internal PKI</span>
                    <span class="pill">HTTPS Enabled</span>
                    <span class="pill">RADIUS-backed Access Design</span>
                    <span class="pill">Segmented Network</span>
                </div>

                <div class="notice">
                    This page demonstrates the user-facing portal experience. In the actual design,
                    trust and access control are primarily enforced by ACME’s internal CA, employee network authentication,
                    and protected routing policies rather than by this front-end form alone.
                </div>
            </div>

            <div class="login-card">
                <h2>Employee Access</h2>
                <p class="login-note">
                    Demonstration login interface for ACME employees. This is a front-end only demo view for the project presentation.
                </p>

                <form id="loginForm">
                    <div class="field">
                        <label for="username">Employee ID</label>
                        <input id="username" type="text" placeholder="e.g. emp1">
                    </div>

                    <div class="field">
                        <label for="password">Password</label>
                        <input id="password" type="password" placeholder="Enter password">
                    </div>

                    <button type="submit" class="btn">Access Internal Portal</button>
                </form>

                <div id="loginError" class="error">
                    Please enter an employee ID and password to continue.
                </div>

                <div class="mini-status">
                    Demo note: after clicking login, the page switches to an internal employee dashboard.
                    No real backend authentication is performed here.
                </div>
            </div>
        </div>

        <div id="dashboardView" class="hidden">
            <div class="panel section-panel">
                <div class="dashboard-top">
                    <div>
                        <div class="badge">Authenticated Session (Demo)</div>
                        <h1 style="font-size:34px; margin-bottom:8px;">Employee Dashboard</h1>
                        <p class="subtitle" style="margin-bottom:0;">
                            Welcome to the ACME internal employee portal.
                        </p>
                    </div>
                    <div>
                        <div class="user-chip">
                            Signed in as <span id="displayUser">employee</span>
                        </div>
                    </div>
                </div>

                <div class="dashboard">
                    <div class="stat">
                        <div class="label">Portal Status</div>
                        <div class="value">Online</div>
                        <div class="sub">HTTPS service available</div>
                    </div>
                    <div class="stat">
                        <div class="label">Server</div>
                        <div class="value">VM2</div>
                        <div class="sub">Stockholm secure web host</div>
                    </div>
                    <div class="stat">
                        <div class="label">Hostname</div>
                        <div class="value">secure</div>
                        <div class="sub">secure.acme.com</div>
                    </div>
                    <div class="stat">
                        <div class="label">Trust Model</div>
                        <div class="value">PKI</div>
                        <div class="sub">Issued by internal CA</div>
                    </div>
                </div>

                <div class="grid">
                    <div class="card">
                        <h3>Internal Security Overview</h3>
                        <ul>
                            <li>HTTPS-enabled internal web service</li>
                            <li>Certificate issued by VM3 internal CA</li>
                            <li>Internal DNS for <code>secure.acme.com</code></li>
                            <li>Protected employee-network access design</li>
                        </ul>
                    </div>

                    <div class="card">
                        <h3>Available Internal Services</h3>
                        <ul>
                            <li>Secure employee portal access</li>
                            <li>Internal name resolution with BIND9</li>
                            <li>Certificate lifecycle support on VM3</li>
                            <li>Support for network-layer authentication</li>
                        </ul>
                    </div>

                    <div class="card">
                        <h3>Session Details</h3>
                        <ul>
                            <li><strong>Logged-in user:</strong> <span id="sessionUser">employee</span></li>
                            <li><strong>Web Server:</strong> Nginx</li>
                            <li><strong>Address:</strong> <code>10.0.1.50</code></li>
                            <li><strong>Certificate Issuer:</strong> ACME internal root CA</li>
                        </ul>
                    </div>
                </div>

                <div class="notice" style="margin-top:24px;">
                    This dashboard is a presentation-layer demo. In the real architecture,
                    internal trust is based on PKI, RADIUS-backed access policies, and secure routing rather than this front-end session alone.
                </div>

                <div style="margin-top:22px; max-width:220px;">
                    <button id="logoutBtn" class="btn secondary">Sign out</button>
                </div>
            </div>
        </div>

        <div class="footer">
            ACME Scandinavia — EP2520 internal security demonstration portal
        </div>
    </div>

    <script>
        const loginForm = document.getElementById('loginForm');
        const loginView = document.getElementById('loginView');
        const dashboardView = document.getElementById('dashboardView');
        const loginError = document.getElementById('loginError');
        const displayUser = document.getElementById('displayUser');
        const sessionUser = document.getElementById('sessionUser');
        const logoutBtn = document.getElementById('logoutBtn');

        loginForm.addEventListener('submit', function (event) {
            event.preventDefault();

            const username = document.getElementById('username').value.trim();
            const password = document.getElementById('password').value.trim();

            if (!username || !password) {
                loginError.style.display = 'block';
                return;
            }

            loginError.style.display = 'none';
            displayUser.textContent = username;
            sessionUser.textContent = username;

            loginView.classList.add('hidden');
            dashboardView.classList.remove('hidden');
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });

        logoutBtn.addEventListener('click', function () {
            document.getElementById('username').value = '';
            document.getElementById('password').value = '';
            loginView.classList.remove('hidden');
            dashboardView.classList.add('hidden');
            loginError.style.display = 'none';
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });
    </script>
</body>
</html>
EOF

ln -sf /etc/nginx/sites-available/secure_site /etc/nginx/sites-enabled/secure_site
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx
systemctl enable nginx

echo ">>> VM2 Provisioning Complete!"
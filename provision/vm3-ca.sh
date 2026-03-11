#!/bin/bash
# =============================================================================
# VM3 (CA Server & FreeRADIUS) — Provisioner
# Purpose now:
# - internal CA based on existing root CA
# - keep previously issued employee/router certs in existing_ca (read-only)
# - issue new employee/device certificates into shared_certs/issued
# - issue SAN-enabled HTTPS server certificate for VM2
# - keep existing FreeRADIUS and routing behavior unchanged
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM3 (CA Server & RADIUS)..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    freeradius freeradius-utils openssl

# -----------------------------------------------------------------------------
# 1) CA workspace
# -----------------------------------------------------------------------------
echo ">>> Preparing persistent CA workspace..."

CA_DIR="/root/acme-ca"
SEED_DIR="/vagrant/shared_certs/seed_ca"
EXISTING_DIR="/vagrant/shared_certs/existing_ca"
EXPORT_BASE="/vagrant/shared_certs/issued"

mkdir -p "$CA_DIR"/{certs,crl,csr,newcerts,private}
mkdir -p "$EXPORT_BASE"

touch "$CA_DIR/index.txt"

# Initialize only if not already present
[ -f "$CA_DIR/serial" ] || echo "1000" > "$CA_DIR/serial"
[ -f "$CA_DIR/crlnumber" ] || echo "1000" > "$CA_DIR/crlnumber"

# Import root CA only once
if [ ! -f "$CA_DIR/private/ca.key" ]; then
    echo ">>> Importing existing CA private key from seed_ca..."
    if [ ! -f "$SEED_DIR/ca.key" ]; then
        echo "ERROR: Missing $SEED_DIR/ca.key"
        exit 1
    fi
    cp "$SEED_DIR/ca.key" "$CA_DIR/private/ca.key"
    chmod 600 "$CA_DIR/private/ca.key"
fi

if [ ! -f "$CA_DIR/certs/ca.crt" ]; then
    echo ">>> Importing existing CA certificate from seed_ca..."
    if [ ! -f "$SEED_DIR/ca.crt" ]; then
        echo "ERROR: Missing $SEED_DIR/ca.crt"
        exit 1
    fi
    cp "$SEED_DIR/ca.crt" "$CA_DIR/certs/ca.crt"
    chmod 644 "$CA_DIR/certs/ca.crt"
fi

# If teammate provided a CA serial seed, use it only on first clean setup
if [ -f "$SEED_DIR/ca.srl" ] && [ ! -s "$CA_DIR/index.txt" ]; then
    echo ">>> Importing CA serial seed..."
    cp "$SEED_DIR/ca.srl" "$CA_DIR/serial"
fi

# Make CA cert available in shared folder root for clients/VM2
cp -f "$CA_DIR/certs/ca.crt" /vagrant/shared_certs/ca.crt
chmod 644 /vagrant/shared_certs/ca.crt

# -----------------------------------------------------------------------------
# 2) OpenSSL CA config
# -----------------------------------------------------------------------------
echo ">>> Writing OpenSSL CA configuration..."

cat > "$CA_DIR/openssl.cnf" <<'EOF'
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /root/acme-ca
certs             = $dir/certs
crl_dir           = $dir/crl
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
crlnumber         = $dir/crlnumber
certificate       = $dir/certs/ca.crt
private_key       = $dir/private/ca.key
default_days      = 825
default_crl_days  = 30
default_md        = sha256
policy            = policy_loose
copy_extensions   = copy
unique_subject    = no

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
default_md          = sha256
prompt              = no

[ req_distinguished_name ]
C  = SE
ST = Stockholm
L  = Stockholm
O  = ACME Scandinavia
OU = Security
CN = placeholder

[ usr_cert ]
basicConstraints = CA:FALSE
nsCertType = client, email
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF

# -----------------------------------------------------------------------------
# 3) Helper scripts for issuing / listing / revoking certs
# -----------------------------------------------------------------------------
echo ">>> Creating CA helper commands..."

cat > /usr/local/bin/ca-issue-employee <<'EOF'
#!/bin/bash
set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: ca-issue-employee <username>"
  exit 1
fi

CA_DIR="/root/acme-ca"
OUT_DIR="/vagrant/shared_certs/issued/$NAME"
CSR_CFG="$CA_DIR/csr/${NAME}.cnf"
CSR_FILE="$CA_DIR/csr/${NAME}.csr"

mkdir -p "$OUT_DIR"

if [ -f "$OUT_DIR/$NAME.crt" ] || grep -q "/CN=$NAME" "$CA_DIR/index.txt" 2>/dev/null; then
  echo "Certificate for $NAME already exists or was previously recorded."
  echo "Check with: ca-list"
  exit 1
fi

openssl genrsa -out "$OUT_DIR/$NAME.key" 2048

cat > "$CSR_CFG" <<EOCNF
[ req ]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[ dn ]
C = SE
ST = Stockholm
L = Stockholm
O = ACME Scandinavia
OU = Employees
CN = $NAME

[ req_ext ]
extendedKeyUsage = clientAuth
keyUsage = digitalSignature, keyEncipherment
EOCNF

openssl req -new \
  -key "$OUT_DIR/$NAME.key" \
  -out "$CSR_FILE" \
  -config "$CSR_CFG"

openssl ca -batch \
  -config "$CA_DIR/openssl.cnf" \
  -extensions usr_cert \
  -in "$CSR_FILE" \
  -out "$OUT_DIR/$NAME.crt"

cp "$CA_DIR/certs/ca.crt" "$OUT_DIR/ca.crt"

chmod 600 "$OUT_DIR/$NAME.key"
chmod 644 "$OUT_DIR/$NAME.crt" "$OUT_DIR/ca.crt"

echo "Issued employee certificate for $NAME"
echo "Output: $OUT_DIR"
EOF
chmod +x /usr/local/bin/ca-issue-employee

cat > /usr/local/bin/ca-issue-server <<'EOF'
#!/bin/bash
set -euo pipefail

NAME="${1:-vm2-srv}"
IP="${2:-10.0.1.50}"
DNS1="${3:-secure.acme.com}"
DNS2="${4:-vm2-srv}"

CA_DIR="/root/acme-ca"
OUT_DIR="/vagrant/shared_certs/issued/$NAME"
CSR_CFG="$CA_DIR/csr/${NAME}.cnf"
CSR_FILE="$CA_DIR/csr/${NAME}.csr"

mkdir -p "$OUT_DIR"

if [ -f "$OUT_DIR/$NAME.crt" ]; then
  echo "Server certificate output already exists at $OUT_DIR"
  echo "Remove it manually first if you really want to re-issue."
  exit 1
fi

openssl genrsa -out "$OUT_DIR/$NAME.key" 2048

cat > "$CSR_CFG" <<EOCNF
[ req ]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[ dn ]
C = SE
ST = Stockholm
L = Stockholm
O = ACME Scandinavia
OU = Servers
CN = $DNS1

[ req_ext ]
extendedKeyUsage = serverAuth
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $DNS1
DNS.2 = $DNS2
IP.1 = $IP
EOCNF

openssl req -new \
  -key "$OUT_DIR/$NAME.key" \
  -out "$CSR_FILE" \
  -config "$CSR_CFG"

openssl ca -batch \
  -config "$CA_DIR/openssl.cnf" \
  -extensions server_cert \
  -in "$CSR_FILE" \
  -out "$OUT_DIR/$NAME.crt"

cp "$CA_DIR/certs/ca.crt" "$OUT_DIR/ca.crt"

chmod 600 "$OUT_DIR/$NAME.key"
chmod 644 "$OUT_DIR/$NAME.crt" "$OUT_DIR/ca.crt"

echo "Issued SAN-enabled server certificate for $NAME"
echo "DNS SANs: $DNS1, $DNS2"
echo "IP SAN:   $IP"
echo "Output:   $OUT_DIR"
EOF
chmod +x /usr/local/bin/ca-issue-server

cat > /usr/local/bin/ca-list <<'EOF'
#!/bin/bash
set -euo pipefail
CA_DIR="/root/acme-ca"

echo "=== CA database (valid / revoked / expired) ==="
if [ -s "$CA_DIR/index.txt" ]; then
  awk 'BEGIN {FS="\t"; OFS=" | "} {print $1,$2,$3,$4,$5,$6}' "$CA_DIR/index.txt"
else
  echo "(empty)"
fi

echo
echo "=== Historical cert files kept in existing_ca ==="
find /vagrant/shared_certs/existing_ca -maxdepth 1 -type f 2>/dev/null | sort || true

echo
echo "=== Newly issued cert directories ==="
find /vagrant/shared_certs/issued -mindepth 1 -maxdepth 1 \( -type d -o -type f \) 2>/dev/null | sort || true
EOF
chmod +x /usr/local/bin/ca-list

cat > /usr/local/bin/ca-revoke <<'EOF'
#!/bin/bash
set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: ca-revoke <common-name>"
  exit 1
fi

CA_DIR="/root/acme-ca"
CERT="/vagrant/shared_certs/issued/$NAME/$NAME.crt"

if [ ! -f "$CERT" ]; then
  echo "Certificate not found: $CERT"
  exit 1
fi

openssl ca -config "$CA_DIR/openssl.cnf" -revoke "$CERT"
openssl ca -config "$CA_DIR/openssl.cnf" -gencrl -out "$CA_DIR/crl/ca.crl.pem"

cp "$CA_DIR/crl/ca.crl.pem" /vagrant/shared_certs/issued/ca.crl.pem
chmod 644 /vagrant/shared_certs/issued/ca.crl.pem

echo "Revoked $NAME and updated CRL."
EOF
chmod +x /usr/local/bin/ca-revoke

# Create CRL file early if possible
if [ ! -f "$CA_DIR/crl/ca.crl.pem" ]; then
    openssl ca -gencrl -config "$CA_DIR/openssl.cnf" -out "$CA_DIR/crl/ca.crl.pem" 2>/dev/null || true
fi
[ -f "$CA_DIR/crl/ca.crl.pem" ] && cp -f "$CA_DIR/crl/ca.crl.pem" /vagrant/shared_certs/issued/ca.crl.pem || true

# -----------------------------------------------------------------------------
# 5) Ensure VM2 web cert exists, but do not auto-create employee demo certs
# -----------------------------------------------------------------------------
echo ">>> Ensuring VM2 server certificate exists..."

if [ ! -d "/vagrant/shared_certs/issued/vm2-srv" ]; then
    /usr/local/bin/ca-issue-server vm2-srv 10.0.1.50 secure.acme.com vm2-srv || true
fi

# -----------------------------------------------------------------------------
# 6) KEEP EXISTING RADIUS CONFIG EXACTLY AS BEFORE
# -----------------------------------------------------------------------------
echo ">>> Configuring FreeRADIUS..."
cat >> /etc/freeradius/3.0/users << 'EOF'

testuser Cleartext-Password := "testpass123"
alice    Cleartext-Password := "alice_password123"
bob      Cleartext-Password := "bob_password456"
EOF

cat >> /etc/freeradius/3.0/clients.conf << 'EOF'

client sthlm-router {
    ipaddr = 10.0.1.0/24
    secret = acme_radius_secret
}

client london-proxy {
    ipaddr = 10.0.2.2
    secret = acme_radius_secret
}
EOF

systemctl restart freeradius
systemctl enable freeradius

# -----------------------------------------------------------------------------
# 7) KEEP EXISTING NETWORK / EXTERNAL EXPOSURE PART EXACTLY AS BEFORE
# -----------------------------------------------------------------------------
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
echo ">>> Useful commands:"
echo "    ca-issue-employee <username>"
echo "    ca-issue-server vm2-srv 10.0.1.50 secure.acme.com vm2-srv"
echo "    ca-list"
echo "    ca-revoke <username>"
# VM2 — Stockholm Server

`10.0.1.2/26` on VLAN 10. The main app server.

## Setup (run in order)

```bash
bash services/vpn/setup-ca.sh               # CA on VM3 (skip if already done)
bash services/dns/setup-dns.sh              # BIND9 + DNSSEC
bash services/dns/configure-resolvers.sh    # makes all VMs use VM2 for *.acme.internal
bash services/syncthing/setup-syncthing.sh  # Syncthing in Docker
bash services/certs/issue-vm2.sh            # server TLS cert from VM3 CA
bash services/nginx/setup-nginx.sh          # nginx vhosts with mTLS
bash services/certs/issue-client.sh alice   # client cert for testing
bash services/totp/setup-totp.sh            # TOTP 2FA validator
bash services/totp/manage-totp.sh add alice # enroll alice for TOTP
bash services/logging/setup-rsyslog.sh      # structured JSON logs

# optional, takes 10-15 min:
bash services/freeipa/setup-freeipa.sh      # FreeIPA IDM + HBAC
```

## What's running

### DNS (`services/dns/`)

BIND9 authoritative for `acme.internal`. DNSSEC via `dnssec-policy default`
(BIND manages keys automatically). Listens on `10.0.1.2` + loopback.
Forward and reverse zones for all VMs.

`configure-resolvers.sh` sets a systemd-resolved drop-in on each VM so
`*.acme.internal` queries go to VM2, everything else uses normal upstream DNS.

### Syncthing (`services/syncthing/`)

Docker container. GUI on `127.0.0.1:8384` (not exposed), sync on `22000`.
Global discovery, relays, and NAT traversal all disabled (internal network only).
Data in `/srv/syncthing/data`.

### Nginx (`services/nginx/`)

Two HTTPS vhosts, both require mTLS (client certificate signed by ACME CA):

- **`critical.acme.internal`** — on-site only (VLAN 10/20). VPN pool denied.
- **`portal.acme.internal`** — on-site + VPN. VPN clients also need TOTP.

Shared SSL config in `/etc/nginx/snippets/acme-ssl.conf`. A `geo` block
in `/etc/nginx/conf.d/acme-http.conf` sets `$is_vpn_client` for 10.0.3.0/24.

### TLS Certs (`services/certs/`)

- `issue-vm2.sh` — signs a server cert on VM3's CA with SANs for all three
  hostnames. Deploys to `/etc/nginx/certs/` on VM2.
- `issue-client.sh <name>` — signs a client cert. Outputs `.crt`, `.key`,
  `.p12` (for browser import) to `services/certs/clients/`.

### TOTP (`services/totp/`)

Flask+pyotp service on `127.0.0.1:8888`. Nginx `auth_request` calls it for
every portal request. If the client is on-site (`$is_vpn_client=0`) it returns
200 immediately. If VPN, it returns 401 which triggers a Basic Auth dialog —
user enters their 6-digit Google Authenticator code as the password.

Secrets stored in `/etc/totp-validator/secrets/<cn>.secret`.

- `manage-totp.sh add alice` — generates secret, prints otpauth:// URL to scan
- `manage-totp.sh verify alice` — generates a live code and tests the validator
- `manage-totp.sh list` / `manage-totp.sh remove alice`

### rsyslog (`services/logging/`)

Tails nginx access/error logs via `imfile`, routes everything to `/var/log/acme/`
as one-line JSON. Six log files: `nginx-critical`, `nginx-portal`, `nginx-error`,
`auth`, `totp-validator`, `syslog`. Logrotate keeps 30 days.

### FreeIPA (`services/freeipa/`) — optional

Installs FreeIPA without taking over BIND9. Creates groups (`acme-employees`,
`acme-admins`), disables default `allow_all` HBAC, adds targeted rules.
Creates sample user `alice`. Adds Kerberos/LDAP SRV records to our DNS zone.

Admin: `admin` / `ACMEipa2026!`

## Testing

```bash
# DNS
vagrant ssh vm1-gw -c 'dig +short critical.acme.internal'     # 10.0.1.2

# mTLS
vagrant ssh vm1-gw -c 'curl -sk https://critical.acme.internal'  # 400 (no cert)
vagrant ssh vm1-gw -c 'curl -s --cacert /vagrant/services/certs/vm2/ca.crt \
  --cert /vagrant/services/certs/clients/alice.crt \
  --key /vagrant/services/certs/clients/alice.key \
  https://critical.acme.internal'                               # 200

# TOTP
bash services/totp/manage-totp.sh verify alice                  # 200 OK

# Logs
vagrant ssh vm2-srv -c 'sudo tail -1 /var/log/acme/nginx-critical.log'
```

## Verified ✅

- DNS resolves from VM1 and VM2
- DNSSEC signing active
- Syncthing container healthy
- mTLS: no cert → 400, valid cert → 200
- TOTP validator returns 200 for valid codes
- rsyslog JSON logs appearing in `/var/log/acme/`

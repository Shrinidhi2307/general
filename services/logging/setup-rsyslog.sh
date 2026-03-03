#!/bin/bash
# =============================================================================
# Configure rsyslog on VM2 for structured log collection
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/logging/setup-rsyslog.sh
#
# What this script does:
#   1. Enables rsyslog imfile module (tails log files as inputs)
#   2. Defines a JSON log format for structured output
#   3. Tails nginx access/error logs and the TOTP validator journal
#   4. Routes all ACME logs to /var/log/acme/ (separate from system logs)
#   5. Configures logrotate so logs don't grow unbounded
#
# Output files in /var/log/acme/:
#   nginx-critical.log   — critical.acme.internal access (JSON)
#   nginx-portal.log     — portal.acme.internal access (JSON)
#   nginx-error.log      — nginx errors (JSON)
#   auth.log             — SSH/PAM authentication events (JSON)
#   totp-validator.log   — TOTP accept/deny events (JSON)
#   syslog.log           — general system messages (JSON)
# =============================================================================
set -euo pipefail

echo "====================================================="
echo " Configuring rsyslog on VM2"
echo "====================================================="

vagrant ssh vm2-srv -- sudo bash -s << 'LOG_EOF'
set -euo pipefail

LOG_DIR="/var/log/acme"

# ── 1. Log output directory ───────────────────────────────────────────────
echo ">>> Creating log directory..."
mkdir -p "$LOG_DIR"
chown syslog:adm "$LOG_DIR"
chmod 750 "$LOG_DIR"

# Ensure nginx custom log files are readable by rsyslog (syslog user is in adm)
for f in /var/log/nginx/critical-access.log /var/log/nginx/portal-access.log \
         /var/log/nginx/critical-error.log /var/log/nginx/portal-error.log; do
    [ -f "$f" ] && chown www-data:adm "$f" && chmod 640 "$f"
done

# ── 2. rsyslog main config drop-in ───────────────────────────────────────
echo ">>> Writing rsyslog config..."
cat > /etc/rsyslog.d/50-acme.conf << 'RSYSLOG_EOF'
# =============================================================================
# ACME rsyslog configuration — VM2 (Stockholm Server)
# =============================================================================

# Load file-tailing module (needed to ingest nginx log files)
module(load="imfile")

# ── JSON template ─────────────────────────────────────────────────────────
# All ACME logs are written as JSON for downstream processing.
# Fields: timestamp, host, facility, severity, tag, message
template(name="ACMEJson" type="list") {
    constant(value="{")
    constant(value="\"timestamp\":\"")   property(name="timereported" dateFormat="rfc3339")
    constant(value="\",\"host\":\"")     property(name="hostname")
    constant(value="\",\"facility\":\"") property(name="syslogfacility-text")
    constant(value="\",\"severity\":\"") property(name="syslogseverity-text")
    constant(value="\",\"tag\":\"")      property(name="syslogtag" format="json")
    constant(value="\",\"message\":\"")  property(name="msg" format="json")
    constant(value="\"}\n")
}

# ── Nginx access log: critical.acme.internal ──────────────────────────────
input(type="imfile"
      File="/var/log/nginx/critical-access.log"
      Tag="nginx-critical"
      Severity="info"
      Facility="local0"
      PersistStateInterval="100")

# ── Nginx access log: portal.acme.internal ────────────────────────────────
input(type="imfile"
      File="/var/log/nginx/portal-access.log"
      Tag="nginx-portal"
      Severity="info"
      Facility="local0"
      PersistStateInterval="100")

# ── Nginx error log ───────────────────────────────────────────────────────
input(type="imfile"
      File="/var/log/nginx/error.log"
      Tag="nginx-error"
      Severity="error"
      Facility="local0"
      PersistStateInterval="100")

# ── Route ACME logs to /var/log/acme/ ─────────────────────────────────────
# nginx logs (local0)
if $syslogfacility-text == "local0" and $syslogtag == "nginx-critical" then {
    action(type="omfile" file="/var/log/acme/nginx-critical.log" template="ACMEJson")
    stop
}
if $syslogfacility-text == "local0" and $syslogtag == "nginx-portal" then {
    action(type="omfile" file="/var/log/acme/nginx-portal.log" template="ACMEJson")
    stop
}
if $syslogfacility-text == "local0" and $syslogtag == "nginx-error" then {
    action(type="omfile" file="/var/log/acme/nginx-error.log" template="ACMEJson")
    stop
}

# totp-validator (systemd journal → syslog via SyslogIdentifier)
if $syslogtag startswith "totp-validator" then {
    action(type="omfile" file="/var/log/acme/totp-validator.log" template="ACMEJson")
    stop
}

# SSH / PAM authentication events
if $programname == "sshd" or $programname == "sudo" then {
    action(type="omfile" file="/var/log/acme/auth.log" template="ACMEJson")
}

# General syslog (everything not already routed above)
if $syslogfacility-text != "local0" then {
    action(type="omfile" file="/var/log/acme/syslog.log" template="ACMEJson")
}

RSYSLOG_EOF

# ── 3. Ensure totp-validator logs reach rsyslog via syslog ────────────────
# Add SyslogIdentifier to the systemd unit so rsyslog can filter it
echo ">>> Patching totp-validator systemd unit for syslog tagging..."
mkdir -p /etc/systemd/system/totp-validator.service.d
cat > /etc/systemd/system/totp-validator.service.d/logging.conf << 'SVC_EOF'
[Service]
SyslogIdentifier=totp-validator
StandardOutput=journal
StandardError=journal
SVC_EOF

systemctl daemon-reload
systemctl restart totp-validator 2>/dev/null || true

# ── 4. Validate and restart rsyslog ──────────────────────────────────────
echo ">>> Validating rsyslog config..."
rsyslogd -N1 2>&1 | grep -v "^rsyslogd" || true

echo ">>> Restarting rsyslog..."
systemctl restart rsyslog
systemctl is-active rsyslog && echo ">>> rsyslog is running." \
    || { echo "ERROR: rsyslog failed"; journalctl -u rsyslog -n 20; exit 1; }

# ── 5. Logrotate ──────────────────────────────────────────────────────────
echo ">>> Writing logrotate config..."
cat > /etc/logrotate.d/acme << 'ROTATE_EOF'
/var/log/acme/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s HUP rsyslog.service 2>/dev/null || true
    endscript
}
ROTATE_EOF

echo ""
echo ">>> rsyslog setup complete."
echo "    Log files will appear in /var/log/acme/ as traffic is generated."
echo "    Trigger test entries:"
echo "      logger -t nginx-critical 'test message'"
echo "      ls /var/log/acme/"

LOG_EOF

echo ""
echo "====================================================="
echo " rsyslog setup complete!"
echo ""
echo " Monitor logs live:"
echo "   vagrant ssh vm2-srv -c 'sudo tail -f /var/log/acme/nginx-portal.log'"
echo "   vagrant ssh vm2-srv -c 'sudo tail -f /var/log/acme/totp-validator.log'"
echo ""
echo " Trigger a test entry:"
echo "   vagrant ssh vm2-srv -c 'logger -t nginx-critical test'"
echo "   vagrant ssh vm2-srv -c 'sudo cat /var/log/acme/syslog.log | tail -3'"
echo "====================================================="

#!/bin/bash
# =============================================================================
# Manage TOTP enrollments for ACME employees
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#
#   bash services/totp/manage-totp.sh add <name>     — enroll a user
#   bash services/totp/manage-totp.sh remove <name>  — revoke a user
#   bash services/totp/manage-totp.sh list            — show enrolled users
#
# The <name> must match the CN in the employee's client certificate
# (the one issued by services/certs/issue-client.sh <name>).
#
# After 'add', scan the printed QR code (or otpauth:// URL) with
# Google Authenticator on the employee's phone.
# =============================================================================
set -euo pipefail

CMD="${1:-}"
NAME="${2:-}"

usage() {
    echo "Usage:"
    echo "  bash services/totp/manage-totp.sh add <name>"
    echo "  bash services/totp/manage-totp.sh remove <name>"
    echo "  bash services/totp/manage-totp.sh list"
    exit 1
}

[ -z "$CMD" ] && usage

case "$CMD" in

# ── Add / enroll ──────────────────────────────────────────────────────────
add)
    [ -z "$NAME" ] && { echo "Error: name required"; usage; }

    echo "====================================================="
    echo " Enrolling TOTP for: ${NAME}"
    echo "====================================================="

    # Generate secret on VM2 and retrieve the otpauth URL
    OTPAUTH=$(vagrant ssh vm2-srv -- sudo bash -s << ENROLL_EOF
set -euo pipefail

SECRETS_DIR="/etc/totp-validator/secrets"
CN="${NAME}"
SECRET_FILE="\${SECRETS_DIR}/\${CN}.secret"

if [ -f "\$SECRET_FILE" ]; then
    echo "ALREADY_ENROLLED" >&2
    SECRET=\$(cat "\$SECRET_FILE")
else
    # Generate a random base32 TOTP secret (20 bytes = 160 bits)
    SECRET=\$(python3 -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null \
        || /opt/totp-validator/venv/bin/python -c "import pyotp; print(pyotp.random_base32())")
    echo "\$SECRET" > "\$SECRET_FILE"
    chown root:totp-validator "\$SECRET_FILE"
    chmod 640 "\$SECRET_FILE"
    echo "Secret saved for \${CN}" >&2
fi

# Print the otpauth URL (used to generate QR code)
/opt/totp-validator/venv/bin/python -c "
import pyotp, sys
secret = open('/etc/totp-validator/secrets/${NAME}.secret').read().strip()
totp = pyotp.TOTP(secret)
print(totp.provisioning_uri(name='${NAME}', issuer_name='ACME Scandinavia'))
"
ENROLL_EOF
    )

    echo ""
    echo "Scan this URL with Google Authenticator:"
    echo ""
    echo "  ${OTPAUTH}"
    echo ""

    # Show QR code in terminal if qrencode is installed on the host
    if command -v qrencode &>/dev/null; then
        echo "QR Code:"
        qrencode -t ANSIUTF8 "${OTPAUTH}"
    else
        echo "Tip: install qrencode to display QR code in terminal:"
        echo "  brew install qrencode"
        echo ""
        echo "Or paste the URL above into:"
        echo "  https://www.qr-code-generator.com"
    fi

    echo ""
    echo " ${NAME} enrolled. They can now use portal.acme.internal from VPN."
    echo " Test: bash services/totp/manage-totp.sh verify ${NAME}"
    ;;

# ── Remove / revoke ───────────────────────────────────────────────────────
remove)
    [ -z "$NAME" ] && { echo "Error: name required"; usage; }

    echo ">>> Revoking TOTP for: ${NAME}..."
    vagrant ssh vm2-srv -- sudo bash -s << REVOKE_EOF
set -euo pipefail
SECRET_FILE="/etc/totp-validator/secrets/${NAME}.secret"
if [ -f "\$SECRET_FILE" ]; then
    rm "\$SECRET_FILE"
    echo "Removed TOTP secret for ${NAME}."
else
    echo "No secret found for ${NAME} — nothing to remove."
fi
REVOKE_EOF
    ;;

# ── List enrolled users ───────────────────────────────────────────────────
list)
    echo ">>> Enrolled TOTP users on VM2:"
    vagrant ssh vm2-srv -- sudo bash -s << 'LIST_EOF'
SECRETS_DIR="/etc/totp-validator/secrets"
count=0
for f in "${SECRETS_DIR}"/*.secret 2>/dev/null; do
    [ -f "$f" ] || { echo "  (none)"; break; }
    echo "  $(basename "$f" .secret)"
    count=$((count + 1))
done
[ $count -gt 0 ] && echo "" && echo "  Total: ${count} user(s)"
LIST_EOF
    ;;

# ── Verify (generate a live code and test the validator) ──────────────────
verify)
    [ -z "$NAME" ] && { echo "Error: name required"; usage; }

    echo ">>> Testing TOTP validator for: ${NAME}..."
    # NAME is expanded here on the host before the heredoc is sent to the VM.
    # All other $vars are escaped so they expand on the VM.
    vagrant ssh vm2-srv -- sudo bash -s << VERIFY_EOF
set -euo pipefail

SECRET_FILE="/etc/totp-validator/secrets/${NAME}.secret"
if [ ! -f "\$SECRET_FILE" ]; then
    echo "No secret enrolled for ${NAME}."
    exit 1
fi

CODE=\$(/opt/totp-validator/venv/bin/python3 -c "
import pyotp
secret = open('\$SECRET_FILE').read().strip()
print(pyotp.TOTP(secret).now())
")

echo "Current TOTP code for ${NAME}: \${CODE}"

ENCODED=\$(printf ':%s' "\${CODE}" | base64)

RESULT=\$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-Is-VPN-Client: 1' \
    -H 'X-SSL-Client-DN: CN=${NAME},O=ACME' \
    -H "Authorization: Basic \${ENCODED}" \
    http://127.0.0.1:8888/auth-totp)

if [ "\$RESULT" = "200" ]; then
    echo "Validator response: 200 OK — TOTP is working correctly."
else
    echo "Validator response: \${RESULT} — check journalctl -u totp-validator"
fi
VERIFY_EOF
    ;;

*)
    echo "Unknown command: ${CMD}"
    usage
    ;;
esac

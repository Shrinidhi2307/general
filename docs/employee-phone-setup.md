# Employee Phone Setup (Android)

How to set up your ACME-issued Android phone for VPN access and two-factor authentication.

## What you need

- Your Android phone (ACME-issued or personal)
- Your `.ovpn` file from IT (e.g. `alice.ovpn`)
- Access to a QR code that IT will show you during enrollment

## Step 1: Install apps

From Google Play Store, install:

1. **OpenVPN Connect** — for the VPN tunnel
2. **Google Authenticator** (or FreeOTP) — for TOTP codes

## Step 2: Import your VPN profile

1. IT gives you a `.ovpn` file (over email, USB, or AirDrop equivalent)
2. Open **OpenVPN Connect**
3. Tap the `+` button or go to **Import Profile > File**
4. Select your `.ovpn` file
5. Tap **Connect** — you should see a key icon in the status bar when connected

> Your `.ovpn` file has your client certificate baked in, so there's no separate password for the VPN itself. Don't share this file with anyone.

## Step 3: Enroll for 2FA

IT will run this on their end:

```bash
bash services/totp/manage-totp.sh add alice
```

They'll show you a QR code on screen. On your phone:

1. Open **Google Authenticator**
2. Tap `+` > **Scan a QR code**
3. Point at the QR code — "ACME Scandinavia: alice" appears
4. Done. The app now shows a 6-digit code that changes every 30 seconds

## Step 4: Access the portal

1. Make sure OpenVPN is connected (key icon in status bar)
2. Open Chrome and go to `https://portal.acme.internal`
3. You'll get a certificate prompt — accept/select your client cert
4. A login dialog pops up asking for username and password:
   - **Username:** anything (it's ignored, your identity comes from the certificate)
   - **Password:** the 6-digit code from Google Authenticator
5. You're in

> The TOTP prompt only appears when you're on VPN. If you're on the office WiFi directly, it skips straight through.

## What you can and can't access remotely

| Resource | From VPN | From office WiFi |
|----------|----------|-----------------|
| Portal (portal.acme.internal) | Yes (with TOTP) | Yes (no TOTP needed) |
| Critical data (critical.acme.internal) | No | Yes |
| DNS / internal names | Yes | Yes |
| Syncthing file sync | Yes | Yes |

The critical server is on-site only by policy. If you need that data while traveling, download what you need before you leave.

## Troubleshooting

**VPN won't connect:**
- Check you have internet first (try google.com)
- Make sure the `remote` line in your `.ovpn` points to the right server address
- Try disconnecting and reconnecting

**"No required SSL certificate" in browser:**
- Your client certificate isn't installed or the browser didn't send it
- On Android Chrome, go to Settings > Security > User credentials and check it's there

**TOTP code rejected:**
- Make sure your phone clock is accurate (Settings > Date & Time > auto)
- TOTP codes are time-based — if your clock is off by more than 30 seconds it won't work
- Wait for the next code and try again

**Can't reach portal.acme.internal:**
- Make sure VPN is connected
- Try `ping 10.0.1.2` — if that works, DNS might not be resolving. The VPN pushes DNS automatically but some Android versions ignore it

## For IT staff

```bash
# Enroll a new employee
bash services/totp/manage-totp.sh add bob

# Check who's enrolled
bash services/totp/manage-totp.sh list

# Revoke someone (lost phone, left company)
bash services/totp/manage-totp.sh remove bob

# Generate a test VPN config
bash services/vpn/issue-vpn-client.sh bob

# Verify TOTP is working server-side
bash services/totp/manage-totp.sh verify bob
```

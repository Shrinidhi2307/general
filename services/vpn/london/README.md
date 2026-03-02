# London Gateway — IPsec VPN Setup

This directory contains everything needed to configure the London side of the
ACME site-to-site IPsec/IKEv2 VPN tunnel.

## Files

| File            | Purpose                                        |
| --------------- | ---------------------------------------------- |
| `ca.crt`        | ACME root CA certificate (from VM3)            |
| `london.crt`    | London gateway certificate (signed by ACME CA) |
| `london.key`    | London gateway private key (**keep secure!**)  |
| `ipsec.conf`    | StrongSwan configuration for the London side   |
| `ipsec.secrets` | Private key reference for IPsec authentication |

## Quick Setup

```bash
# 1. Install StrongSwan
sudo apt update
sudo apt install -y strongswan strongswan-pki libcharon-extra-plugins

# 2. Install certificates
sudo cp ca.crt     /etc/ipsec.d/cacerts/
sudo cp london.crt /etc/ipsec.d/certs/
sudo cp london.key /etc/ipsec.d/private/
sudo chmod 600     /etc/ipsec.d/private/london.key

# 3. Install configuration
sudo cp ipsec.conf    /etc/ipsec.conf
sudo cp ipsec.secrets /etc/ipsec.secrets
sudo chmod 600        /etc/ipsec.secrets

# 4. Enable IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-forward.conf
sudo sysctl -p /etc/sysctl.d/99-forward.conf

# 5. Update the remote IP
# Edit /etc/ipsec.conf and replace 'right=%any' with Stockholm's
# actual IP on the shared LAN between your routers.

# 6. Start and verify
sudo systemctl enable --now strongswan-starter
sudo ipsec restart
sudo ipsec statusall
```

## Before You Start

1. **Update `right=` in ipsec.conf** — Replace `%any` with Stockholm router's
   IP on the shared LAN. Stockholm side also needs London's IP set.
2. **Firewall** — Allow UDP 500, UDP 4500, and ESP protocol inbound:
   ```bash
   sudo ufw allow 500,4500/udp comment 'IKEv2/IPsec'
   sudo ufw allow proto esp from any to any comment 'IPsec ESP'
   ```
3. **NAT exclusion** — If your gateway does NAT, exclude tunnel-bound traffic:
   ```bash
   # In /etc/ufw/before.rules, inside the *nat section, BEFORE your masquerade rule:
   -A POSTROUTING -s 10.0.1.128/26 -d 10.0.1.0/26 -j ACCEPT
   -A POSTROUTING -s 10.0.1.128/26 -d 10.0.1.240/28 -j ACCEPT
   ```

## Verification

```bash
# Check tunnel status
sudo ipsec statusall

# Manually initiate tunnel
sudo ipsec up london-stockholm

# Check routing
ip route

# Test connectivity to Stockholm Server VLAN
ping 10.0.1.2    # VM2 (Server)
ping 10.0.1.242  # VM6 (DMZ)

# Live logs
sudo journalctl -u strongswan-starter -f
```

## Network Reference

| Site              | Subnet        | Description |
| ----------------- | ------------- | ----------- |
| Stockholm VLAN 10 | 10.0.1.0/26   | Server + CA |
| Stockholm VLAN 30 | 10.0.1.240/28 | DMZ         |
| London VLAN 20    | 10.0.1.128/26 | Client      |

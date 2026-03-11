# Site-to-Site IPsec VPN — Connection Walkthrough

## How the Connection Works

### Physical Topology

The S2S VPN is now terminated on the physical routers (WireGuard). The VM-based StrongSwan
configuration in this directory is retained for reference/reproducibility but the primary S2S
tunnel runs between the Stockholm (DD-WRT) and London (OpenWrt) routers.

London VM4 still runs StrongSwan for roadwarrior remote access.

### IKEv2 Negotiation Flow (VM4 — roadwarrior)

1. **Remote client initiates** — sends IKE_SA_INIT to VM4
2. **IKE_SA_INIT exchange** — negotiates crypto (AES256-SHA256-MODP2048), exchanges DH keys
3. **IKE_AUTH exchange** — both sides present x509 certificates signed by ACME-CA
4. **CHILD_SA (ESP tunnel) installed** — kernel xfrm policies encrypt traffic

### NAT Exclusion

VM4 runs MASQUERADE for internet-bound traffic. Without NAT exclusion, tunnel-bound packets would be NAT'd before hitting the xfrm policy. An iptables ACCEPT rule is inserted before MASQUERADE:

```
-A POSTROUTING -s 10.0.2.0/24 -d 10.0.1.0/24 -j ACCEPT   # on VM4
```

### Dead Peer Detection (DPD)

If a peer goes silent for 30s, DPD probes are sent. After 120s of no response the tunnel is torn down and automatically re-established (`dpdaction=restart`).

---

## Setup Procedure (Lab)

```bash
# 1. Bring up VM4
vagrant up vm4-gw

# 2. Generate PKI (needs VM3 running)
vagrant up vm3-ca
bash services/vpn/setup-ca.sh
vagrant halt vm3-ca            # air-gap it again

# 3. Deploy VPN configs, certs
bash services/vpn/setup-s2s.sh

# 4. Verify
bash services/vpn/test-s2s.sh
```

---

## Key Configuration Files

| File | Deployed to | Role |
|------|-------------|------|
| `london/ipsec.conf` | VM4 `/etc/ipsec.conf` | London side — `auto=add` (responder) |
| `london/ipsec.secrets` | VM4 `/etc/ipsec.secrets` | References `london.key` |
| `certs/ca.crt` | VM4 `/etc/ipsec.d/cacerts/` | Root CA certificate |
| `certs/london.crt` | VM4 `/etc/ipsec.d/certs/` | London gateway cert |
| `certs/london.key` | VM4 `/etc/ipsec.d/private/` | London private key (mode 600) |

---

## What to Change for Real Deployment

### 1. WAN Addresses

Replace the VirtualBox internal network IPs with real public IPs or routable addresses.
If either side is behind NAT, add `leftfirewall=yes` and consider using `%any` for the NATed side's `right=` value, or enable NAT-T (`forceencaps=yes`).

### 2. Certificates

Replace lab certs with certs from your real PKI or a commercial CA:

- Regenerate with proper FQDNs matching your DNS
- Use a longer key (4096-bit RSA or ECDSA P-384/P-521)
- Set proper certificate lifetimes and plan for renewal
- Update `leftid`/`rightid` to match the new certificate SANs

### 3. Crypto Parameters

The lab uses strong defaults, but review for your compliance requirements:

```ini
# Current (good for most cases):
ike=aes256-sha256-modp2048!
esp=aes256-sha256-modp2048!

# Stronger option (if hardware supports it):
ike=aes256gcm16-sha384-ecp384!
esp=aes256gcm16-sha384!
```

### 4. Subnets

Update `leftsubnet` and `rightsubnet` to match your actual site networks.

### 5. Debug Logging

Turn down debug verbosity — the lab config is verbose for troubleshooting:

```diff
 config setup
-    charondebug="ike 2, knl 2, cfg 2, net 2, esp 2, dmn 2, mgr 2"
+    charondebug="ike 1, knl 1, cfg 0, net 0, esp 0, dmn 0, mgr 0"
```

### 6. NAT Exclusion

Update the iptables rules and `before.rules` entries to match your real subnets. If you're not running NAT on the gateways (e.g., using proper routing), you can remove the NAT exclusion entirely.

### 7. Firewall

In production:
- Allow UDP 500 (IKE) and UDP 4500 (NAT-T) on WAN-facing interfaces
- Allow ESP (protocol 50) if not using NAT-T
- Keep suricata/fail2ban enabled and tuned for your traffic

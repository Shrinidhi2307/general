# Site-to-Site IPsec VPN — Connection Walkthrough

## How the Connection Works

### Physical Topology

```
Stockholm (VM1)                          London (VM4)
┌─────────────────┐    acme-wan (intnet)    ┌─────────────────┐
│  10.100.0.1/30  │◄──────────────────────►│  10.100.0.2/30  │
│    enp0s16      │   point-to-point link   │    enp0s10      │
└────────┬────────┘                         └────────┬────────┘
         │                                           │
   ┌─────┴──────┐                              ┌─────┴──────┐
   │ VLAN 10    │ 10.0.1.0/26                  │ VLAN 10    │ 10.0.2.0/26
   │ VLAN 20    │ 10.0.1.128/26                │ VLAN 20    │ 10.0.2.128/26
   │ VLAN 30    │ 10.0.1.240/28                └────────────┘
   └────────────┘
```

In the lab, `acme-wan` is a VirtualBox internal network simulating a WAN link.
In production this would be a public internet link or dedicated MPLS/leased line.

### IKEv2 Negotiation Flow

1. **VM1 initiates** (`auto=start`) — sends IKE_SA_INIT to VM4 (`auto=add`, responder only)
2. **IKE_SA_INIT exchange** — negotiates crypto (AES256-SHA256-MODP2048), exchanges DH keys
3. **IKE_AUTH exchange** — both sides present x509 certificates signed by ACME-CA:
   - VM1 sends `stockholm.crt` (SAN: `DNS:stockholm.acme.corp`)
   - VM4 sends `london.crt` (SAN: `DNS:london.acme.corp`)
   - Each side verifies the peer cert against `ca.crt` in `/etc/ipsec.d/cacerts/`
   - Identity matching: `leftid`/`rightid` are checked against the cert's SAN field
4. **CHILD_SA (ESP tunnel) installed** — kernel xfrm policies encrypt traffic between the declared subnets

### What Gets Encrypted

All traffic matching these subnet pairs goes through the ESP tunnel:

| Source (leftsubnet)              | Destination (rightsubnet)        |
|----------------------------------|----------------------------------|
| Stockholm 10.0.1.0/26 (VLAN 10) | London 10.0.2.0/26 (VLAN 10)    |
| Stockholm 10.0.1.128/26 (VLAN 20)| London 10.0.2.128/26 (VLAN 20) |
| Stockholm 10.0.1.240/28 (VLAN 30)| London 10.0.2.0/26 (VLAN 10)   |
| *(and all reverse directions)*   |                                  |

Traffic between the gateways' WAN IPs (10.100.0.x) is **not** tunneled — only subnet-to-subnet traffic is.

### NAT Exclusion

Both gateways run MASQUERADE for internet-bound traffic. Without NAT exclusion, tunnel-bound packets would be NAT'd before hitting the xfrm policy, causing a mismatch. An iptables ACCEPT rule is inserted before MASQUERADE:

```
-A POSTROUTING -s 10.0.1.0/24 -d 10.0.2.0/24 -j ACCEPT   # on VM1
-A POSTROUTING -s 10.0.2.0/24 -d 10.0.1.0/24 -j ACCEPT   # on VM4
```

### Dead Peer Detection (DPD)

If a peer goes silent for 30s, DPD probes are sent. After 120s of no response the tunnel is torn down and automatically re-established (`dpdaction=restart`).

---

## Setup Procedure (Lab)

```bash
# 1. Bring up VMs (or just the two gateways)
vagrant up vm1-gw vm4-gw

# 2. Generate PKI (needs VM3 running)
vagrant up vm3-ca
bash services/vpn/setup-ca.sh
vagrant halt vm3-ca            # air-gap it again

# 3. Deploy VPN configs, certs, and bring up tunnel
bash services/vpn/setup-s2s.sh

# 4. Verify
bash services/vpn/test-s2s.sh
```

---

## Key Configuration Files

| File | Deployed to | Role |
|------|-------------|------|
| `ipsec.conf` | VM1 `/etc/ipsec.conf` | Stockholm side — `auto=start` (initiator) |
| `london/ipsec.conf` | VM4 `/etc/ipsec.conf` | London side — `auto=add` (responder) |
| `ipsec.secrets` | VM1 `/etc/ipsec.secrets` | References `stockholm.key` |
| `london/ipsec.secrets` | VM4 `/etc/ipsec.secrets` | References `london.key` |
| `certs/ca.crt` | Both `/etc/ipsec.d/cacerts/` | Root CA certificate |
| `certs/stockholm.crt` | VM1 `/etc/ipsec.d/certs/` | Stockholm gateway cert |
| `certs/stockholm.key` | VM1 `/etc/ipsec.d/private/` | Stockholm private key (mode 600) |
| `certs/london.crt` | VM4 `/etc/ipsec.d/certs/` | London gateway cert |
| `certs/london.key` | VM4 `/etc/ipsec.d/private/` | London private key (mode 600) |

---

## What to Change for Real Deployment

### 1. WAN Addresses

Replace the VirtualBox internal network IPs with real public IPs or routable addresses:

```diff
 # ipsec.conf (Stockholm)
-left=10.100.0.1
+left=<stockholm-public-ip>
-right=10.100.0.2
+right=<london-public-ip>

 # london/ipsec.conf
-left=10.100.0.2
+left=<london-public-ip>
-right=10.100.0.1
+right=<stockholm-public-ip>
```

If either side is behind NAT, add `leftfirewall=yes` and consider using `%any` for the NATed side's `right=` value, or enable NAT-T (`forceencaps=yes`).

### 2. Certificates

Replace lab certs with certs from your real PKI or a commercial CA:

- Regenerate with proper FQDNs matching your DNS (e.g., `vpn-gw.stockholm.acme.com`)
- Use a longer key (4096-bit RSA or ECDSA P-384/P-521)
- Set proper certificate lifetimes and plan for renewal
- Update `leftid`/`rightid` to match the new certificate SANs
- Update `rightca` if the CA DN changes

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

Update `leftsubnet` and `rightsubnet` to match your actual site networks:

```diff
 # ipsec.conf (Stockholm)
-leftsubnet=10.0.1.0/26,10.0.1.128/26,10.0.1.240/28
+leftsubnet=<stockholm-server-net>,<stockholm-client-net>,<stockholm-dmz-net>
-rightsubnet=10.0.2.0/26,10.0.2.128/26
+rightsubnet=<london-server-net>,<london-client-net>
```

### 5. Debug Logging

Turn down debug verbosity — the lab config is verbose for troubleshooting:

```diff
 config setup
-    charondebug="ike 2, knl 2, cfg 2, net 2, esp 2, dmn 2, mgr 2"
+    charondebug="ike 1, knl 1, cfg 0, net 0, esp 0, dmn 0, mgr 0"
```

### 6. NAT Exclusion

Update the iptables rules and `before.rules` entries to match your real subnets. If you're not running NAT on the gateways (e.g., using proper routing), you can remove the NAT exclusion entirely.

### 7. WAN Interface Detection

The lab's auto-detection logic in `setup-s2s.sh` (find unconfigured interface) is a lab convenience. In production, configure the WAN interface explicitly via netplan/networkd with a known interface name.

### 8. Firewall

The lab disables suricata/fail2ban for simplicity. In production:
- Allow UDP 500 (IKE) and UDP 4500 (NAT-T) on WAN-facing interfaces
- Allow ESP (protocol 50) if not using NAT-T
- Keep suricata/fail2ban enabled and tuned for your traffic

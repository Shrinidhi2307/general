# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

KTH networks course project: ACME Corp multi-site network infrastructure using Vagrant/VirtualBox VMs on macOS. Stockholm site: VM1 (Gateway), VM2 (Server), VM3 (CA), VM6 (DMZ). London site: VM4 (Gateway), VM5 (RADIUS Proxy).

## Architecture

### Network Topology — Stockholm
- **VM1 (vm1-gw)**: Multi-homed gateway with 4 NICs — Vagrant NAT (enp0s3, internet) + three internal VLANs (enp0s8/9/10)
- **VM2 (vm2-srv)**: Server VLAN 10 (10.0.1.2/26) — runs Nginx, BIND9 DNS, Syncthing
- **VM3 (vm3-ca)**: VLAN 10 (10.0.1.3/26) — air-gapped CA server with FreeRADIUS, no internet route
- **VM6 (vm6-dmz)**: VLAN 30 / DMZ (10.0.1.242/28) — Docker, Nginx, Certbot for spin-off web

### Network Topology — London
- **VM4 (vm4-gw)**: London gateway with 3 NICs — Vagrant NAT (enp0s3) + two VLANs (enp0s8/9). IKEv2/IPsec S2S, OpenVPN server, Suricata, Fail2ban
- **VM5 (vm5-radius)**: London VLAN 10 (10.0.2.2/26) — FreeRADIUS proxy to VM3 via IPsec tunnel

### VLAN Subnets (VirtualBox Internal Networks)
Stockholm:
- VLAN 10 (acme-vlan10): 10.0.1.0/26 — Server/CA
- VLAN 20 (acme-vlan20): 10.0.1.128/26 — Client
- VLAN 30 (acme-vlan30): 10.0.1.240/28 — DMZ

London:
- VLAN 10 (london-vlan10): 10.0.2.0/26 — Server (RADIUS)
- VLAN 20 (london-vlan20): 10.0.2.128/26 — Client

### Interface Mapping
- enp0s3: Vagrant NAT (management/internet, present on all VMs)
- enp0s8: First VLAN interface
- enp0s9: Second VLAN interface (VM1/VM4 only: VLAN 20)
- enp0s10: Third VLAN interface (VM1 only: VLAN 30)

### Key Security Policies
- VM3 is air-gapped (DHCP route override removes default route)
- DMZ is isolated from internal VLANs (deny rules before allow)
- VM1 and VM4 use DEFAULT_FORWARD_POLICY=DROP with explicit allow rules
- IPsec (IKEv2) for site-to-site VPN between Stockholm and London

## Scripts

All scripts run from the host in the project directory (where Vagrantfile lives).

| Script | Purpose |
|---|---|
| `Vagrantfile` | Defines all 6 VMs with VirtualBox networking |
| `provision/vm1-gw.sh` | Stockholm gateway provisioner: packages, IP forwarding, NAT |
| `provision/vm2-srv.sh` | Stockholm server provisioner: packages, inter-VLAN routes |
| `provision/vm3-ca.sh` | CA provisioner: packages, air-gap netplan |
| `provision/vm6-dmz.sh` | DMZ provisioner: packages, inter-VLAN routes |
| `provision/vm4-gw.sh` | London gateway provisioner: packages, IP forwarding, NAT, OpenVPN |
| `provision/vm5-radius.sh` | London RADIUS proxy provisioner: packages, routes |
| `configure-ufw-stockholm.sh` | Applies UFW firewall rules to Stockholm VMs |
| `configure-ufw-london.sh` | Applies UFW firewall rules to London VMs |
| `test-firewall-stockholm.sh` | Verifies Stockholm firewall policies |
| `test-firewall-london.sh` | Verifies London firewall policies |
| `reset-ufw-stockholm.sh` | Strips UFW rules on Stockholm VMs |
| `reset-ufw-london.sh` | Strips UFW rules on London VMs |

### Running

```bash
# Initial setup (from project directory)
brew install --cask virtualbox vagrant
vagrant up                     # All VMs
vagrant up vm4-gw vm5-radius   # London only

# Configure firewalls and test
bash configure-ufw-stockholm.sh
bash test-firewall-stockholm.sh
bash configure-ufw-london.sh
bash test-firewall-london.sh
```

### Accessing VMs
```bash
vagrant ssh vm1-gw
vagrant ssh vm2-srv
vagrant ssh vm3-ca
vagrant ssh vm6-dmz
vagrant ssh vm4-gw
vagrant ssh vm5-radius
```

# ACME Corp — Multi-Site Network

KTH networks course project. Multi-site corporate network built with Vagrant/VirtualBox VMs.

Stockholm runs 4 VMs (VM1, VM2, VM3, VM6). London runs 2 VMs (VM4, VM5). Both sites are in a single Vagrantfile and connected via IPsec VPN.

## Network Topology

```
             Internet                              Internet
                │                                     │
          ┌─────┴──────┐                        ┌─────┴──────┐
          │   VM1-GW   │  enp0s3: NAT           │   VM4-GW   │  enp0s3: NAT
          │  Stockholm  │  enp0s8: 10.0.1.1/26   │   London   │  enp0s8: 10.0.2.1/26
          │   Gateway   │  enp0s9: 10.0.1.129/26 │   Gateway   │  enp0s9: 10.0.2.129/26
          │            │  enp0s10: 10.0.1.241/28 │            │
          └──┬───┬──┬──┘                        └──┬───┬─────┘
             │   │  │    ── IPsec S2S tunnel ──    │   │
    ┌────────┘   │  └────────┐            ┌────────┘   │
    │            │           │            │            │
 VLAN 10     VLAN 20     VLAN 30       VLAN 10     VLAN 20
10.0.1.0/26  10.0.1.128/26  10.0.1.240/28  10.0.2.0/26  10.0.2.128/26
(Server/CA)  (Client)      (DMZ)        (RADIUS)    (Client)
    │                        │            │
 ┌──┴───┐               ┌───┴───┐     ┌──┴─────┐
 │VM2   │ 10.0.1.2      │VM6    │     │VM5     │ 10.0.2.2
 │Server│ Nginx, BIND9,  │DMZ    │     │RADIUS  │ FreeRADIUS
 │      │ Syncthing      │       │     │Proxy   │ (proxy to VM3)
 ├──────┤               └───────┘     └────────┘
 │VM3   │ 10.0.1.3
 │CA    │ FreeRADIUS, EasyRSA
 │      │ (air-gapped)
 └──────┘
```

## Prerequisites

- [VirtualBox](https://www.virtualbox.org/) 7.x
- [Vagrant](https://www.vagrantup.com/) 2.4+
- **32 GB RAM** recommended for all 6 VMs (16 GB is fine for one site at a time)
- ~50 GB disk available

### macOS

```bash
brew install --cask virtualbox vagrant
```

### Windows

1. Install [VirtualBox](https://www.virtualbox.org/wiki/Downloads) and [Vagrant](https://developer.hashicorp.com/vagrant/install#windows).
2. Reboot after both installers finish.

> **Note:** Hyper-V must be disabled for VirtualBox. In elevated PowerShell: `bcdedit /set hypervisorlaunchtype off`, then reboot.

### Linux

```bash
sudo apt-get install -y virtualbox vagrant
```

## Quick Start

```bash
# Bring up everything
vagrant up

# Or just one site
vagrant up vm1-gw vm2-srv vm3-ca vm6-dmz    # Stockholm
vagrant up vm4-gw vm5-radius                 # London

# Configure firewalls
bash configure-ufw-stockholm.sh
bash configure-ufw-london.sh

# Test
bash test-firewall-stockholm.sh
bash test-firewall-london.sh
```

> **Windows users:** Bash scripts need Git Bash or WSL. `vagrant` commands work in PowerShell.

### Running Individual VMs

You don't have to bring up everything at once. On a 16 GB machine, bring up only the VMs you need. Note that inter-VLAN routing requires the site's gateway (VM1 or VM4) to be running.

```bash
vagrant up vm1-gw            # Start only the Stockholm gateway
vagrant up vm4-gw vm5-radius # Start London
vagrant halt vm3-ca          # Stop one VM
vagrant destroy vm6-dmz -f   # Destroy and recreate just the DMZ
vagrant provision vm2-srv    # Re-run the provisioner on one VM
```

## VMs

### Stockholm

| VM  | Hostname | VLAN       | IP                   | Key Services                                  |
| --- | -------- | ---------- | -------------------- | --------------------------------------------- |
| VM1 | vm1-gw   | 10, 20, 30 | 10.0.1.1, .129, .241 | StrongSwan IPsec, Suricata IDS, Fail2ban, NAT |
| VM2 | vm2-srv  | 10         | 10.0.1.2             | Nginx, BIND9, Docker, Syncthing               |
| VM3 | vm3-ca   | 10         | 10.0.1.3             | FreeRADIUS, Easy-RSA (air-gapped)             |
| VM6 | vm6-dmz  | 30         | 10.0.1.242           | Docker, Nginx, Certbot                        |

### London

| VM  | Hostname   | VLAN   | IP             | Key Services                                           |
| --- | ---------- | ------ | -------------- | ------------------------------------------------------ |
| VM4 | vm4-gw     | 10, 20 | 10.0.2.1, .129 | StrongSwan IPsec, OpenVPN, Suricata IDS, Fail2ban, NAT |
| VM5 | vm5-radius | 10     | 10.0.2.2       | FreeRADIUS (proxy to VM3 via IPsec)                    |

## SSH Access

```bash
# Stockholm
vagrant ssh vm1-gw
vagrant ssh vm2-srv
vagrant ssh vm3-ca
vagrant ssh vm6-dmz

# London
vagrant ssh vm4-gw
vagrant ssh vm5-radius
```

## Scripts

| Script                       | Purpose                                   |
| ---------------------------- | ----------------------------------------- |
| `configure-ufw-stockholm.sh` | Apply UFW firewall rules to Stockholm VMs |
| `configure-ufw-london.sh`    | Apply UFW firewall rules to London VMs    |
| `test-firewall-stockholm.sh` | Verify Stockholm firewall policies        |
| `test-firewall-london.sh`    | Verify London firewall policies           |
| `reset-ufw-stockholm.sh`     | Disable all UFW rules on Stockholm VMs    |
| `reset-ufw-london.sh`        | Disable all UFW rules on London VMs       |

## Interface Mapping (VirtualBox)

All VMs have a Vagrant NAT adapter (`enp0s3`) for management. VLAN interfaces:

| VM  | enp0s8               | enp0s9               | enp0s10              |
| --- | -------------------- | -------------------- | -------------------- |
| VM1 | VLAN 10 (10.0.1.1)   | VLAN 20 (10.0.1.129) | VLAN 30 (10.0.1.241) |
| VM2 | VLAN 10 (10.0.1.2)   | —                    | —                    |
| VM3 | VLAN 10 (10.0.1.3)   | —                    | —                    |
| VM6 | VLAN 30 (10.0.1.242) | —                    | —                    |
| VM4 | VLAN 10 (10.0.2.1)   | VLAN 20 (10.0.2.129) | —                    |
| VM5 | VLAN 10 (10.0.2.2)   | —                    | —                    |

## Firewall Policy Summary

**VM1 (Stockholm Gateway):**

- Default deny incoming/routed, allow outgoing
- NAT masquerade for 10.0.1.0/24 outbound on enp0s3
- DMZ blocked from Server and Client VLANs (deny before allow)
- VLANs 10/20/30 allowed outbound to internet
- Internet inbound to DMZ on ports 80/443 only
- VLAN 20 → VLAN 10 restricted to ports 443, 8384, 53 (not VM3)

**VM2 (Server):** deny incoming except SSH, HTTP/S, DNS, Syncthing (8384, 22000)

**VM3 (CA):** deny incoming except SSH, RADIUS (1812-1813/udp). Air-gapped (no default route).

**VM6 (DMZ):** deny incoming except SSH, HTTP/S

**VM4 (London Gateway):**

- Default deny incoming/routed, allow outgoing
- NAT masquerade for 10.0.2.0/24 outbound on enp0s3
- IPsec (UDP 500/4500, ESP) and OpenVPN (UDP 1194) allowed
- London VLANs 10/20 allowed outbound to internet
- VLAN 20 → VLAN 10 restricted to ports 443, 8384, 53, RADIUS (1812-1813)

**VM5 (RADIUS Proxy):** deny incoming except SSH, RADIUS (1812-1813/udp)

## Vagrant Tips

```bash
vagrant status              # Show state of all VMs
vagrant up                  # Create/start all VMs
vagrant halt                # Stop all VMs (preserves disk)
vagrant destroy -f          # Delete all VMs and their disks
vagrant snapshot save vm1-gw clean-baseline
vagrant snapshot restore vm1-gw clean-baseline
```

## Known Issues

**Air-gap uses DHCP override:** VM3's air-gap is implemented by disabling DHCP-provided routes on enp0s3 (`dhcp4-overrides: use-routes: false`). The Vagrant NAT interface stays up for `vagrant ssh` but has no default route. To temporarily restore internet on VM3 for package installs:

```bash
vagrant ssh vm3-ca -c "sudo ip route add default via 10.0.2.2 dev enp0s3"
# ... install packages ...
vagrant ssh vm3-ca -c "sudo ip route del default via 10.0.2.2 dev enp0s3"
```

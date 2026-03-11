# ACME Corp — Multi-Site Network

KTH networks course project. Multi-site corporate network built with OpenWrt routers and Vagrant/VirtualBox VMs.

Stockholm runs 3 VMs (VM2, VM3, VM6) behind an OpenWrt router. London runs 1 VM (VM5) behind an OpenWrt router. The routers handle site-to-site WireGuard VPN, WiFi, and firewall. VMs provide application services.

## Network Topology

```
                        WireGuard S2S
  Stockholm Router ◄──────────────────────► London Router
  (OpenWrt)                                  (OpenWrt)
  WAN: 130.237.11.42                         WAN: DHCP
  wg0: 10.0.3.1                              wg0: 10.0.3.2
       │                                          │
  ┌────┴──────────────────────┐             ┌─────┴──────────────┐
  │         │         │       │             │         │          │
 LAN    Employee   Guest    DMZ            LAN    Employee    Guest
10.0.1.0  10.0.1.128 10.0.4.0 10.0.1.240  10.0.2.0  10.0.2.0  10.0.4.0
 /24       /25        /24      /28          /24       /24        /24
  │                             │             │
  │  ┌──────┐                   │          ┌──┴─────┐
  ├──│VM2   │ .2                │          │VM5     │ .2
  │  │Server│ Nginx, BIND9,     │          │RADIUS  │ FreeRADIUS
  │  │      │ Syncthing         │          │Proxy   │ (proxy→VM3)
  │  ├──────┤               ┌───┴───┐      └────────┘
  │  │VM3   │ .3            │VM6    │ .242
  │  │CA    │ FreeRADIUS,   │DMZ    │ Docker, Nginx,
  │  │      │ EasyRSA       │       │ Certbot
  │  └──────┘               └───────┘
  │
  ├── Host PC 10.0.1.24 (bridged to VM2 via enp0s9)
```

## Prerequisites

- [VirtualBox](https://www.virtualbox.org/) 7.x
- [Vagrant](https://www.vagrantup.com/) 2.4+
- **32 GB RAM** recommended
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
vagrant up vm2-srv vm3-ca vm6-dmz         # Stockholm
vagrant up vm5-radius                      # London

# Configure firewalls
bash configure-ufw-stockholm.sh
bash configure-ufw-london.sh

# Test
bash test-firewall-stockholm.sh
bash test-firewall-london.sh
```

> **Windows users:** Bash scripts need Git Bash or WSL. `vagrant` commands work in PowerShell.

### Running Individual VMs

You don't have to bring up everything at once.

```bash
vagrant up vm2-srv           # Start only the Stockholm server
vagrant up vm5-radius        # Start London RADIUS
vagrant halt vm3-ca          # Stop one VM
vagrant destroy vm6-dmz -f   # Destroy and recreate just the DMZ
vagrant provision vm2-srv    # Re-run the provisioner on one VM
```

## VMs

### Stockholm

| VM  | Hostname | Subnet | IP         | Key Services                      |
| --- | -------- | ------ | ---------- | --------------------------------- |
| VM2 | vm2-srv  | LAN    | 10.0.1.2   | Nginx, BIND9, Docker, Syncthing   |
| VM3 | vm3-ca   | LAN    | 10.0.1.3   | FreeRADIUS, Easy-RSA (air-gapped) |
| VM6 | vm6-dmz  | DMZ    | 10.0.1.242 | Docker, Nginx, Certbot            |

### London

| VM  | Hostname   | Subnet | IP       | Key Services                            |
| --- | ---------- | ------ | -------- | --------------------------------------- |
| VM5 | vm5-radius | LAN    | 10.0.2.2 | FreeRADIUS (proxy to VM3 via WireGuard) |

## SSH Access

```bash
# Stockholm
vagrant ssh vm2-srv
vagrant ssh vm3-ca
vagrant ssh vm6-dmz

# London
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

| VM  | enp0s8               | enp0s9              |
| --- | -------------------- | ------------------- |
| VM2 | VLAN 10 (10.0.1.2)   | Bridged (10.0.1.50) |
| VM3 | VLAN 10 (10.0.1.3)   | —                   |
| VM6 | VLAN 30 (10.0.1.242) | —                   |
| VM5 | LAN (10.0.2.2)       | Bridged (10.0.2.50) |

## Firewall Policy Summary

### Router Firewalls (OpenWrt)

**Stockholm Router:** default REJECT input/forward, ACCEPT output. Zones: lan, wan (masq), employee, guest (fwd REJECT), vpn (no masq). VPN→Critical (10.0.1.2) blocked.

**London Router:** default REJECT input/forward, ACCEPT output. Zones: lan, wan (masq), employee, guest (fwd ACCEPT, masq), vpn (masq).

### VM Firewalls (UFW)

**VM2 (Server):** deny incoming except SSH, HTTP/S, DNS, Syncthing (8384, 22000)

**VM3 (CA):** deny incoming except SSH, RADIUS (1812-1813/udp). Air-gapped (no default route).

**VM6 (DMZ):** deny incoming except SSH, HTTP/S

**VM5 (RADIUS Proxy):** deny incoming except SSH, RADIUS (1812-1813/udp)

## Vagrant Tips

```bash
vagrant status              # Show state of all VMs
vagrant up                  # Create/start all VMs
vagrant halt                # Stop all VMs (preserves disk)
vagrant destroy -f          # Delete all VMs and their disks
```

## Known Issues

**Air-gap uses DHCP override:** VM3's air-gap is implemented by disabling DHCP-provided routes on enp0s3 (`dhcp4-overrides: use-routes: false`). The Vagrant NAT interface stays up for `vagrant ssh` but has no default route. To temporarily restore internet on VM3 for package installs:

```bash
vagrant ssh vm3-ca -c "sudo ip route add default via 10.0.2.2 dev enp0s3"
# ... install packages ...
vagrant ssh vm3-ca -c "sudo ip route del default via 10.0.2.2 dev enp0s3"
```

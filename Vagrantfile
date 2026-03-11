# -*- mode: ruby -*-
# vi: set ft=ruby :
# =============================================================================
# ACME Multi-Site Network — VirtualBox VMs via Vagrant
# =============================================================================
# Creates Stockholm: VM2 (Server), VM3 (CA), VM6 (DMZ)
#         London:    VM5 (RADIUS Proxy)
#
# The host PC (10.0.1.24) bridges to VM2 for Stockholm network access.
#
# USAGE:
#   brew install --cask virtualbox vagrant
#   vagrant up                    # All VMs
#   vagrant up vm5-radius          # London only
#   vagrant ssh vm2-srv
#
# NETWORKING:
#   Each VM gets a Vagrant NAT adapter (enp0s3) for management/provisioning.
#   VLAN interfaces use VirtualBox internal networks:
#
#   Stockholm:
#     acme-vlan10  — Server VLAN (10.0.1.0/26)
#     acme-vlan30  — DMZ VLAN   (10.0.1.240/28)
#
#   London:
#     london-vlan10 — Server VLAN (10.0.2.0/26)
# =============================================================================

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  # ──────────────────────────────────────────────
  # VM2: Stockholm Server
  # ──────────────────────────────────────────────
  config.vm.define "vm2-srv" do |srv|
    srv.vm.hostname = "vm2-srv"
    srv.vm.provider "virtualbox" do |vb|
      vb.name = "acme-vm2-srv"
      vb.memory = 8192
      vb.cpus = 4
    end
    # VLAN 10 — Server (enp0s8) — internal link to VM3/CA
    srv.vm.network "private_network", ip: "10.0.1.2",
      netmask: "255.255.255.192",
      virtualbox__intnet: "acme-vlan10"
    # Bridged adapter (enp0s9) — connects to physical LAN / OpenWrt router.
    # Vagrant will prompt to select the host adapter; pick the NIC that is
    # plugged into the router's LAN port.
    srv.vm.network "public_network",
      ip: "10.0.1.50",
      netmask: "255.255.255.192"
    srv.vm.provision "shell", path: "provision/vm2-srv.sh"
    # Route fix must run on every boot (not just first provision)
    srv.vm.provision "shell", run: "always", inline: <<-SHELL
      if ip link show enp0s9 >/dev/null 2>&1; then
        ip route del 10.0.1.0/26 dev enp0s8 2>/dev/null || true
        ip route replace 10.0.1.0/26 dev enp0s9 src 10.0.1.50 metric 50
        ip route add 10.0.1.0/26 dev enp0s8 src 10.0.1.2 metric 200 2>/dev/null || true
        ip route add 10.0.1.128/26 via 10.0.1.1 dev enp0s9 2>/dev/null || true
        # VPN + London return routes — so VM2 can reply to traffic arriving via WireGuard
        ip route add 10.0.3.0/24 via 10.0.1.1 dev enp0s9 2>/dev/null || true
        ip route add 10.0.2.0/24 via 10.0.1.1 dev enp0s9 2>/dev/null || true
      fi
    SHELL
  end
  # ──────────────────────────────────────────────
  # VM3: CA Server (air-gapped post-provision)
  # ──────────────────────────────────────────────
  config.vm.define "vm3-ca" do |ca|
    ca.vm.hostname = "vm3-ca"
    ca.vm.provider "virtualbox" do |vb|
      vb.name = "acme-vm3-ca"
      vb.memory = 2048
      vb.cpus = 1
      vb.customize ["modifyvm", :id, "--nicpromisc3", "allow-all"]
    end
    # VLAN 10 — Server (enp0s8) — internal link to VM2
    ca.vm.network "private_network", ip: "10.0.1.3",
      netmask: "255.255.255.192",
      virtualbox__intnet: "acme-vlan10"
    # Bridged adapter (enp0s9) — connects to physical LAN / Stockholm router.
    # RADIUS traffic from the router reaches VM3 directly, no dependency on VM2.
    ca.vm.network "public_network",
      ip: "10.0.1.51",
      netmask: "255.255.255.192"
    ca.vm.provision "shell", path: "provision/vm3-ca.sh"
    # Route fix: prefer bridged adapter (enp0s9) for router LAN traffic
    ca.vm.provision "shell", run: "always", inline: <<-SHELL
      if ip link show enp0s9 >/dev/null 2>&1; then
        ip route del 10.0.1.0/26 dev enp0s8 2>/dev/null || true
        ip route replace 10.0.1.0/26 dev enp0s9 src 10.0.1.51 metric 50
        ip route add 10.0.1.0/26 dev enp0s8 src 10.0.1.3 metric 200 2>/dev/null || true
      fi
    SHELL
  end

  # ──────────────────────────────────────────────
  # VM6: DMZ
  # ──────────────────────────────────────────────
  config.vm.define "vm6-dmz" do |dmz|
    dmz.vm.hostname = "vm6-dmz"
    dmz.vm.provider "virtualbox" do |vb|
      vb.name = "acme-vm6-dmz"
      vb.memory = 2048
      vb.cpus = 1
    end
    # VLAN 30 — DMZ (enp0s8)
    dmz.vm.network "private_network", ip: "10.0.1.242",
      netmask: "255.255.255.240",
      virtualbox__intnet: "acme-vlan30"
    dmz.vm.provision "shell", path: "provision/vm6-dmz.sh"
  end

  # ──────────────────────────────────────────────
  # VM5: London RADIUS Proxy
  # ──────────────────────────────────────────────
  config.vm.define "vm5-radius" do |rad|
    rad.vm.hostname = "vm5-radius"
    rad.vm.provider "virtualbox" do |vb|
      vb.name = "acme-vm5-radius"
      vb.memory = 2048
      vb.cpus = 1
      # VBox NAT defaults to 10.0.2.0/24 (gateway 10.0.2.2), which conflicts
      # with the London router br-lan (10.0.2.2). Shift NAT to a different subnet.
      vb.customize ["modifyvm", :id, "--natnet1", "10.0.100.0/24"]
      vb.customize ["modifyvm", :id, "--nicpromisc3", "allow-all"]
    end
    # London LAN (enp0s8) — internal link (VBox intnet)
    # Using .3 to avoid conflict with London router br-lan at 10.0.2.2
    rad.vm.network "private_network", ip: "10.0.2.3",
      netmask: "255.255.255.192",
      virtualbox__intnet: "london-vlan10"
    # Bridged adapter (enp0s9) — connects to London router's br-lan via LAN port 3.
    # Router br-lan is 10.0.2.2/24, so VM5 bridge must be on the same subnet.
    # bridge: is hardcoded to avoid interactive prompt during provision.
    # Change if your USB Ethernet adapter has a different name
    # (run: VBoxManage list bridgedifs | grep Name)
    rad.vm.network "public_network",
      bridge: "en6: USB 10/100/1000 LAN",
      ip: "10.0.2.50",
      netmask: "255.255.255.0"
    rad.vm.provision "shell", path: "provision/vm5-radius.sh"
    # Route fix: bridge (enp0s9, /24) and intnet (enp0s8, /26) overlap on 10.0.2.0/26.
    # Prefer bridge for router traffic, keep intnet as fallback.
    rad.vm.provision "shell", run: "always", inline: <<-SHELL
      if ip link show enp0s9 >/dev/null 2>&1; then
        # Delete any VBox NAT DHCP-injected routes
        ip route del 10.0.2.0/24 dev enp0s3 2>/dev/null || true
        ip route del 10.0.2.2 dev enp0s3 2>/dev/null || true
        # Remove intnet /26 route (more specific, would win over /24)
        ip route del 10.0.2.0/26 dev enp0s8 2>/dev/null || true
        # Set bridge as primary for 10.0.2.0/24
        ip route replace 10.0.2.0/24 dev enp0s9 src 10.0.2.50 metric 50
        # Re-add intnet as fallback
        ip route add 10.0.2.0/26 dev enp0s8 src 10.0.2.3 metric 200 2>/dev/null || true
        # Host route for router (in case /26 still intercepts)
        ip route replace 10.0.2.2 dev enp0s9 src 10.0.2.50 metric 10
      fi
    SHELL
  end
end

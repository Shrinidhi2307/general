# -*- mode: ruby -*-
# vi: set ft=ruby :
# =============================================================================
# ACME Multi-Site Network — VirtualBox VMs via Vagrant
# =============================================================================
# Creates Stockholm: VM1 (Gateway), VM2 (Server), VM3 (CA), VM6 (DMZ)
#         London:    VM4 (Gateway), VM5 (RADIUS Proxy)
#
# USAGE:
#   brew install --cask virtualbox vagrant
#   vagrant up                    # All VMs
#   vagrant up vm4-gw vm5-radius  # London only
#   vagrant ssh vm1-gw
#
# NETWORKING:
#   Each VM gets a Vagrant NAT adapter (enp0s3) for management/provisioning.
#   VLAN interfaces use VirtualBox internal networks:
#
#   Stockholm:
#     acme-vlan10  — Server VLAN (10.0.1.0/26)
#     acme-vlan20  — Client VLAN (10.0.1.128/26)
#     acme-vlan30  — DMZ VLAN   (10.0.1.240/28)
#
#   London:
#     london-vlan10 — Server VLAN (10.0.2.0/26)
#     london-vlan20 — Client VLAN (10.0.2.128/26)
#
#   WAN:
#     acme-wan    — Point-to-point link between VM1 and VM4 (10.100.0.0/30)
#
#   IPsec S2S tunnel runs over the acme-wan link.
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

  # Original internal server VLAN
 srv.vm.network "public_network",
  ip: "10.0.1.10",
  bridge: "TP-LINK Gigabit Ethernet USB Adapter"

  srv.vm.provision "shell", path: "provision/vm2-srv.sh"
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
    end
    # VLAN 10 — Server (enp0s8)
    ca.vm.network "private_network", ip: "10.0.1.3",
      netmask: "255.255.255.192",
      virtualbox__intnet: "acme-vlan10"
    ca.vm.provision "shell", path: "provision/vm3-ca.sh"
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
      # with VM5's intnet IP 10.0.2.2. Shift NAT to a different subnet.
      vb.customize ["modifyvm", :id, "--natnet1", "10.0.100.0/24"]
    end
    # London VLAN 10 — Server (enp0s8)
    rad.vm.network "private_network", ip: "10.0.2.2",
      netmask: "255.255.255.192",
      virtualbox__intnet: "london-vlan10"
    rad.vm.provision "shell", path: "provision/vm5-radius.sh"
  end
end

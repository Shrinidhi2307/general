#!/bin/bash
# =============================================================================
# VM5 (London RADIUS Proxy) — Provisioner
# Installs: freeradius (proxy mode)
# Configures: inter-VLAN routes through VM4
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM5 (London RADIUS Proxy)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    freeradius freeradius-utils

# ── Inter-VLAN route via VM4 gateway ──
# Static IP (10.0.2.2/26) is configured by Vagrant auto_config.
# Add routes to other London VLANs via VM4.
cat > /etc/netplan/99-acme-vm5-routes.yaml << 'YAML'
network:
  version: 2
  ethernets:
    enp0s8:
      routes:
        - to: 10.0.2.128/26
          via: 10.0.2.1
YAML
netplan apply 2>/dev/null || true

echo ">>> VM5 (London RADIUS Proxy) provisioned."

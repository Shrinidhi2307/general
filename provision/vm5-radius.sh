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

# ── Inter-VLAN routes via VM4 gateway ──
# Route to London Client VLAN through VM4
cat > /etc/netplan/99-acme-routes.yaml << 'YAML'
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

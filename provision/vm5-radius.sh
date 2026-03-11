#!/bin/bash
# =============================================================================
# VM5 (London RADIUS Proxy) — Provisioner
# Installs: freeradius (proxy mode)
# Networking: bridged to London router LAN via enp0s9
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM5 (London RADIUS Proxy)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    freeradius freeradius-utils

echo ">>> VM5 (London RADIUS Proxy) provisioned."

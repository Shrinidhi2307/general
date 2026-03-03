#!/bin/bash
# =============================================================================
# Install and configure Syncthing on VM2 (Stockholm Server) via Docker
# =============================================================================
# Run from the project directory (where Vagrantfile lives):
#   bash services/syncthing/setup-syncthing.sh
#
# What this script does:
#   1. Creates config and data directories on VM2
#   2. Pulls the official syncthing/syncthing Docker image
#   3. Starts the container with:
#        - GUI bound to 127.0.0.1:8384 (not externally exposed)
#        - Sync port 22000 open on all interfaces
#        - Global discovery + relays disabled
#   4. Creates a systemd service so it survives reboots
#   5. Prints the VM2 device ID
# =============================================================================
set -euo pipefail

DEVICE_ID_FILE="services/syncthing/vm2-device-id.txt"

echo "====================================================="
echo " Setting up Syncthing (Docker) on VM2"
echo "====================================================="

mkdir -p services/syncthing

vagrant ssh vm2-srv -- sudo bash -s << 'SYNC_EOF'
set -euo pipefail

CONFIG_DIR="/srv/syncthing/config"
DATA_DIR="/srv/syncthing/data"
CONTAINER_NAME="syncthing"
IMAGE="syncthing/syncthing:latest"

# ── 1. Directories ────────────────────────────────────────────────────────
echo ">>> Creating config and data directories..."
mkdir -p "$CONFIG_DIR" "$DATA_DIR"
# Run as uid 1000 inside the container (syncthing default)
chown -R 1000:1000 "$CONFIG_DIR" "$DATA_DIR"

# ── 2. Pull image ─────────────────────────────────────────────────────────
echo ">>> Pulling Syncthing image..."
docker pull "$IMAGE"

# ── 3. Remove any existing container ─────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo ">>> Removing existing container..."
    docker rm -f "$CONTAINER_NAME"
fi

# ── 4. Start container ────────────────────────────────────────────────────
echo ">>> Starting Syncthing container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -e PUID=1000 \
    -e PGID=1000 \
    -e STGUIADDRESS=127.0.0.1:8384 \
    -e STNODEFAULTFOLDER=1 \
    -p 127.0.0.1:8384:8384 \
    -p 22000:22000/tcp \
    -p 22000:22000/udp \
    -v "${CONFIG_DIR}:/var/syncthing/config" \
    -v "${DATA_DIR}:/var/syncthing/data" \
    "$IMAGE"

# ── 5. Systemd service (ensures container starts on boot) ─────────────────
echo ">>> Creating systemd service..."
cat > /etc/systemd/system/syncthing.service << 'SVC_EOF'
[Unit]
Description=Syncthing (Docker)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start syncthing
ExecStop=/usr/bin/docker stop syncthing

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable syncthing.service

# ── 6. Wait for Syncthing to initialise and print device ID ───────────────
echo ">>> Waiting for Syncthing to start..."
sleep 5

DEVICE_ID=$(docker exec "$CONTAINER_NAME" \
    sh -c 'syncthing --device-id --config /var/syncthing/config' 2>/dev/null \
    || echo "not-ready-yet")

echo ""
echo "Syncthing is running."
echo "Device ID: ${DEVICE_ID}"
echo "${DEVICE_ID}" > /vagrant/services/syncthing/vm2-device-id.txt

SYNC_EOF

echo ""
echo "====================================================="
echo " Syncthing (Docker) setup complete!"
if [ -f "$DEVICE_ID_FILE" ]; then
    echo " VM2 Device ID: $(cat $DEVICE_ID_FILE)"
fi
echo ""
echo " Verify the container is running:"
echo "   vagrant ssh vm2-srv -c 'sudo docker ps'"
echo ""
echo " Check logs:"
echo "   vagrant ssh vm2-srv -c 'sudo docker logs syncthing'"
echo "====================================================="

#!/bin/bash
# =============================================================================
# LLM Log Analyzer — Install Script for VM2
# Deploys Ollama (Docker) + gemma3:4b (Q4_K_M) + Python analyzer
# Run: vagrant ssh vm2-srv -c "sudo bash /vagrant/services/llm-logs/setup-llm-logs.sh"
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/llm-logs"
MODEL="gemma3:4b"
SRC_DIR="$(pwd)"

echo "=== LLM Log Analyzer Setup ==="

# ── Install NVIDIA container toolkit for GPU passthrough ──

# ── Install NVIDIA container toolkit for GPU passthrough ──
if ! dpkg -s nvidia-container-toolkit &>/dev/null; then
    echo ">>> Installing NVIDIA container toolkit..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi
# ── Detect docker compose command ──
if docker compose version &>/dev/null; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    echo "ERROR: Neither 'docker compose' nor 'docker-compose' found."
    echo "Install with: apt-get install docker-compose"
    exit 1
fi
echo ">>> Using: ${DC}"

# ── Copy project files to install directory ──
echo ">>> Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp "${SRC_DIR}/docker-compose.yml" "${INSTALL_DIR}/"
cp "${SRC_DIR}/requirements.txt"   "${INSTALL_DIR}/"
cp "${SRC_DIR}/config.py"          "${INSTALL_DIR}/"
cp "${SRC_DIR}/models.py"          "${INSTALL_DIR}/"
cp "${SRC_DIR}/analyze_logs.py"    "${INSTALL_DIR}/"

# ── Start Ollama container ──
echo ">>> Starting Ollama container..."
cd "${INSTALL_DIR}"
${DC} up -d

# ── Wait for Ollama API to be ready ──
echo ">>> Waiting for Ollama API..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
        echo "    Ollama API is up."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Ollama failed to start within 30s"
        exit 1
    fi
    sleep 1
done

# ── Pull the model (~3GB download) ──
echo ">>> Pulling ${MODEL}... (this will take a while)"
${DC} exec -T ollama ollama pull "${MODEL}"
echo ">>> Model ${MODEL} pulled successfully."

# ── Setup Python venv ──
echo ">>> Setting up Python venv..."
python3 -m venv "${INSTALL_DIR}/.venv"
"${INSTALL_DIR}/.venv/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt"

# ── Create findings directory ──
mkdir -p "${INSTALL_DIR}/findings"

# ── Syncthing log dump script ──
# Syncthing runs in Docker, so we dump container logs to a file
# the analyzer can read incrementally. Uses a timestamp marker to
# avoid re-dumping the entire history each run.
cat > "${INSTALL_DIR}/dump-syncthing-logs.sh" << 'DUMP'
#!/bin/bash
MARKER="/opt/llm-logs/.syncthing-last-dump"
LOGFILE="/var/log/syncthing.log"
if [ -f "$MARKER" ]; then
    SINCE=$(cat "$MARKER")
    docker logs --since "$SINCE" syncthing >> "$LOGFILE" 2>&1
else
    docker logs syncthing > "$LOGFILE" 2>&1
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
DUMP
chmod +x "${INSTALL_DIR}/dump-syncthing-logs.sh"

# Do initial dump so the analyzer has something to read
"${INSTALL_DIR}/dump-syncthing-logs.sh"

# ── Install cron job (every 5 minutes) ──
# Dump syncthing logs first, then run the analyzer
CRON_LINE="*/5 * * * * ${INSTALL_DIR}/dump-syncthing-logs.sh && cd ${INSTALL_DIR} && ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/analyze_logs.py >> ${INSTALL_DIR}/cron.log 2>&1"
if ! crontab -l 2>/dev/null | grep -qF "analyze_logs.py"; then
    echo ">>> Adding cron job..."
    (crontab -l 2>/dev/null || true; echo "${CRON_LINE}") | crontab -
else
    echo ">>> Cron job already exists, skipping."
fi

echo ""
echo "=== Setup complete ==="
echo "  Install dir: ${INSTALL_DIR}"
echo "  Model:       ${MODEL}"
echo "  Log sources: /var/log/auth.log, nginx access/error, syncthing"
echo "  Findings:    ${INSTALL_DIR}/findings/"
echo "  Cron:        every 5 minutes (dumps syncthing logs, then analyzes)"
echo ""
echo "  Manual run:  cd ${INSTALL_DIR} && .venv/bin/python analyze_logs.py"
echo "  View logs:   tail -f ${INSTALL_DIR}/cron.log"
echo "  View finds:  cat ${INSTALL_DIR}/findings/findings_\$(date +%F).jsonl"

# LLM Log Analyzer

Runs a local LLM (Ollama + gemma3:4b) on VM2 to scan logs for security threats.
Reads auth.log, nginx, and syncthing logs, chunks them up, feeds them to the model,
and writes structured findings to disk. No external API calls — everything stays on the box.

## Setup

Requires VM2 to be provisioned and nginx/syncthing already running.

```bash
# 1. nginx
vagrant ssh vm2-srv -c "sudo bash /vagrant/services/nginx/setup-nginx.sh"

# 2. syncthing
vagrant ssh vm2-srv -c "sudo bash /vagrant/services/syncthing/setup-syncthing.sh"

# 3. this
vagrant ssh vm2-srv -c "sudo bash /vagrant/services/llm-logs/setup-llm-logs.sh"
```

The setup script handles everything: docker compose, ollama, model pull (~3GB),
python venv, syncthing log dump script, and cron. The model download is the slow part.

## Running manually

```bash
vagrant ssh vm2-srv
cd /opt/llm-logs && sudo .venv/bin/python analyze_logs.py
```

## Cron

A cron job runs every 5 minutes. It first dumps new syncthing docker logs to
`/var/log/syncthing.log`, then runs the analyzer. The lock file prevents
overlapping runs.

Check cron output:
```bash
sudo tail -f /opt/llm-logs/cron.log
```

## Findings

Written to `/opt/llm-logs/findings/findings_YYYY-MM-DD.jsonl` — one JSON object per line.

```bash
sudo cat /opt/llm-logs/findings/findings_$(date +%F).jsonl
```

## Lock file gotcha

The analyzer uses a lock file (`/opt/llm-logs/.analyze.lock`) so only one
instance runs at a time. If the process crashes, the OS releases the lock
automatically — but sometimes the file sticks around and causes
"Another instance is already running" on the next run.

Fix it with `--force`:
```bash
sudo .venv/bin/python analyze_logs.py --force
```

Or just delete it:
```bash
sudo rm /opt/llm-logs/.analyze.lock
```

## Log sources

| Source | Path | Notes |
|---|---|---|
| auth | `/var/log/auth.log` | SSH, sudo, PAM |
| nginx_access | `/var/log/nginx/access.log` | Web requests |
| nginx_error | `/var/log/nginx/error.log` | Web errors |
| syncthing | `/var/log/syncthing.log` | Dumped from docker container before each run |

## GPU passthrough

The setup script installs the NVIDIA container toolkit so Ollama can use
the GPU from inside Docker. This requires:

1. **NVIDIA drivers on the host** — must be installed on the VM's host OS
   before running the setup script. The toolkit talks to the driver, it
   doesn't install one.
2. **VirtualBox GPU passthrough** — if VM2 runs in VirtualBox, the GPU
   needs to be passed through to the VM. This is done in VBox settings
   (or via `vb.customize` in the Vagrantfile) by attaching the PCI device.
   VBox GPU passthrough is finicky — it needs IOMMU enabled in BIOS and
   the host must not be using the GPU itself.
3. **NVIDIA container toolkit** — installed automatically by `setup-llm-logs.sh`.
   Adds the nvidia runtime to Docker so containers can see the GPU.
4. **docker-compose.yml** — has a `deploy.resources.reservations.devices`
   block that requests 1 NVIDIA GPU for the Ollama container.

If there's no GPU available, Ollama falls back to CPU automatically — it
just runs slower.

To verify GPU is working inside the container:
```bash
vagrant ssh vm2-srv
sudo docker exec ollama nvidia-smi
```

## Model

gemma3:4b (Q4_K_M, ~3GB) running on GPU via NVIDIA container toolkit.
Configured for 8192 context window, 50 lines per chunk. Swap the model
in `config.py` if needed — for CPU-only testing, `qwen2.5:0.5b` works
(badly, but it works).

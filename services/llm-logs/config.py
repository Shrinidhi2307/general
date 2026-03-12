from pathlib import Path

BASE_DIR = Path(__file__).parent

OLLAMA_URL = "http://localhost:11434"
MODEL = "gemma3:4b"

CHUNK_SIZE_LINES = 50
TEMPERATURE = 0.1
NUM_CTX = 8192

STATE_FILE = BASE_DIR / "state.json"
FINDINGS_DIR = BASE_DIR / "findings"
LOCK_FILE = BASE_DIR / ".analyze.lock"

LOG_SOURCES = [
    {"name": "auth", "path": "/var/log/auth.log"},
    {"name": "nginx_access", "path": "/var/log/nginx/access.log"},
    {"name": "nginx_error", "path": "/var/log/nginx/error.log"},
    {"name": "syncthing", "path": "/var/log/syncthing.log"},
    {"name": "openwrt", "path": "/var/log/openwrt.log"},
]

SYSTEM_PROMPT = """\
You are a security log analyst. Analyze the log lines and identify security threats.

Rules:
- Only report threats directly evidenced by the logs. No speculation.
- sample_lines must be exact verbatim copies from the input.
- Return empty findings list if no threats found. Do not fabricate findings.
- Ignore routine activity: service starts, cron jobs, NTP, package updates.

Threats to detect: brute force auth, privilege escalation (sudo/su/pkexec), \
web attacks (SQLi/XSS/path traversal/shell injection), unauthorized access, \
port scanning, unusual process execution.

Threat levels: LOW=single anomaly, MEDIUM=repeated pattern, \
HIGH=active exploitation or confirmed breach.\
"""

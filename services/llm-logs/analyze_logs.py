#!/usr/bin/env python3
"""Secure LLM Log Analyzer - processes system/web logs through a local LLM."""

import fcntl
import json
import os
import sys
from datetime import date
from pathlib import Path

import requests
from pydantic import ValidationError

from config import (
    CHUNK_SIZE_LINES,
    FINDINGS_DIR,
    LOCK_FILE,
    LOG_SOURCES,
    MODEL,
    NUM_CTX,
    OLLAMA_URL,
    STATE_FILE,
    SYSTEM_PROMPT,
    TEMPERATURE,
)
from models import AnalysisResponse


def flatten_schema(schema: dict) -> dict:
    """Inline $defs/$ref so Ollama's structured output can parse the schema."""
    import copy
    schema = copy.deepcopy(schema)
    defs = schema.pop("$defs", {})

    def resolve(node):
        if isinstance(node, dict):
            if "$ref" in node:
                ref_name = node["$ref"].split("/")[-1]
                return resolve(copy.deepcopy(defs[ref_name]))
            return {k: resolve(v) for k, v in node.items()}
        if isinstance(node, list):
            return [resolve(item) for item in node]
        return node

    return resolve(schema)


def acquire_lock():
    """Acquire an exclusive lock to prevent overlapping cron runs.

    Uses fcntl.flock which is automatically released by the OS when
    the process exits (even on crash/SIGKILL). Pass --force to remove
    a stale lock file before attempting to acquire.
    """
    if "--force" in sys.argv and LOCK_FILE.exists():
        LOCK_FILE.unlink()
        print("Removed stale lock file.")

    lock_fp = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Another instance is already running. Exiting.")
        print("If this is a stale lock, run with --force to clear it.")
        sys.exit(0)
    return lock_fp


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {}


def save_state(state: dict):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def get_file_inode(path: str) -> int:
    return os.stat(path).st_ino


def read_new_lines(source: dict, state: dict) -> tuple[list[str], int]:
    """Read new lines from a log file since last processed offset.

    Returns (lines, new_offset). Detects log rotation via inode change
    or file shrinkage and resets offset to 0.
    """
    name = source["name"]
    path = source["path"]

    if not Path(path).exists():
        return [], 0

    current_inode = get_file_inode(path)
    prev = state.get(name, {"offset": 0, "inode": current_inode})
    offset = prev["offset"]

    # Detect log rotation: inode changed or file is smaller than offset
    file_size = os.path.getsize(path)
    if current_inode != prev.get("inode") or file_size < offset:
        offset = 0

    with open(path, "r", errors="replace") as f:
        f.seek(offset)
        lines = f.readlines()
        new_offset = f.tell()

    return lines, new_offset


def chunk_lines(lines: list[str], size: int) -> list[list[str]]:
    """Split lines into chunks of the given size."""
    return [lines[i : i + size] for i in range(0, len(lines), size)]


MAX_LOG_CHARS = 6000  # ~1500 tokens; keeps prompt well within NUM_CTX (8192)


def analyze_chunk(log_text: str, source_name: str) -> AnalysisResponse | None:
    """Send a log chunk to Ollama and parse the structured response."""
    log_text = log_text[-MAX_LOG_CHARS:] if len(log_text) > MAX_LOG_CHARS else log_text
    try:
        resp = requests.post(
            f"{OLLAMA_URL}/api/chat",
            json={
                "model": MODEL,
                "stream": False,
                "format": flatten_schema(AnalysisResponse.model_json_schema()),
                "options": {"temperature": TEMPERATURE, "num_ctx": NUM_CTX},
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {
                        "role": "user",
                        "content": f"Log source: {source_name}\n\n{log_text}",
                    },
                ],
            },
            timeout=300,
        )
        resp.raise_for_status()
    except requests.RequestException as e:
        print(f"  Ollama request failed: {e}")
        return None

    try:
        content = resp.json()["message"]["content"]
        return AnalysisResponse.model_validate_json(content)
    except (KeyError, json.JSONDecodeError, ValidationError) as e:
        print(f"  Failed to parse LLM response: {e}")
        return None


def clear_context():
    """Unload model from memory to clear KV cache between chunks."""
    try:
        requests.post(
            f"{OLLAMA_URL}/api/chat",
            json={"model": MODEL, "keep_alive": 0},
            timeout=10,
        )
    except requests.RequestException:
        pass


def save_findings(findings: list, source_name: str):
    """Append findings to today's JSONL file."""
    FINDINGS_DIR.mkdir(exist_ok=True)
    out_path = FINDINGS_DIR / f"findings_{date.today().isoformat()}.jsonl"

    with open(out_path, "a") as f:
        for finding in findings:
            record = finding.model_dump()
            record["log_source"] = source_name
            f.write(json.dumps(record) + "\n")


def process_source(source: dict, state: dict) -> dict:
    """Process a single log source. Returns updated state entry."""
    name = source["name"]
    path = source["path"]

    if not Path(path).exists():
        print(f"[{name}] File not found: {path} — skipping")
        return state.get(name, {"offset": 0, "inode": 0})

    lines, new_offset = read_new_lines(source, state)
    current_inode = get_file_inode(path)

    if not lines:
        print(f"[{name}] No new lines")
        return {"offset": new_offset, "inode": current_inode}

    print(f"[{name}] Processing {len(lines)} new lines")
    chunks = chunk_lines(lines, CHUNK_SIZE_LINES)
    all_ok = True

    for i, chunk in enumerate(chunks, 1):
        log_text = "".join(chunk)
        print(f"  Chunk {i}/{len(chunks)} ({len(chunk)} lines)...")
        result = analyze_chunk(log_text, name)

        clear_context()

        if result is None:
            all_ok = False
            continue

        if result.findings:
            save_findings(result.findings, name)
            for f in result.findings:
                print(f"  [{f.threat_level.value.upper()}] {f.description}")
        else:
            print(f"  No threats found")

    # Only advance cursor if all chunks succeeded
    if all_ok:
        return {"offset": new_offset, "inode": current_inode}
    else:
        prev = state.get(name, {"offset": 0, "inode": current_inode})
        return {"offset": prev["offset"], "inode": current_inode}


def main():
    lock_fp = acquire_lock()
    try:
        state = load_state()

        print(f"Secure LLM Log Analyzer — {date.today().isoformat()}")
        print(f"Model: {MODEL} | Chunk size: {CHUNK_SIZE_LINES} lines\n")

        for source in LOG_SOURCES:
            state[source["name"]] = process_source(source, state)

        save_state(state)
        print("\nDone.")
    finally:
        lock_fp.close()
        LOCK_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    main()

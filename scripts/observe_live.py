#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import time

parser = argparse.ArgumentParser(description="Observe one explicitly named live session without storing conversation content.")
parser.add_argument("--session", required=True)
parser.add_argument("--source", choices=("cli", "desktop", "unknown"), default="cli")
parser.add_argument("--seconds", type=float, default=20)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--data-dir", type=Path, default=Path.home() / "Library/Application Support/Codex Signal")
args = parser.parse_args()
if not 1 <= args.seconds <= 300:
    parser.error("seconds must be between 1 and 300")
args.output.parent.mkdir(parents=True, exist_ok=True)
previous = None
with args.output.open("w") as output:
    args.output.chmod(0o600)
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        try:
            state = json.loads((args.data_dir / "runtime-status.json").read_text())
            row = next((row for row in state["sessions"] if row["id"] == args.source + ":" + args.session), None)
            record = {"phase": row.get("phase") if row else None, "pending": row.get("pending") if row else None,
                      "seen": row.get("seen") if row else None, "speechCount": state.get("speechCount")}
            if record != previous:
                output.write(json.dumps(dict(observedAt=time.time(), **record)) + "\n")
                output.flush()
                print(json.dumps(record), flush=True)
                previous = record
        except (FileNotFoundError, json.JSONDecodeError, KeyError):
            pass
        time.sleep(0.05)

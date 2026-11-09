#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import time

from signal_bridge import validate_event, write_event


def scenario_events(name):
    if name == "initial":
        return json.loads((Path(__file__).resolve().parent.parent / "fixtures" / "sessions.json").read_text())
    if name == "new-question":
        return [{"source": "cli", "sessionId": "demo-new-question", "turnId": "turn-1", "project": "新问题", "kind": "question", "requestId": "new-question-1", "offset": 0}]
    if name == "resume":
        return [{"source": "cli", "sessionId": "demo-api-cli", "turnId": "turn-1", "project": "API 服务", "kind": "resumed", "requestId": "approval-1", "offset": 0}]
    if name == "stale":
        return [
            {"source": "cli", "sessionId": "demo-api-cli", "turnId": "turn-2", "project": "API 服务", "kind": "started", "offset": 0},
            {"source": "cli", "sessionId": "demo-api-cli", "turnId": "turn-2", "project": "API 服务", "kind": "question", "requestId": "question-2", "offset": 0.01},
            {"source": "cli", "sessionId": "demo-api-cli", "turnId": "turn-1", "project": "API 服务", "kind": "completed", "offset": 0.02},
        ]
    return [{"source": "cli", "sessionId": "demo-list-" + str(index), "turnId": "turn-1", "project": "长列表项目 " + str(index + 1), "kind": "approval" if index % 3 == 0 else "started", "requestId": "request-" + str(index) if index % 3 == 0 else None, "offset": index / 100} for index in range(16)]


def main():
    parser = argparse.ArgumentParser(description="Send explicit demonstration events to an isolated Codex Signal data directory.")
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--scenario", choices=("initial", "new-question", "resume", "stale", "long-list"), default="initial")
    parser.add_argument("--interval", type=float, default=0)
    args = parser.parse_args()
    if not 0 <= args.interval <= 10:
        parser.error("--interval must be between 0 and 10 seconds")
    base = time.time()
    events = scenario_events(args.scenario)
    for index, source in enumerate(events):
        event = dict(source)
        offset = event.pop("offset", index / 100)
        event.update(schemaVersion=1, eventId="replay:" + args.scenario + ":" + str(index), occurredAt=base + offset, isChild=False)
        write_event(validate_event(event), args.data_dir.expanduser())
        if args.interval:
            time.sleep(args.interval)
    print(json.dumps({"scenario": args.scenario, "eventsWritten": len(events), "dataDirectory": str(args.data_dir), "evidence": "synthetic replay; not a live Codex session"}, ensure_ascii=False))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import stat
import sqlite3
import subprocess
import plistlib
import re
from datetime import datetime, timezone
import sys
import time
import uuid

# The bridge can run from a signed app bundle; keep imports read-only.
sys.dont_write_bytecode = True
from request_correlation import enrich_hook

MAX_INPUT = 1024 * 1024
MAX_EVENT = 64 * 1024
SOURCES = {"cli", "desktop", "unknown"}
KINDS = {"started", "approval", "question", "resumed", "completed", "failed", "stopped", "disconnected"}
FIELDS = {"schemaVersion", "eventId", "source", "sessionId", "turnId", "requestId", "project", "kind", "occurredAt", "isChild", "title", "cwd", "terminalTTY", "terminalBundleID"}
HOOKS = ("UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt")
DEFAULT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Codex Signal"


def text_field(value, name, limit=512):
    if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > limit:
        raise ValueError("invalid " + name)
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("control character in " + name)
    return value


def validate_event(raw):
    if not isinstance(raw, dict) or set(raw) - FIELDS:
        raise ValueError("invalid event fields")
    if type(raw.get("schemaVersion")) is not int or raw["schemaVersion"] != 1:
        raise ValueError("unsupported schemaVersion")
    if raw.get("source") not in SOURCES or raw.get("kind") not in KINDS:
        raise ValueError("invalid source or kind")
    event = dict(raw)
    for name in ("eventId", "sessionId", "turnId", "project"):
        event[name] = text_field(event.get(name), name, 256 if name == "project" else 512)
    request = event.setdefault("requestId", None)
    if request is not None:
        text_field(request, "requestId")
    for name, limit in (("title", 1024), ("cwd", 4096), ("terminalTTY", 128), ("terminalBundleID", 256)):
        if event.get(name) is not None:
            text_field(event[name], name, limit)
    if event.get("cwd") is not None and not event["cwd"].startswith("/"):
        raise ValueError("cwd must be absolute")
    if event.get("terminalTTY") is not None and not re.fullmatch(r"/dev/(ttys[0-9]+|tty[0-9]+|pts/[0-9]+)", event["terminalTTY"]):
        raise ValueError("invalid terminalTTY")
    if event.get("terminalBundleID") is not None and not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", event["terminalBundleID"]):
        raise ValueError("invalid terminalBundleID")
    timestamp = event.get("occurredAt")
    if type(timestamp) not in (int, float) or not math.isfinite(timestamp) or not 0 <= timestamp <= 253402300799:
        raise ValueError("invalid occurredAt")
    if type(event.setdefault("isChild", False)) is not bool:
        raise ValueError("invalid isChild")
    return event


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def process_record(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid=,comm="], capture_output=True, text=True, timeout=0.2)
    fields = result.stdout.strip().split(None, 1)
    if result.returncode or len(fields) != 2:
        return None
    arguments = fields[1]
    if Path(fields[1]).name == "codex":
        args = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True, timeout=0.2)
        if args.returncode:
            return None
        arguments = args.stdout.strip()
    return int(fields[0]), fields[1], arguments


def classify_process(executable, arguments, parent_executable, desktop_bundle_id=None):
    if Path(executable).name != "codex":
        return None
    try:
        words = shlex.split(arguments)
    except ValueError:
        return None
    if len(words) < 2 or words[1] != "app-server":
        if len(words) > 1 and words[1] in {"exec", "e", "review", "resume", "fork"}:
            return "cli"
        return None if "app-server" in words[1:] else "cli"
    parent = Path(parent_executable)
    if parent.parent.name == "MacOS" and parent.parent.parent.name == "Contents" and desktop_bundle_id == "com.openai.codex":
        return "desktop"
    return "unknown"


def detect_source():
    pid = os.getppid()
    for _ in range(12):
        record = process_record(pid)
        if record is None:
            return None
        parent_pid, executable, arguments = record
        if Path(executable).name == "codex":
            parent = process_record(parent_pid)
            parent_executable = parent[1] if parent else ""
            info = Path(parent_executable).parent.parent / "Info.plist"
            bundle_id = None
            if info.is_file():
                try:
                    with info.open("rb") as handle:
                        bundle_id = plistlib.load(handle).get("CFBundleIdentifier")
                except (OSError, ValueError, plistlib.InvalidFileException):
                    pass
            return classify_process(executable, arguments, parent_executable, bundle_id)
        if parent_pid <= 1 or parent_pid == pid:
            return None
        pid = parent_pid
    return None


def normalized_title(value):
    if not isinstance(value, str):
        return None
    title = " ".join(value.split())
    try:
        return text_field(title, "title", 1024)
    except ValueError:
        return None


def codex_title(session_id, root=None):
    """Read title metadata only. Bound input even when an account has a huge index."""
    root = Path(root) if root is not None else Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser()
    try:
        with (root / "session_index.jsonl").open("rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            offset = max(0, size - 8 * 1024 * 1024)
            handle.seek(offset)
            if offset:
                handle.readline(65537)
            data = handle.read(8 * 1024 * 1024)
        found = None
        for line in data.splitlines():
            if len(line) > 65536:
                continue
            try:
                entry = json.loads(line)
                if not isinstance(entry, dict) or entry.get("id") != session_id:
                    continue
                title = normalized_title(entry.get("thread_name"))
                if title is None:
                    continue
                try:
                    updated = datetime.fromisoformat(entry.get("updated_at", "").replace("Z", "+00:00"))
                    updated = updated.replace(tzinfo=updated.tzinfo or timezone.utc).timestamp()
                except (ValueError, TypeError, AttributeError, OverflowError):
                    updated = float("-inf")
                if found is None or updated >= found[0]:
                    found = (updated, title)
            except (ValueError, UnicodeDecodeError, RecursionError):
                continue
        return found[1] if found else None
    except (OSError, ValueError):
        return None


def codex_database_title(session_id, root=None):
    """Exact-id fallback for CLI threads absent from the rename index. Open read-only."""
    root = Path(root) if root is not None else Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser()
    try:
        candidates = [path for path in root.glob("state_*.sqlite") if re.fullmatch(r"state_[0-9]+\.sqlite", path.name)]
        candidates.sort(key=lambda path: int(path.stem.split("_")[-1]), reverse=True)
        for path in candidates[:4]:
            connection = None
            try:
                connection = sqlite3.connect(path.absolute().as_uri() + "?mode=ro", uri=True, timeout=0.05)
                connection.execute("PRAGMA query_only=ON")
                try:
                    row = connection.execute("SELECT name, title FROM threads WHERE id = ? LIMIT 1", (session_id,)).fetchone()
                except sqlite3.OperationalError:
                    # Older schemas have no explicit thread name.
                    row = connection.execute("SELECT title FROM threads WHERE id = ? LIMIT 1", (session_id,)).fetchone()
                title = next((title for value in (row or ()) if (title := normalized_title(value))), None)
                if title:
                    return title
            except (sqlite3.Error, OSError, ValueError):
                continue
            finally:
                if connection is not None:
                    connection.close()
    except OSError:
        pass
    return None


def codex_database_source(session_id, root=None):
    """Creation provenance for shared-service hooks; vscode alone is not a desktop client."""
    root = Path(root) if root is not None else Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser()
    try:
        candidates = [path for path in root.glob("state_*.sqlite") if re.fullmatch(r"state_[0-9]+\.sqlite", path.name)]
        candidates.sort(key=lambda path: int(path.stem.split("_")[-1]), reverse=True)
        for path in candidates[:4]:
            connection = None
            try:
                connection = sqlite3.connect(path.absolute().as_uri() + "?mode=ro", uri=True, timeout=0.05)
                connection.execute("PRAGMA query_only=ON")
                row = connection.execute("SELECT originator FROM threads WHERE id = ? LIMIT 1", (session_id,)).fetchone()
                if row is not None:
                    # This value is verified against this machine's standalone and daemon CLI threads.
                    # Unknown origins stay unknown; do not infer a desktop app from source=vscode.
                    return "cli" if row[0] == "codex-tui" else None
            except (sqlite3.Error, OSError, ValueError):
                continue
            finally:
                if connection is not None:
                    connection.close()
    except OSError:
        pass
    return None


def resolve_source(process_source, raw):
    if process_source in {"cli", "desktop"}:
        return process_source
    session_id = raw.get("session_id", raw.get("thread-id")) if isinstance(raw, dict) else None
    if isinstance(session_id, str):
        return codex_database_source(session_id) or "unknown"
    return "unknown"


def terminal_metadata():
    """Identify only a CLI's inherited terminal; never inspect process environment or transcript."""
    result = {}
    pid = os.getppid()
    found_codex = False
    for _ in range(12):
        record = process_record(pid)
        if record is None:
            break
        parent_pid, executable, arguments = record
        if Path(executable).name == "codex" and not found_codex:
            # A daemon's terminal/environment belongs to the service, not its client.
            if classify_process(executable, arguments, "") != "cli":
                return {}
            found_codex = True
            tty = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "tty="], capture_output=True, text=True, timeout=0.2)
            value = tty.stdout.strip()
            value = value if value.startswith("/dev/") else "/dev/" + value
            if tty.returncode == 0 and re.fullmatch(r"/dev/(ttys[0-9]+|tty[0-9]+|pts/[0-9]+)", value):
                result["terminalTTY"] = value
        path = Path(executable)
        if path.parent.name == "MacOS" and path.parent.parent.name == "Contents":
            try:
                with (path.parent.parent / "Info.plist").open("rb") as handle:
                    bundle_id = plistlib.load(handle).get("CFBundleIdentifier")
                if isinstance(bundle_id, str) and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
                    result["terminalBundleID"] = bundle_id
                    break
            except (OSError, ValueError, plistlib.InvalidFileException):
                pass
        if parent_pid <= 1 or parent_pid == pid:
            break
        pid = parent_pid
    if not found_codex:
        return {}
    if "terminalBundleID" not in result:
        bundle_id = {"Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
                     "WezTerm": "com.github.wez.wezterm", "ghostty": "com.mitchellh.ghostty",
                     "vscode": "com.microsoft.VSCode"}.get(os.environ.get("TERM_PROGRAM"))
        if bundle_id:
            result["terminalBundleID"] = bundle_id
    return result


def enrich_metadata(event, raw):
    title = next((title for key in ("session_title", "thread_title", "title")
                  if (title := normalized_title(raw.get(key))) is not None), None)
    title = title or codex_title(event["sessionId"]) or codex_database_title(event["sessionId"])
    if title:
        event["title"] = title
    if event["source"] == "cli":
        try:
            event.update(terminal_metadata())
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return validate_event(event)


def record_diagnostic(raw, event, data_dir, source, error=None):
    if not isinstance(raw, dict):
        return
    directory = data_dir / "diagnostics"
    fd = private_directory(directory)
    try:
        entries = sorted(directory.glob("*.json"), key=lambda p: p.stat().st_mtime)
        for entry in entries[:-255]:
            entry.unlink()
        report = {"receivedAt": time.time(), "hookEvent": raw.get("hook_event_name", raw.get("type")),
                  "sessionId": raw.get("session_id", raw.get("thread-id")), "turnId": raw.get("turn_id", raw.get("turn-id")),
                  "fieldNames": sorted(raw), "toolName": raw.get("tool_name"), "toolUseIdPresent": bool(raw.get("tool_use_id")),
                  "toolInputFields": sorted(raw.get("tool_input", {})) if isinstance(raw.get("tool_input"), dict) else [],
                  "source": source, "normalizedKind": event.get("kind") if event else None,
                  "requestId": event.get("requestId") if event else None,
                  "error": error}
        name = uuid.uuid4().hex + ".json"
        file_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd)
        with os.fdopen(file_fd, "w") as handle:
            json.dump(report, handle, ensure_ascii=False)
    finally:
        os.close(fd)


def normalize(raw, mode, source, now=None):
    if mode == "event":
        return validate_event(raw)
    if not isinstance(raw, dict):
        raise ValueError("input must be a JSON object")
    if source not in SOURCES:
        raise ValueError("--source is required for hook and notify")
    request = None
    if mode == "notify":
        if raw.get("type") != "agent-turn-complete":
            return None
        kind, session, turn = "completed", raw.get("thread-id"), raw.get("turn-id")
    else:
        name = raw.get("hook_event_name")
        direct = {"UserPromptSubmit": "started", "PermissionRequest": "approval", "Stop": "completed", "Interrupt": "stopped", "SessionEnd": "disconnected"}
        if name in direct:
            kind = direct[name]
        elif name == "PreToolUse" and raw.get("tool_name") == "request_user_input":
            kind = "question"
        elif name == "PostToolUse" and raw.get("tool_use_id"):
            kind = "resumed"
        else:
            return None
        session, turn = raw.get("session_id"), raw.get("turn_id")
        if kind in {"approval", "question", "resumed"}:
            tool_id = raw.get("tool_use_id")
            if tool_id:
                request = "tool:" + text_field(tool_id, "tool_use_id", 450)
            elif kind in {"approval", "question"}:
                request = "fallback:" + digest([raw.get("tool_name"), raw.get("tool_input")])
    cwd = raw.get("cwd")
    project = Path(cwd).name if isinstance(cwd, str) and cwd else "Codex"
    project = project or "Codex"
    session, turn = text_field(session, "session id"), text_field(turn, "turn id")
    event = {
        "schemaVersion": 1,
        "eventId": digest([source, session, turn, kind, request]),
        "source": source,
        "sessionId": session,
        "turnId": turn,
        "requestId": request,
        "project": project,
        "kind": kind,
        "occurredAt": time.time() if now is None else now,
        "isChild": bool(raw.get("parent_session_id")),
    }
    if isinstance(cwd, str) and cwd.startswith("/"):
        try:
            event["cwd"] = text_field(cwd, "cwd", 4096)
        except ValueError:
            pass
    return validate_event(event)


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(descriptor)
    if info.st_uid != os.getuid():
        os.close(descriptor)
        raise ValueError("event directory has another owner")
    os.fchmod(descriptor, 0o700)
    return descriptor


def write_event(event, data_dir):
    payload = json.dumps(event, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(payload) > MAX_EVENT:
        raise ValueError("event exceeds 64 KiB")
    root_fd = private_directory(data_dir)
    try:
        try:
            os.mkdir("inbox", 0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        inbox_fd = os.open("inbox", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        try:
            if os.fstat(inbox_fd).st_uid != os.getuid():
                raise ValueError("inbox has another owner")
            os.fchmod(inbox_fd, 0o700)
            if len(os.listdir(inbox_fd)) >= 4096:
                raise ValueError("inbox is full")
            token = uuid.uuid4().hex
            temporary, final = "." + token + ".tmp", token + ".json"
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=inbox_fd)
            try:
                with os.fdopen(descriptor, "wb") as output:
                    output.write(payload)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, final, src_dir_fd=inbox_fd, dst_dir_fd=inbox_fd)
            finally:
                try:
                    os.unlink(temporary, dir_fd=inbox_fd)
                except FileNotFoundError:
                    pass
        finally:
            os.close(inbox_fd)
    finally:
        os.close(root_fd)


def hooks_config(source, data_dir):
    if source not in SOURCES | {"auto"}:
        raise ValueError("--source is required for --print-hooks")
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), "--input", "hook", "--source", source, "--data-dir", str(data_dir.absolute())])
    return {"hooks": {name: [{"hooks": [{"type": "command", "command": command, "timeout": 3}]}] for name in HOOKS}}


def main():
    parser = argparse.ArgumentParser(description="Read-only Codex Signal event receiver. Never installs hooks or changes notify.")
    parser.add_argument("--input", choices=("hook", "notify", "event"), default="hook")
    parser.add_argument("--source", choices=sorted(SOURCES | {"auto"}))
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--print-hooks", action="store_true", help="print a hooks.json fragment for official trust review")
    parser.add_argument("payload", nargs="?", help="notify JSON argument; hook and event read stdin")
    args = parser.parse_args()
    raw = None
    source = args.source
    event = None
    try:
        if args.print_hooks:
            print(json.dumps(hooks_config(args.source, args.data_dir), ensure_ascii=False, indent=2))
            return 0
        if args.input == "notify":
            if args.payload is None:
                raise ValueError("notify requires one JSON argument")
            data = args.payload.encode("utf-8")
        else:
            if args.payload is not None:
                raise ValueError("hook and event require stdin")
            data = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(data) > MAX_INPUT:
            raise ValueError("input exceeds 1 MiB")
        raw = json.loads(data, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite JSON number")))
        correlation_source = source
        if source == "auto":
            try:
                process_source = detect_source()
            except (OSError, ValueError, subprocess.SubprocessError):
                process_source = None
            source = resolve_source(process_source, raw)
            # Keep in-flight Pre/Permission/Post records in their original transport partition.
            # A metadata retry or this upgrade must not split an existing request correlation.
            correlation_source = process_source or "unknown"
        enriched = enrich_hook(raw, correlation_source, args.data_dir.expanduser()) if args.input == "hook" and isinstance(raw, dict) else raw
        event = normalize(enriched, args.input, source)
        if event is not None:
            if args.input != "event":
                event = enrich_metadata(event, raw)
            write_event(event, args.data_dir.expanduser())
        if args.input != "event":
            record_diagnostic(raw, event, args.data_dir.expanduser(), source)
        return 0
    except (ValueError, OSError, TypeError, RecursionError, subprocess.SubprocessError):
        try:
            record_diagnostic(raw, None, args.data_dir.expanduser(), source, "invalid-or-unclassified")
        except (ValueError, OSError, TypeError):
            pass
        print("Codex Signal skipped an invalid input or unavailable event directory.", file=sys.stderr)
        return 0 if args.input == "hook" and not args.print_hooks else 2


if __name__ == "__main__":
    raise SystemExit(main())

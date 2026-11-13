import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat


# StopFailure and SessionEnd only arrive from Claude Code; both end the turn like Stop.
EVENTS = {"PreToolUse", "PermissionRequest", "PostToolUse", "UserPromptSubmit", "Stop", "Interrupt", "StopFailure", "SessionEnd"}


def _identifier(value, limit=512):
    return isinstance(value, str) and bool(value.strip()) and len(value.encode("utf-8")) <= limit and not any(ord(c) < 32 or ord(c) == 127 for c in value)


def _fingerprint(raw):
    if not _identifier(raw.get("tool_name")) or "tool_input" not in raw:
        return None
    tool_input = raw["tool_input"]
    if raw["tool_name"] == "Bash" and isinstance(tool_input, dict) and isinstance(tool_input.get("command"), str):
        tool_input = {"command": tool_input["command"]}
    encoded = json.dumps([raw["tool_name"], tool_input], ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if os.fstat(descriptor).st_uid != os.getuid():
            raise ValueError("correlation directory has another owner")
        os.fchmod(descriptor, 0o700)
    finally:
        os.close(descriptor)


def _connect(data_dir):
    _private_directory(data_dir)
    directory = data_dir / "correlation"
    _private_directory(directory)
    database = directory / "requests.sqlite3"
    descriptor = os.open(database, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
            raise ValueError("invalid correlation database")
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    return sqlite3.connect(database, timeout=0.1)


def _incomplete_marker(data_dir, source, session, turn):
    owner = hashlib.sha256(json.dumps([source, session], separators=(",", ":")).encode()).hexdigest()
    round_id = hashlib.sha256(turn.encode()).hexdigest()
    return Path(data_dir) / "correlation" / "incomplete" / (owner + "-" + round_id)


def _mark_incomplete(marker):
    _private_directory(marker.parent.parent.parent)
    _private_directory(marker.parent.parent)
    _private_directory(marker.parent)
    try:
        descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        return
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _auto_owner(connection, data_dir, session, turn):
    connection.execute("""CREATE TABLE IF NOT EXISTS auto_owners (
        session_id TEXT NOT NULL,
        turn_id TEXT NOT NULL,
        source TEXT NOT NULL,
        PRIMARY KEY (session_id, turn_id)
    )""")
    owner = connection.execute("SELECT source FROM auto_owners WHERE session_id = ? AND turn_id = ?", (session, turn)).fetchone()
    if owner is not None:
        return owner[0]
    legacy = connection.execute("SELECT DISTINCT source FROM calls WHERE session_id = ? AND turn_id = ?", (session, turn)).fetchall()
    source = legacy[0][0] if len(legacy) == 1 else "auto"
    if len(legacy) > 1 or any(_incomplete_marker(data_dir, old, session, turn).exists()
                              for old in ("cli", "desktop", "unknown")):
        _mark_incomplete(_incomplete_marker(data_dir, "auto", session, turn))
    connection.execute("INSERT INTO auto_owners VALUES (?, ?, ?)", (session, turn, source))
    return source


CLAUDE_WORK = {"PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "StopFailure"}


def track_claude_turn(raw, data_dir):
    """Return the turn for a Claude Code hook and whether that turn began without UserPromptSubmit.

    Claude Code names a turn only by prompt_id. Slash commands can start work without
    UserPromptSubmit, and SessionEnd carries the exit command's own prompt_id, so it
    must end the last tracked turn instead."""
    name, session, prompt = raw.get("hook_event_name"), raw.get("session_id"), raw.get("prompt_id")
    prompt = prompt if _identifier(prompt) else None
    if not _identifier(session):
        return prompt, False
    connection = None
    try:
        connection = _connect(Path(data_dir))
        with connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("CREATE TABLE IF NOT EXISTS claude_turns (session_id TEXT PRIMARY KEY, turn_id TEXT NOT NULL)")
            row = connection.execute("SELECT turn_id FROM claude_turns WHERE session_id = ?", (session,)).fetchone()
            current = row[0] if row else None
            if name == "SessionEnd":
                connection.execute("DELETE FROM claude_turns WHERE session_id = ?", (session,))
                return current or prompt, False
            if prompt is None or prompt == current or (name != "UserPromptSubmit" and name not in CLAUDE_WORK):
                return prompt, False
            connection.execute("INSERT OR REPLACE INTO claude_turns VALUES (?, ?)", (session, prompt))
            return prompt, name != "UserPromptSubmit"
    except (OSError, ValueError, sqlite3.Error):
        return prompt, False
    finally:
        if connection is not None:
            connection.close()


def enrich_hook(raw, source, data_dir):
    result = dict(raw)
    name = raw.get("hook_event_name")
    session = raw.get("session_id")
    turn = raw.get("turn_id")
    if source not in {"auto", "cli", "desktop", "unknown", "claude"} or name not in EVENTS or not _identifier(session) or not _identifier(turn):
        return result
    connection = None
    recording_pre = False
    marker = _incomplete_marker(data_dir, source, session, turn)
    automatic = source == "auto"
    try:
        fingerprint = _fingerprint(raw) if name in {"PreToolUse", "PermissionRequest", "PostToolUse"} else None
        tool_id = raw.get("tool_use_id")
        valid_tool_id = _identifier(tool_id, 450)
        if name == "PreToolUse" and (not valid_tool_id or fingerprint is None):
            return result
        if name == "PermissionRequest" and (tool_id or fingerprint is None):
            return result
        if name == "PostToolUse" and not valid_tool_id:
            return result
        recording_pre = name == "PreToolUse"
        if name == "PermissionRequest" and marker.exists():
            return result
        connection = _connect(Path(data_dir))
        with connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("""CREATE TABLE IF NOT EXISTS calls (
                source TEXT NOT NULL,
                session_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                tool_id TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                finished INTEGER NOT NULL CHECK (finished IN (0, 1)),
                PRIMARY KEY (source, session_id, turn_id, tool_id)
            )""")
            if automatic:
                source = _auto_owner(connection, data_dir, session, turn)
            identity = (source, session, turn)
            if name == "PreToolUse":
                connection.execute("INSERT OR IGNORE INTO calls VALUES (?, ?, ?, ?, ?, 0)", (*identity, tool_id, fingerprint))
            elif name == "PermissionRequest":
                matches = connection.execute("SELECT tool_id FROM calls WHERE source = ? AND session_id = ? AND turn_id = ? AND fingerprint = ? AND finished = 0 LIMIT 2", (*identity, fingerprint)).fetchall()
                owner_marker = _incomplete_marker(data_dir, source, session, turn)
                if len(matches) == 1 and not marker.exists() and not owner_marker.exists():
                    result["tool_use_id"] = matches[0][0]
            elif name == "PostToolUse":
                connection.execute("""INSERT INTO calls VALUES (?, ?, ?, ?, ?, 1)
                    ON CONFLICT(source, session_id, turn_id, tool_id) DO UPDATE SET finished = 1""", (*identity, tool_id, fingerprint or ""))
            elif name == "UserPromptSubmit":
                if automatic:
                    connection.execute("""DELETE FROM calls WHERE session_id = ? AND turn_id != ?
                        AND EXISTS (SELECT 1 FROM auto_owners WHERE auto_owners.session_id = calls.session_id
                            AND auto_owners.turn_id = calls.turn_id AND auto_owners.source = calls.source)""", (session, turn))
                    connection.execute("DELETE FROM auto_owners WHERE session_id = ? AND turn_id != ?", (session, turn))
                connection.execute("DELETE FROM calls WHERE source = ? AND session_id = ? AND turn_id != ?", identity)
            else:
                connection.execute("DELETE FROM calls WHERE source = ? AND session_id = ? AND turn_id = ?", identity)
        if name == "UserPromptSubmit" and marker.parent.is_dir():
            prefix = marker.name.split("-", 1)[0] + "-"
            for old_marker in marker.parent.glob(prefix + "*"):
                if old_marker != marker:
                    old_marker.unlink(missing_ok=True)
    except (OSError, ValueError, TypeError, sqlite3.Error, RecursionError):
        if recording_pre:
            try:
                _mark_incomplete(marker)
            except (OSError, ValueError):
                pass
        return dict(raw)
    finally:
        if connection is not None:
            connection.close()
    return result

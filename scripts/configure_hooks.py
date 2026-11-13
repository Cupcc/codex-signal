#!/usr/bin/env python3
"""Install Codex Signal's receiver and merge its user-level Codex or Claude Code hooks."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
from signal_bridge import CLAUDE_HOOKS, HOOKS, hook_group

BRIDGE_FILES = ("signal_bridge.py", "request_correlation.py")
# Claude Code keeps hooks inside settings.json alongside unrelated user settings.
AGENTS = {
    "codex": {"file": "hooks.json", "events": HOOKS, "sources": {"auto", "cli", "desktop", "unknown"}},
    "claude": {"file": "settings.json", "events": CLAUDE_HOOKS, "sources": {"claude"}},
}


def read_config(path):
    name = path.name
    if path.is_symlink():
        raise ValueError(name + " 是符号链接，请在实际配置目录中重试。")
    try:
        original = path.read_bytes()
    except FileNotFoundError:
        return None, {}
    try:
        config = json.loads(original)
    except (ValueError, UnicodeError):
        raise ValueError(name + " 格式有误，修复后可重新配置。原文件未修改。")
    if not isinstance(config, dict) or not isinstance(config.get("hooks", {}), dict):
        raise ValueError(name + " 的 hooks 必须是对象。原文件未修改。")
    for groups in config.get("hooks", {}).values():
        if not isinstance(groups, list) or any(not isinstance(group, dict) or not isinstance(group.get("hooks", []), list) for group in groups):
            raise ValueError(name + " 的事件格式有误。原文件未修改。")
    return original, config


def signal_hook_arguments(handler, sources=AGENTS["codex"]["sources"]):
    if not isinstance(handler, dict) or handler.get("type") != "command":
        return None
    command = handler.get("command")
    if not isinstance(command, str):
        return None
    try:
        args = shlex.split(command)
    except ValueError:
        return None
    # Recognize the exact receiver invocation, including configurations generated
    # by older releases. Leave wrappers and unrelated commands alone.
    if (len(args) == 8 and Path(args[1]).name == "signal_bridge.py"
            and args[2:5] == ["--input", "hook", "--source"]
            and args[5] in sources
            and args[6] == "--data-dir"):
        return args
    return None


def is_signal_hook(handler, sources=AGENTS["codex"]["sources"]):
    return signal_hook_arguments(handler, sources) is not None


def merge_hooks(config, command, force=False, agent="codex"):
    spec = AGENTS[agent]
    merged = dict(config)
    events = dict(config.get("hooks", {}))
    if force:
        for name, groups in events.items():
            kept = []
            for group in groups:
                handlers = group.get("hooks", [])
                remaining = [handler for handler in handlers if not is_signal_hook(handler, spec["sources"])]
                if remaining == handlers:
                    kept.append(group)
                elif remaining:
                    kept.append(dict(group, hooks=remaining))
            events[name] = kept
    # Drop this receiver from events a newer bridge no longer uses.
    for name, groups in list(events.items()):
        if name in spec["events"]:
            continue
        kept = []
        for group in groups:
            handlers = group.get("hooks", [])
            remaining = [handler for handler in handlers if not is_signal_hook(handler, spec["sources"])]
            if remaining == handlers:
                kept.append(group)
            elif remaining:
                kept.append(dict(group, hooks=remaining))
        if kept:
            events[name] = kept
        else:
            del events[name]
    target = shlex.split(command)
    for name in spec["events"]:
        groups = []
        found = False
        for group in events.get(name, []):
            handlers = group.get("hooks", [])
            updated = []
            for handler in handlers:
                existing = signal_hook_arguments(handler, spec["sources"])
                if existing is not None:
                    found = True
                    # The installed script's content-addressed path identifies
                    # its bridge version. Preserve healthy, current definitions.
                    current = Path(existing[1]) == Path(target[1]) and Path(existing[7]) == Path(target[7])
                    if not current or not os.access(existing[0], os.X_OK):
                        arguments = list(target)
                        arguments[5] = existing[5]
                        handler = dict(handler, command=shlex.join(arguments))
                updated.append(handler)
            groups.append(group if updated == handlers else dict(group, hooks=updated))
        if not found:
            group = hook_group(command)
            if agent == "codex":
                # Claude Code would show this on its spinner for every tool call.
                group["hooks"][0]["statusMessage"] = "Codex Signal"
            groups.append(group)
        events[name] = groups
    merged["hooks"] = events
    return merged


def atomic_write(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=".codex-signal-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install_bridge(source, data_dir, force=False):
    files = {name: (source / name).read_bytes() for name in BRIDGE_FILES}
    digest = hashlib.sha256(b"".join(files.values())).hexdigest()[:20]
    root = data_dir / "Bridge"
    directory = root / digest
    for target in (data_dir, root, directory):
        if target.is_symlink():
            raise ValueError("桥接目录是符号链接，无法安装。")
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name, data in files.items():
        target = directory / name
        if target.is_symlink():
            raise ValueError("桥接脚本是符号链接，无法安装。")
        if force or not target.exists() or target.read_bytes() != data:
            atomic_write(target, data)
    return directory / "signal_bridge.py"


def configure(codex_home, data_dir, source=None, force=False, agent="codex"):
    codex_home, data_dir = codex_home.expanduser().absolute(), data_dir.expanduser().absolute()
    spec = AGENTS[agent]
    product = "Claude Code" if agent == "claude" else "Codex"
    codex_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(codex_home / ".codex-signal.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("无法锁定 " + product + " 配置，请重试。")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = codex_home / spec["file"]
        original, config = read_config(path)
        bridge = install_bridge(source or Path(__file__).parent, data_dir, force)
        receiver = "claude" if agent == "claude" else "auto"
        command = shlex.join([sys.executable, str(bridge), "--input", "hook", "--source", receiver, "--data-dir", str(data_dir)])
        merged = merge_hooks(config, command, force, agent)
        backup = None
        changed = force or merged != config
        if changed:
            if read_config(path)[0] != original:
                raise ValueError(product + " 配置刚刚发生变化，请重试。")
            if original is not None:
                backup = codex_home / (spec["file"] + ".codex-signal-backup-" + uuid.uuid4().hex)
                with open(backup, "xb") as output:
                    os.chmod(backup, 0o600)
                    output.write(original)
            atomic_write(path, (json.dumps(merged, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        return {"changed": changed, "hooksPath": str(path), "backupPath": str(backup) if backup else None}
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", choices=sorted(AGENTS), default="codex")
    parser.add_argument("--config-home", "--codex-home", dest="config_home", type=Path, required=True,
                        help="Codex home or Claude Code configuration directory")
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--force", action="store_true", help="rebuild Codex Signal hooks and reinstall its bridge")
    args = parser.parse_args()
    try:
        print(json.dumps(configure(args.config_home, args.data_dir, force=args.force, agent=args.agent), ensure_ascii=False))
        return 0
    except (OSError, ValueError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())

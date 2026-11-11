#!/usr/bin/env python3
"""Install Codex Signal's receiver and merge its user-level hooks."""
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
from signal_bridge import HOOKS

BRIDGE_FILES = ("signal_bridge.py", "request_correlation.py")


def read_config(path):
    if path.is_symlink():
        raise ValueError("hooks.json 是符号链接，请在实际配置目录中重试。")
    try:
        original = path.read_bytes()
    except FileNotFoundError:
        return None, {}
    try:
        config = json.loads(original)
    except (ValueError, UnicodeError):
        raise ValueError("hooks.json 格式有误，修复后可重新配置。原文件未修改。")
    if not isinstance(config, dict) or not isinstance(config.get("hooks", {}), dict):
        raise ValueError("hooks.json 的 hooks 必须是对象。原文件未修改。")
    for groups in config.get("hooks", {}).values():
        if not isinstance(groups, list) or any(not isinstance(group, dict) or not isinstance(group.get("hooks", []), list) for group in groups):
            raise ValueError("hooks.json 的事件格式有误。原文件未修改。")
    return original, config


def signal_hook_arguments(handler):
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
            and args[5] in {"auto", "cli", "desktop", "unknown"}
            and args[6] == "--data-dir"):
        return args
    return None


def is_signal_hook(handler):
    return signal_hook_arguments(handler) is not None


def merge_hooks(config, command, force=False):
    merged = dict(config)
    events = dict(config.get("hooks", {}))
    if force:
        for name, groups in events.items():
            kept = []
            for group in groups:
                handlers = group.get("hooks", [])
                remaining = [handler for handler in handlers if not is_signal_hook(handler)]
                if remaining == handlers:
                    kept.append(group)
                elif remaining:
                    kept.append(dict(group, hooks=remaining))
            events[name] = kept
    target = shlex.split(command)
    for name in HOOKS:
        groups = []
        found = False
        for group in events.get(name, []):
            handlers = group.get("hooks", [])
            updated = []
            for handler in handlers:
                existing = signal_hook_arguments(handler)
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
            groups.append({"hooks": [{
                "type": "command", "command": command, "timeout": 3,
                "statusMessage": "Codex Signal",
            }]})
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


def configure(codex_home, data_dir, source=None, force=False):
    codex_home, data_dir = codex_home.expanduser().absolute(), data_dir.expanduser().absolute()
    codex_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(codex_home / ".codex-signal.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("无法锁定 Codex 配置，请重试。")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = codex_home / "hooks.json"
        original, config = read_config(path)
        bridge = install_bridge(source or Path(__file__).parent, data_dir, force)
        command = shlex.join([sys.executable, str(bridge), "--input", "hook", "--source", "auto", "--data-dir", str(data_dir)])
        merged = merge_hooks(config, command, force)
        backup = None
        changed = force or merged != config
        if changed:
            if read_config(path)[0] != original:
                raise ValueError("Codex 配置刚刚发生变化，请重试。")
            if original is not None:
                backup = codex_home / ("hooks.json.codex-signal-backup-" + uuid.uuid4().hex)
                with open(backup, "xb") as output:
                    os.chmod(backup, 0o600)
                    output.write(original)
            atomic_write(path, (json.dumps(merged, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        return {"changed": changed, "hooksPath": str(path), "backupPath": str(backup) if backup else None}
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--force", action="store_true", help="rebuild Codex Signal hooks and reinstall its bridge")
    args = parser.parse_args()
    try:
        print(json.dumps(configure(args.codex_home, args.data_dir, force=args.force), ensure_ascii=False))
        return 0
    except (OSError, ValueError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())

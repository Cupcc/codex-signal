import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from configure_hooks import BRIDGE_FILES, configure, is_signal_hook
from signal_bridge import CLAUDE_HOOKS, HOOKS, hooks_config


class ConfigureHooksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="signal-setup-")
        self.root = Path(self.temporary.name)
        self.codex = self.root / "custom-codex"
        self.codex.mkdir()
        self.data = self.root / "data with space ' $(touch SHOULD_NOT_RUN)"
        self.path = self.codex / "hooks.json"
        self.config = self.codex / "config.toml"
        self.config.write_text('notify = ["existing-receiver", "keep"]\n')
        self.trust = self.codex / "hook-trust.json"
        self.trust.write_text('{"existing":"unchanged"}')

    def tearDown(self):
        self.temporary.cleanup()

    def read(self):
        return json.loads(self.path.read_text())

    def signal_handlers(self):
        return [handler for groups in self.read()["hooks"].values() for group in groups
                for handler in group.get("hooks", []) if is_signal_hook(handler)]

    def test_fresh_install_runs_receiver_from_quoted_stable_path(self):
        result = configure(self.codex, self.data)
        self.assertTrue(result["changed"])
        self.assertIsNone(result["backupPath"])
        self.assertEqual(set(self.read()["hooks"]), set(HOOKS))
        command = self.signal_handlers()[0]["command"].replace("--source auto", "--source cli")
        payload = {"hook_event_name": "Stop", "session_id": "setup-session", "turn_id": "turn-1", "cwd": "/example/Atlas"}
        run = subprocess.run(command, shell=True, input=json.dumps(payload), text=True, capture_output=True,
                             cwd=self.root, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        event = json.loads(next((self.data / "inbox").glob("*.json")).read_text())
        self.assertEqual((event["sessionId"], event["kind"]), ("setup-session", "completed"))
        self.assertFalse((self.root / "SHOULD_NOT_RUN").exists())
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.read_text(), 'notify = ["existing-receiver", "keep"]\n')
        self.assertEqual(self.trust.read_text(), '{"existing":"unchanged"}')

    def test_existing_hooks_are_preserved_with_exact_backup(self):
        existing = {"other": {"keep": True}, "hooks": {"Stop": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "existing-hook"}]}],
                                                      "SessionStart": [{"hooks": [{"type": "mcp", "server": "existing"}]}]}}
        original = json.dumps(existing).encode()
        self.path.write_bytes(original)
        result = configure(self.codex, self.data)
        self.assertEqual(Path(result["backupPath"]).read_bytes(), original)
        self.assertEqual(Path(result["backupPath"]).stat().st_mode & 0o777, 0o600)
        merged = self.read()
        self.assertEqual(merged["other"], existing["other"])
        self.assertEqual(merged["hooks"]["Stop"][0], existing["hooks"]["Stop"][0])
        self.assertEqual(merged["hooks"]["SessionStart"], existing["hooks"]["SessionStart"])

    def test_repeated_and_concurrent_install_does_not_duplicate_or_rewrite(self):
        configure(self.codex, self.data)
        original = self.path.read_bytes(), self.path.stat().st_mtime_ns
        self.assertFalse(configure(self.codex, self.data)["changed"])

        def retry(_):
            try:
                return configure(self.codex, self.data)["changed"]
            except BlockingIOError:
                return False

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            self.assertFalse(any(pool.map(retry, range(8))))
        self.assertEqual((self.path.read_bytes(), self.path.stat().st_mtime_ns), original)
        self.assertEqual(len(self.signal_handlers()), len(HOOKS))
        self.assertFalse(list(self.codex.glob("*backup*")))

    def test_same_bridge_version_preserves_custom_hooks_and_all_file_timestamps(self):
        configure(self.codex, self.data)
        config = self.read()
        handler = config["hooks"]["Stop"][0]["hooks"][0]
        handler["timeout"] = 12
        handler["statusMessage"] = "我的提醒"
        handler["command"] = handler["command"].replace("--source auto", "--source cli")
        config["hooks"]["Stop"][0]["matcher"] = "keep-matcher"
        config["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": "other-receiver"})
        self.path.write_text(json.dumps(config, ensure_ascii=False, separators=(",", ":")))
        files = [self.path] + list((self.data / "Bridge").glob("*/*.py"))
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in files}

        result = configure(self.codex, self.data)

        self.assertFalse(result["changed"])
        self.assertIsNone(result["backupPath"])
        self.assertEqual({path: (path.read_bytes(), path.stat().st_mtime_ns) for path in files}, before)
        self.assertFalse(list(self.codex.glob("*backup*")))

    def test_same_version_preserves_working_python_and_repairs_missing_python(self):
        configure(self.codex, self.data)
        config = self.read()
        python = self.root / "existing-python3"
        python.symlink_to(sys.executable)
        handler = config["hooks"]["Stop"][0]["hooks"][0]
        arguments = shlex.split(handler["command"])
        arguments[0] = str(python)
        handler["command"] = shlex.join(arguments)
        self.path.write_text(json.dumps(config))
        original = self.path.read_bytes(), self.path.stat().st_mtime_ns

        self.assertFalse(configure(self.codex, self.data)["changed"])
        self.assertEqual((self.path.read_bytes(), self.path.stat().st_mtime_ns), original)

        python.unlink()
        self.assertTrue(configure(self.codex, self.data)["changed"])
        restored = self.read()
        self.assertEqual(shlex.split(restored["hooks"]["Stop"][0]["hooks"][0]["command"])[0], sys.executable)
        self.assertEqual(len(self.signal_handlers()), len(HOOKS))

    def test_missing_event_adds_only_missing_hook(self):
        configure(self.codex, self.data)
        config = self.read()
        del config["hooks"]["Interrupt"]
        config["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 12
        config["hooks"]["Stop"].insert(0, {"hooks": [{"type": "command", "command": "other-receiver"}]})
        original = json.dumps(config).encode()
        self.path.write_bytes(original)

        result = configure(self.codex, self.data)

        self.assertTrue(result["changed"])
        self.assertEqual(Path(result["backupPath"]).read_bytes(), original)
        installed = self.read()["hooks"]
        for name, groups in config["hooks"].items():
            self.assertEqual(installed[name], groups)
        self.assertEqual(len(installed["Interrupt"]), 1)
        self.assertEqual(len(self.signal_handlers()), len(HOOKS))

    def test_force_rebuilds_same_version_hooks_and_bridge(self):
        configure(self.codex, self.data)
        config = self.read()
        receiver = config["hooks"]["Stop"][0]["hooks"][0]
        bridge = Path(shlex.split(receiver["command"])[1])
        receiver.update(timeout=12, statusMessage="custom", command=receiver["command"].replace("--source auto", "--source cli"))
        neighbor = {"type": "command", "command": "keep-me"}
        config["hooks"]["Stop"][0].update(matcher="custom", hooks=[neighbor, receiver, dict(receiver)])
        original = json.dumps(config).encode()
        self.path.write_bytes(original)
        for path in (self.path, bridge, bridge.with_name("request_correlation.py")):
            os.utime(path, (1, 1))

        result = configure(self.codex, self.data, force=True)

        self.assertTrue(result["changed"])
        self.assertEqual(Path(result["backupPath"]).read_bytes(), original)
        self.assertEqual(self.read()["hooks"]["Stop"][0], {"matcher": "custom", "hooks": [neighbor]})
        self.assertEqual(len(self.signal_handlers()), len(HOOKS))
        for handler in self.signal_handlers():
            self.assertEqual(handler["timeout"], 3)
            self.assertEqual(handler["statusMessage"], "Codex Signal")
            self.assertIn("--source auto", handler["command"])
        for path in (self.path, bridge, bridge.with_name("request_correlation.py")):
            self.assertGreater(path.stat().st_mtime, 1)
        self.assertEqual(self.config.read_text(), 'notify = ["existing-receiver", "keep"]\n')
        self.assertEqual(self.trust.read_text(), '{"existing":"unchanged"}')

    def test_force_rewrites_even_when_default_configuration_is_identical(self):
        configure(self.codex, self.data)
        original = self.path.read_bytes()
        os.utime(self.path, (1, 1))
        result = configure(self.codex, self.data, force=True)
        self.assertTrue(result["changed"])
        self.assertEqual(self.path.read_bytes(), original)
        self.assertGreater(self.path.stat().st_mtime, 1)
        self.assertEqual(Path(result["backupPath"]).read_bytes(), original)

    def test_bridge_upgrade_changes_only_outdated_commands_in_place(self):
        source = self.root / "app-resources"
        source.mkdir()
        for name in BRIDGE_FILES:
            shutil.copy(Path(__file__).parent / name, source / name)
        configure(self.codex, self.data, source)
        old_command = self.signal_handlers()[0]["command"]
        with open(source / "request_correlation.py", "a") as output:
            output.write("\n# new bridge version\n")
        configure(self.codex, self.data, source)
        config = self.read()
        new_command = self.signal_handlers()[0]["command"]
        self.assertNotEqual(old_command, new_command)
        group = config["hooks"]["Stop"][0]
        group["matcher"] = "keep-matcher"
        group["hooks"][0].update(command=old_command.replace("--source auto", "--source cli"), timeout=12, statusMessage="我的提醒")
        group["hooks"].insert(0, {"type": "command", "command": "other-receiver"})
        self.path.write_text(json.dumps(config))
        expected = json.loads(json.dumps(config))
        expected["hooks"]["Stop"][0]["hooks"][1]["command"] = new_command.replace("--source auto", "--source cli")

        result = configure(self.codex, self.data, source)

        self.assertTrue(result["changed"])
        self.assertEqual(self.read(), expected)
        self.assertFalse(configure(self.codex, self.data, source)["changed"])

    def test_migrates_legacy_receiver_without_removing_neighbor(self):
        legacy = hooks_config("cli", self.root / "old-data")
        neighbor = {"type": "command", "command": "other-tool signal_bridge.py"}
        legacy["hooks"]["Stop"][0]["hooks"].append(neighbor)
        legacy["hooks"]["Stop"][0]["matcher"] = "keep-matcher"
        self.path.write_text(json.dumps(legacy))
        configure(self.codex, self.data)
        self.assertEqual(len(self.signal_handlers()), len(HOOKS))
        self.assertEqual(self.read()["hooks"]["Stop"][0]["matcher"], "keep-matcher")
        self.assertEqual(self.read()["hooks"]["Stop"][0]["hooks"][1], neighbor)
        self.assertEqual(len(self.read()["hooks"]["Stop"]), 1)
        self.assertTrue(all(str(self.data) in shlex.split(h["command"]) for h in self.signal_handlers()))

    def test_app_move_or_release_without_bridge_changes_does_not_rewrite_hooks(self):
        source = self.root / "app-resources"
        source.mkdir()
        for name in BRIDGE_FILES:
            shutil.copy(Path(__file__).parent / name, source / name)
        (source / "VERSION").write_text("0.5.0")
        configure(self.codex, self.data, source)
        original_command = self.signal_handlers()[0]["command"]
        original_file = self.path.read_bytes(), self.path.stat().st_mtime_ns
        moved = self.root / "moved-app"
        source.rename(moved)
        (moved / "VERSION").write_text("0.6.0")
        self.assertFalse(configure(self.codex, self.data, moved)["changed"])
        self.assertEqual(self.signal_handlers()[0]["command"], original_command)
        self.assertEqual((self.path.read_bytes(), self.path.stat().st_mtime_ns), original_file)
        self.assertFalse(list(self.codex.glob("*backup*")))
        with open(moved / "signal_bridge.py", "a") as output:
            output.write("\n# changed version\n")
        self.assertTrue(configure(self.codex, self.data, moved)["changed"])
        self.assertNotEqual(self.signal_handlers()[0]["command"], original_command)
        self.assertEqual(len(self.signal_handlers()), len(HOOKS))

    def test_malformed_config_is_left_intact(self):
        for content in [b"{", b"[]", b'{"hooks":[]}', b'{"hooks":{"Stop":{}}}', b'{"hooks":{"Stop":[{"hooks":{}}]}}']:
            self.path.write_bytes(content)
            with self.assertRaises(ValueError):
                configure(self.codex, self.data)
            self.assertEqual(self.path.read_bytes(), content)
        self.assertFalse(self.data.exists())

    def test_symlink_and_external_edit_are_not_overwritten(self):
        target = self.root / "shared-hooks.json"
        target.write_text("{}")
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            configure(self.codex, self.data)
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(target.read_text(), "{}")
        self.path.unlink()

        from configure_hooks import install_bridge

        def edit(*args):
            self.path.write_text('{"other":"new-edit"}')
            return install_bridge(*args)

        with patch("configure_hooks.install_bridge", side_effect=edit):
            with self.assertRaisesRegex(ValueError, "发生变化"):
                configure(self.codex, self.data)
        self.assertEqual(self.path.read_text(), '{"other":"new-edit"}')

    def test_cli_installs_to_explicit_home_without_touching_default(self):
        env = dict(os.environ, HOME=str(self.root / "empty-home"))
        run = subprocess.run([sys.executable, str(Path(__file__).parent / "configure_hooks.py"), "--codex-home", str(self.codex),
                              "--data-dir", str(self.data)], env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)["hooksPath"], str(self.path))
        self.assertFalse((self.root / "empty-home/.codex").exists())



class ConfigureClaudeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="signal-claude-setup-")
        self.root = Path(self.temporary.name)
        self.claude = self.root / "claude home"
        self.claude.mkdir()
        self.data = self.root / "data"
        self.path = self.claude / "settings.json"
        self.existing = {"model": "opus", "env": {"KEEP": "1"}, "permissions": {"allow": ["Bash(ls)"]},
                         "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"},
                         "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "existing-guard"}]}]}}
        self.original = json.dumps(self.existing, indent=4).encode()
        self.path.write_bytes(self.original)

    def tearDown(self):
        self.temporary.cleanup()

    def read(self):
        return json.loads(self.path.read_text())

    def handlers(self, sources=frozenset({"claude"})):
        return {name: [handler for group in groups for handler in group["hooks"] if is_signal_hook(handler, sources)]
                for name, groups in self.read()["hooks"].items()}

    def test_merges_into_settings_and_keeps_other_settings(self):
        result = configure(self.claude, self.data, agent="claude")
        self.assertEqual(result["hooksPath"], str(self.path))
        self.assertEqual(Path(result["backupPath"]).read_bytes(), self.original)
        merged = self.read()
        for key in ("model", "env", "permissions", "statusLine"):
            self.assertEqual(merged[key], self.existing[key])
        self.assertEqual(merged["hooks"]["PreToolUse"][0], self.existing["hooks"]["PreToolUse"][0])
        ours = {name: handlers for name, handlers in self.handlers().items() if handlers}
        self.assertEqual(set(ours), set(CLAUDE_HOOKS))
        self.assertTrue(all(len(handlers) == 1 and "statusMessage" not in handlers[0] for handlers in ours.values()))
        self.assertNotIn("Notification", merged["hooks"])
        self.assertFalse((self.claude / "hooks.json").exists())
        self.assertFalse(configure(self.claude, self.data, agent="claude")["changed"])

    def test_installed_command_records_claude_turn(self):
        configure(self.claude, self.data, agent="claude")
        command = self.handlers()["Stop"][0]["command"]
        payload = {"hook_event_name": "Stop", "session_id": "claude-session", "prompt_id": "prompt-1", "cwd": "/example/Atlas"}
        run = subprocess.run(command, shell=True, input=json.dumps(payload), text=True, capture_output=True, cwd=self.root, timeout=10)
        self.assertEqual((run.returncode, run.stdout), (0, ""), run.stderr)
        events = [json.loads(path.read_text()) for path in (self.data / "inbox").glob("*.json")]
        self.assertEqual({(event["source"], event["sessionId"], event["turnId"], event["kind"]) for event in events},
                         {("claude", "claude-session", "prompt-1", "started"), ("claude", "claude-session", "prompt-1", "completed")})

    def test_upgrade_removes_receiver_from_events_no_longer_used(self):
        # 0.7.0 registered Notification with an idle_prompt matcher.
        configure(self.claude, self.data, agent="claude")
        settings = self.read()
        command = self.handlers()["Stop"][0]["command"]
        neighbor = {"type": "command", "command": "notify-send-like"}
        settings["hooks"]["Notification"] = [{"matcher": "idle_prompt", "hooks": [{"type": "command", "command": command, "timeout": 3}]},
                                             {"hooks": [neighbor, {"type": "command", "command": command, "timeout": 3}]}]
        self.path.write_text(json.dumps(settings))
        self.assertTrue(configure(self.claude, self.data, agent="claude")["changed"])
        self.assertEqual(self.read()["hooks"]["Notification"], [{"hooks": [neighbor]}])
        self.assertFalse(configure(self.claude, self.data, agent="claude")["changed"])

    def test_codex_and_claude_receivers_stay_separate(self):
        codex = self.root / "codex"
        configure(codex, self.data)
        configure(self.claude, self.data, agent="claude")
        codex_before = (codex / "hooks.json").read_bytes()
        self.assertTrue(configure(self.claude, self.data, force=True, agent="claude")["changed"])
        self.assertEqual((codex / "hooks.json").read_bytes(), codex_before)
        self.assertFalse(any(self.handlers(frozenset({"auto", "cli", "desktop", "unknown"})).values()))
        codex_handlers = [h for groups in json.loads(codex_before)["hooks"].values() for g in groups for h in g["hooks"]]
        self.assertFalse(any(is_signal_hook(h, {"claude"}) for h in codex_handlers))
        self.assertEqual(sum(map(len, self.handlers().values())), len(CLAUDE_HOOKS))

    def test_cli_agent_option_targets_settings(self):
        env = dict(os.environ, HOME=str(self.root / "empty-home"))
        run = subprocess.run([sys.executable, str(Path(__file__).parent / "configure_hooks.py"), "--agent", "claude",
                              "--config-home", str(self.claude), "--data-dir", str(self.data)], env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)["hooksPath"], str(self.path))
        self.assertFalse((self.root / "empty-home/.claude").exists())

    def test_symlinked_settings_are_left_alone(self):
        target = self.root / "dotfiles-settings.json"
        target.write_bytes(self.original)
        self.path.unlink()
        self.path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "settings.json 是符号链接"):
            configure(self.claude, self.data, agent="claude")
        self.assertEqual(target.read_bytes(), self.original)

if __name__ == "__main__":
    unittest.main()

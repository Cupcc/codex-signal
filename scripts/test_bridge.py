#!/usr/bin/env python3
from concurrent.futures import ThreadPoolExecutor
import json
import io
import os
from pathlib import Path
import stat
import sqlite3
import subprocess
from unittest.mock import patch
import sys
import tempfile
import unittest

BRIDGE = Path(__file__).with_name("signal_bridge.py")


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="signal-bridge-test-")
        self.root = Path(self.temporary.name)
        self.data = self.root / "data"
        self.fake_home = self.root / "home"
        (self.fake_home / ".codex").mkdir(parents=True)
        self.config = self.fake_home / ".codex" / "config.toml"
        self.config.write_text('notify = ["existing-receiver", "keep-this"]\n')
        self.hooks = self.fake_home / ".codex" / "hooks.json"
        self.hooks.write_text('{"hooks":{"Stop":[{"existing":true}]}}')
        self.environment = dict(os.environ, HOME=str(self.fake_home), CODEX_HOME=str(self.fake_home / ".codex"))

    def tearDown(self):
        self.temporary.cleanup()

    def run_bridge(self, payload, mode="hook", source="cli", data=None):
        command = [sys.executable, str(BRIDGE), "--input", mode, "--data-dir", str(data or self.data)]
        if source is not None:
            command.extend(["--source", source])
        encoded = payload if isinstance(payload, str) else json.dumps(payload)
        if mode == "notify":
            command.append(encoded)
            encoded = None
        return subprocess.run(command, input=encoded, text=True, capture_output=True, env=self.environment, timeout=10)

    def events(self):
        return [json.loads(path.read_text()) for path in (self.data / "inbox").glob("*.json")]

    def hook(self, name="PermissionRequest", **extra):
        return dict(hook_event_name=name, session_id="s-a", turn_id="t-a", cwd="/private/example/API 服务", **extra)

    def test_hook_stdin_is_private_and_never_returns_a_decision(self):
        result = self.run_bridge(self.hook(tool_name="shell", tool_input={"command": "SECRET_COMMAND"}, prompt="SECRET_PROMPT", last_assistant_message="SECRET_REPLY"))
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        event = self.events()[0]
        self.assertEqual((event["project"], event["kind"], event["source"]), ("API 服务", "approval", "cli"))
        self.assertEqual(event["cwd"], "/private/example/API 服务")
        self.assertTrue(event["requestId"].startswith("fallback:"))
        serialized = json.dumps(event)
        for secret in ("SECRET_COMMAND", "SECRET_PROMPT", "SECRET_REPLY"):
            self.assertNotIn(secret, serialized)
        self.assertEqual(stat.S_IMODE(self.data.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.data / "inbox").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(next((self.data / "inbox").glob("*.json")).stat().st_mode), 0o600)

    def test_title_uses_exact_session_index_metadata_and_latest_timestamp(self):
        index = self.fake_home / ".codex" / "session_index.jsonl"
        entries = [{"id": "s-a", "thread_name": "初始标题", "updated_at": "2026-01-01T00:00:00Z"},
                   {"id": "s-other", "thread_name": "其他会话", "updated_at": "2026-01-04T00:00:00Z"},
                   {"id": "s-a", "thread_name": "  修复\n API  登录  ", "updated_at": "2026-01-03T00:00:00.123Z"},
                   {"id": "s-a", "thread_name": "旧记录", "updated_at": "2026-01-02T00:00:00Z"}]
        index.write_text("\n".join(json.dumps(entry) for entry in entries) + "\n{broken")
        self.run_bridge(self.hook("Stop"), source="unknown")
        event = self.events()[0]
        self.assertEqual(event["title"], "修复 API 登录")
        self.assertNotIn("terminalTTY", event)
        self.assertNotIn("terminalBundleID", event)

    def test_database_title_fallback_is_exact_and_read_only(self):
        database = self.fake_home / ".codex" / "state_5.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, first_user_message TEXT)")
            connection.executemany("INSERT INTO threads VALUES (?, ?, ?)", [("s-a", "数据库标题", "PRIVATE_PROMPT"), ("other", "其他标题", "OTHER_PROMPT")])
        before = database.read_bytes()
        self.run_bridge(self.hook("Stop"), source="unknown")
        self.assertEqual(self.events()[0]["title"], "数据库标题")
        self.assertNotIn("PRIVATE_PROMPT", json.dumps(self.events()))
        self.assertEqual(database.read_bytes(), before)
        self.run_bridge(dict(self.hook("Stop"), session_id="missing"), source="unknown")
        missing = next(event for event in self.events() if event["sessionId"] == "missing")
        self.assertNotIn("title", missing)

    def test_explicit_title_does_not_fall_back_to_prompt(self):
        self.run_bridge(self.hook("Stop", session_title="  会话标题  ", prompt="PRIVATE"), source="desktop")
        self.assertEqual(self.events()[0]["title"], "会话标题")
        self.run_bridge(dict(self.hook("Stop", prompt="PRIVATE"), session_id="another"), source="desktop")
        event = next(event for event in self.events() if event["sessionId"] == "another")
        self.assertNotIn("title", event)

    def test_database_fallback_prefers_thread_name_over_initial_title(self):
        database = self.fake_home / ".codex" / "state_5.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)")
            connection.execute("INSERT INTO threads VALUES ('s-a', ' 自动生成的会话名 ', '最初的标题')")
        self.run_bridge(self.hook("Stop"), source="unknown")
        self.assertEqual(self.events()[0]["title"], "自动生成的会话名")

    def test_terminal_metadata_matches_actual_codex_tty(self):
        from signal_bridge import terminal_metadata
        records = [(42, "/usr/local/bin/codex", "codex"), (1, "/bin/zsh", "zsh")]
        result = subprocess.CompletedProcess([], 0, stdout="ttys012\n", stderr="")
        with patch("signal_bridge.process_record", side_effect=records), patch("signal_bridge.subprocess.run", return_value=result), patch.dict(os.environ, {"TERM_PROGRAM": "Apple_Terminal"}):
            self.assertEqual(terminal_metadata(), {"terminalTTY": "/dev/ttys012", "terminalBundleID": "com.apple.Terminal"})

    def test_ghostty_hook_captures_codex_tty_not_title(self):
        from signal_bridge import terminal_metadata
        records = [(42, "/usr/local/bin/codex", "codex"), (1, "/bin/zsh", "zsh")]
        result = subprocess.CompletedProcess([], 0, stdout="ttys013\n", stderr="")
        with patch("signal_bridge.process_record", side_effect=records), patch("signal_bridge.subprocess.run", return_value=result), patch.dict(os.environ, {"TERM_PROGRAM": "ghostty"}):
            self.assertEqual(terminal_metadata(), {"terminalTTY": "/dev/ttys013", "terminalBundleID": "com.mitchellh.ghostty"})

    def test_optional_metadata_rejects_unsafe_values(self):
        from signal_bridge import validate_event
        event = {"schemaVersion": 1, "eventId": "e-a", "source": "cli", "sessionId": "s-a", "turnId": "t-a", "project": "Example", "kind": "failed", "occurredAt": 1794200000.0}
        for key, value in [("cwd", "relative/path"), ("terminalTTY", "/dev/ttys0\ncommand"), ("terminalTTY", "/dev/../tmp/x"), ("terminalBundleID", "x;open"), ("title", "bad\x00title")]:
            with self.assertRaises(ValueError):
                validate_event(dict(event, **{key: value}))

    def test_source_classification_uses_nearest_codex_and_desktop_parent(self):
        from signal_bridge import classify_process
        self.assertEqual(classify_process("/usr/local/bin/codex", "codex exec hello", "/bin/zsh"), "cli")
        self.assertEqual(classify_process("/a/codex", "codex exec explain app-server", "/bin/zsh"), "cli")
        self.assertEqual(classify_process("/Applications/Codex.app/Contents/Resources/codex", "codex", "/bin/zsh"), "cli")
        self.assertEqual(classify_process("/a/codex", "codex app-server", "/Applications/Codex.app/Contents/MacOS/Codex", "com.openai.codex"), "desktop")
        self.assertEqual(classify_process("/a/codex", "codex app-server", "/bin/zsh"), "unknown")
        self.assertIsNone(classify_process("/a/python3", "python3 script.py", "/bin/zsh"))

    def test_shared_service_uses_exact_cli_originator_not_generic_source(self):
        from signal_bridge import codex_database_source, resolve_source
        root = self.fake_home / ".codex"
        database = root / "state_5.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, source TEXT, originator TEXT)")
            connection.executemany("INSERT INTO threads VALUES (?, ?, ?)", [
                ("s-a", "vscode", "codex-tui"), ("other", "vscode", "unrecognized-client"),
                ("empty", "vscode", None)])
        before = database.read_bytes()
        with patch.dict(os.environ, self.environment):
            self.assertEqual(resolve_source("unknown", self.hook()), "cli")
            self.assertEqual(resolve_source(None, self.hook()), "cli")
            self.assertEqual(resolve_source("desktop", self.hook()), "desktop")
            self.assertEqual(resolve_source("cli", self.hook()), "cli")
            for session in ["other", "empty", "missing", "s-a' OR 1=1 --"]:
                self.assertIsNone(codex_database_source(session))
                self.assertEqual(resolve_source("unknown", dict(self.hook(), session_id=session)), "unknown")
        self.assertEqual(database.read_bytes(), before)

    def test_auto_hook_records_cli_and_keeps_inflight_shared_request_correlation(self):
        import signal_bridge
        from request_correlation import enrich_hook
        database = self.fake_home / ".codex" / "state_5.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, originator TEXT)")
            connection.execute("INSERT INTO threads VALUES ('s-a', 'codex-tui')")
        tool = {"tool_name": "Bash", "tool_input": {"command": "true"}}
        enrich_hook(self.hook("PreToolUse", tool_use_id="call-before-upgrade", **tool), "unknown", self.data)
        raw = self.hook("PermissionRequest", **tool)
        argv = [str(BRIDGE), "--source", "auto", "--data-dir", str(self.data)]
        with patch.dict(os.environ, self.environment), patch.object(sys, "argv", argv), \
             patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(json.dumps(raw).encode()))), \
             patch("signal_bridge.detect_source", return_value="unknown"), \
             patch("signal_bridge.terminal_metadata", return_value={}):
            self.assertEqual(signal_bridge.main(), 0)
        event = self.events()[0]
        self.assertEqual(event["source"], "cli")
        self.assertEqual(event["requestId"], "tool:call-before-upgrade")
        self.assertNotIn("terminalTTY", event)

    def test_auto_request_identity_survives_process_detection_failure(self):
        import signal_bridge
        for initial, later in [(None, "cli"), ("cli", None), (None, "desktop"), ("desktop", None)]:
            with self.subTest(initial=initial, later=later):
                data = self.root / (str(initial) + "-" + str(later))
                tool = dict(tool_name="Bash", tool_input={"command": "true"})
                for name, detected, extra in [
                    ("PreToolUse", initial, {"tool_use_id": "call-auto"}),
                    ("PermissionRequest", later, {}),
                    ("PostToolUse", later, {"tool_use_id": "call-auto"}),
                ]:
                    raw = self.hook(name, **tool, **extra)
                    with patch.dict(os.environ, self.environment), \
                         patch.object(sys, "argv", [str(BRIDGE), "--source", "auto", "--data-dir", str(data)]), \
                         patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(json.dumps(raw).encode()))), \
                         patch("signal_bridge.detect_source", return_value=detected), \
                         patch("signal_bridge.codex_database_source", return_value="cli"), \
                         patch("signal_bridge.enrich_metadata", side_effect=lambda event, _: event):
                        self.assertEqual(signal_bridge.main(), 0)
                events = sorted((json.loads(path.read_text()) for path in (data / "inbox").glob("*.json")),
                                key=lambda event: event["occurredAt"])
                self.assertEqual([event["kind"] for event in events], ["approval", "resumed"])
                self.assertEqual([event["requestId"] for event in events], ["tool:call-auto"] * 2)

    def test_missing_old_locked_or_newer_unknown_database_does_not_guess(self):
        from signal_bridge import codex_database_source
        root = self.fake_home / ".codex"
        self.assertIsNone(codex_database_source("s-a", root))
        older = root / "state_5.sqlite"
        with sqlite3.connect(older) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
        self.assertIsNone(codex_database_source("s-a", root))
        with sqlite3.connect(older) as connection:
            connection.execute("ALTER TABLE threads ADD COLUMN originator TEXT")
            connection.execute("INSERT INTO threads VALUES ('s-a', 'ignored', 'codex-tui')")
        newer = root / "state_10.sqlite"
        with sqlite3.connect(newer) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, originator TEXT)")
            connection.execute("INSERT INTO threads VALUES ('s-a', 'unrecognized-client')")
        self.assertIsNone(codex_database_source("s-a", root))
        # Lock failures remain non-fatal (with no readable fallback).
        older.unlink()
        connection = sqlite3.connect(newer)
        try:
            connection.execute("BEGIN EXCLUSIVE")
            self.assertIsNone(codex_database_source("s-a", root))
        finally:
            connection.close()

    def test_shared_daemon_never_supplies_client_terminal_metadata(self):
        from signal_bridge import terminal_metadata
        record = (1, "/Applications/ChatGPT.app/Contents/Resources/codex", "codex app-server")
        with patch("signal_bridge.process_record", return_value=record), \
             patch.dict(os.environ, {"TERM_PROGRAM": "ghostty"}), patch("signal_bridge.subprocess.run") as process:
            self.assertEqual(terminal_metadata(), {})
            process.assert_not_called()

    def test_diagnostics_exclude_conversation_and_tool_input(self):
        self.run_bridge(self.hook(tool_name="shell", tool_input={"command": "DO_NOT_SAVE"}, prompt="PRIVATE_BODY"))
        paths = list((self.data / "diagnostics").glob("*.json"))
        self.assertEqual(len(paths), 1)
        report = json.loads(paths[0].read_text())
        self.assertEqual(report["normalizedKind"], "approval")
        self.assertNotIn("DO_NOT_SAVE", paths[0].read_text())
        self.assertNotIn("PRIVATE_BODY", paths[0].read_text())
        self.assertEqual(stat.S_IMODE(paths[0].stat().st_mode), 0o600)

    def test_notify_reads_argv(self):
        result = self.run_bridge({"type": "agent-turn-complete", "thread-id": "notify-session", "turn-id": "notify-turn", "cwd": "/a/Atlas", "last-assistant-message": "PRIVATE"}, mode="notify", source="desktop")
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        event = self.events()[0]
        self.assertEqual((event["sessionId"], event["turnId"], event["kind"], event["source"]), ("notify-session", "notify-turn", "completed", "desktop"))
        self.assertNotIn("PRIVATE", json.dumps(event))

    def test_duplicate_delivery_keeps_stable_event_and_request_ids(self):
        payload = self.hook(tool_name="shell", tool_input={"command": "example", "a": 1})
        self.run_bridge(payload)
        self.run_bridge(payload)
        events = self.events()
        self.assertEqual(len(events), 2)
        self.assertEqual(len({event["eventId"] for event in events}), 1)
        self.assertEqual(len({event["requestId"] for event in events}), 1)

    def test_post_tool_result_correlates_without_exposing_output(self):
        self.run_bridge(self.hook(tool_use_id="call-1"))
        self.run_bridge(self.hook("PostToolUse", tool_use_id="call-1", tool_response={"error": "PRIVATE"}))
        events = sorted(self.events(), key=lambda event: event["occurredAt"])
        self.assertEqual([event["kind"] for event in events], ["approval", "resumed"])
        self.assertEqual(events[0]["requestId"], events[1]["requestId"])
        self.assertNotIn("PRIVATE", json.dumps(events))

    def test_unknown_tools_and_uncorrelated_results_are_ignored(self):
        for payload in [self.hook("PreToolUse", tool_name="shell"), self.hook("PostToolUse"), self.hook("StopFailure"), self.hook("SubagentStop"), self.hook("SessionStart")]:
            result = self.run_bridge(payload)
            self.assertEqual((result.returncode, result.stdout), (0, ""))
        self.assertEqual(self.events(), [])

    def test_only_explicit_question_tool_is_question(self):
        self.run_bridge(self.hook("PreToolUse", tool_name="request_user_input", tool_use_id="ask-1"))
        self.assertEqual(self.events()[0]["kind"], "question")

    def test_async_question_return_does_not_mean_user_answered(self):
        tool = dict(tool_name="request_user_input_async", tool_use_id="ask-async",
                    tool_input={"questions": [{"title": "PRIVATE_QUESTION"}]})
        self.run_bridge(self.hook("PreToolUse", **tool))
        self.run_bridge(self.hook("PostToolUse", tool_response="PRIVATE_RESPONSE", **tool))
        events = self.events()
        self.assertEqual([event["kind"] for event in events], ["question"])
        self.assertEqual(events[0]["requestId"], "tool:ask-async")
        self.assertNotIn("PRIVATE_", json.dumps(events))

    def test_blocking_question_return_resumes_the_matching_request(self):
        tool = dict(tool_name="request_user_input", tool_use_id="ask-blocking")
        self.run_bridge(self.hook("PreToolUse", **tool))
        self.run_bridge(self.hook("PostToolUse", **tool))
        events = sorted(self.events(), key=lambda event: event["occurredAt"])
        self.assertEqual([event["kind"] for event in events], ["question", "resumed"])
        self.assertEqual(events[0]["requestId"], events[1]["requestId"])

    def test_lifecycle_is_not_success_inference(self):
        for name in ["UserPromptSubmit", "Stop", "Interrupt", "SessionEnd"]:
            self.run_bridge(self.hook(name))
        self.assertEqual({event["kind"] for event in self.events()}, {"started", "completed", "stopped", "disconnected"})

    def test_malformed_and_missing_turn_do_not_block_hook(self):
        invalid = ["{", "null", "[]", '{"n":NaN}', self.hook(turn="wrong"), dict(hook_event_name="Stop", session_id="s-a")]
        invalid[4]["turn_id"] = ""
        for payload in invalid:
            result = self.run_bridge(payload)
            self.assertEqual((result.returncode, result.stdout), (0, ""))
            self.assertTrue(result.stderr)
        self.assertEqual(self.events(), [])

    def test_large_input_does_not_write_event(self):
        result = self.run_bridge(" " * (1024 * 1024 + 1))
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        self.assertEqual(self.events(), [])

    def test_standard_event_validates_fields_and_strips_nothing_silently(self):
        event = {"schemaVersion": 1, "eventId": "e-a", "source": "cli", "sessionId": "s-a", "turnId": "t-a", "project": "Example", "kind": "failed", "occurredAt": 1794200000.0, "isChild": False}
        result = self.run_bridge(event, mode="event", source=None)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.events()[0]["kind"], "failed")
        for key, value in [("summary", "private"), ("schemaVersion", 2), ("isChild", "false"), ("occurredAt", float("inf")), ("occurredAt", -1), ("source", "other"), ("eventId", "a\nb")]:
            result = self.run_bridge(dict(event, **{key: value}), mode="event", source=None)
            self.assertEqual(result.returncode, 2)
        self.assertEqual(len(self.events()), 1)

    def test_concurrent_writers_preserve_every_complete_event(self):
        def send(index):
            return self.run_bridge(dict(self.hook("Stop"), session_id="session-" + str(index)))
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(send, range(32)))
        self.assertTrue(all(result.returncode == 0 and result.stdout == "" for result in results))
        events = self.events()
        self.assertEqual(len(events), 32)
        self.assertEqual(len({event["sessionId"] for event in events}), 32)
        self.assertEqual(list((self.data / "inbox").glob("*.tmp")), [])

    def test_symlink_inbox_is_refused(self):
        self.data.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (self.data / "inbox").symlink_to(outside, target_is_directory=True)
        result = self.run_bridge(self.hook("Stop"))
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_source_must_be_explicit(self):
        result = self.run_bridge(self.hook("Stop"), source=None)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertEqual(self.events(), [])

    def test_generated_configuration_preserves_existing_files(self):
        before = (self.config.read_bytes(), self.hooks.read_bytes())
        result = subprocess.run([sys.executable, str(BRIDGE), "--print-hooks", "--source", "cli", "--data-dir", str(self.data)], text=True, capture_output=True, env=self.environment, timeout=10)
        self.assertEqual(result.returncode, 0)
        config = json.loads(result.stdout)
        self.assertIn("PermissionRequest", config["hooks"])
        self.assertNotIn("StopFailure", config["hooks"])
        for items in config["hooks"].values():
            self.assertEqual(items[0]["hooks"][0]["type"], "command")
            self.assertIn("--source cli", items[0]["hooks"][0]["command"])
        self.run_bridge(self.hook("Stop"))
        self.assertEqual(before, (self.config.read_bytes(), self.hooks.read_bytes()))


    def claude(self, name, turn="p-1", **extra):
        value = dict(hook_event_name=name, session_id="c-a", cwd="/private/example/Atlas", transcript_path="/private/SECRET_TRANSCRIPT.jsonl", **extra)
        if turn is not None:
            value["prompt_id"] = turn
        return value

    def claude_events(self):
        return sorted(self.events(), key=lambda event: event["occurredAt"])

    def test_claude_lifecycle_uses_prompt_id_as_turn(self):
        for payload in [self.claude("SessionStart", turn=None, source="startup"),
                        self.claude("UserPromptSubmit", prompt="SECRET_PROMPT", session_title="发布说明"),
                        self.claude("Notification", notification_type="permission_prompt", message="Claude needs your permission"),
                        self.claude("Stop", last_assistant_message="SECRET_REPLY")]:
            result = self.run_bridge(payload, source="claude")
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        events = self.claude_events()
        self.assertEqual([event["kind"] for event in events], ["started", "completed"])
        self.assertEqual({(event["source"], event["sessionId"], event["turnId"], event["project"]) for event in events},
                         {("claude", "c-a", "p-1", "Atlas")})
        self.assertEqual(events[0]["title"], "发布说明")
        serialized = json.dumps(events)
        for secret in ("SECRET_PROMPT", "SECRET_REPLY", "SECRET_TRANSCRIPT"):
            self.assertNotIn(secret, serialized)

    def test_claude_permission_and_question_resolve_by_tool_call(self):
        bash = {"tool_name": "Bash", "tool_input": {"command": "rm -rf build", "description": "Clean"}}
        ask = {"tool_name": "AskUserQuestion", "tool_input": {"questions": [{"question": "Which layout?"}]}}
        for name, extra in [("PreToolUse", dict(bash, tool_use_id="toolu_a")), ("PermissionRequest", bash),
                            ("PostToolUse", dict(bash, tool_use_id="toolu_a")), ("PreToolUse", dict(ask, tool_use_id="toolu_b")),
                            ("PermissionRequest", ask), ("PostToolUse", dict(ask, tool_use_id="toolu_b"))]:
            self.run_bridge(self.claude(name, **extra), source="claude")
        events = self.claude_events()
        self.assertEqual([(event["kind"], event["requestId"]) for event in events],
                         [("approval", "tool:toolu_a"), ("resumed", "tool:toolu_a"), ("question", "tool:toolu_b"),
                          ("question", "tool:toolu_b"), ("resumed", "tool:toolu_b")])
        # The question's permission dialog is the same request, not a second one.
        self.assertEqual(events[2]["eventId"], events[3]["eventId"])
        self.assertNotIn("rm -rf", json.dumps(events))

    def test_claude_turn_endings_without_interrupt_hook(self):
        cases = [("StopFailure", {"error": "rate_limit"}, "failed"), ("Notification", {"notification_type": "idle_prompt"}, "stopped"),
                 ("SessionEnd", {"reason": "prompt_input_exit"}, "stopped")]
        for index, (name, extra, _) in enumerate(cases):
            self.run_bridge(self.claude(name, turn="p-" + str(index), **extra), source="claude")
        self.assertEqual([event["kind"] for event in self.claude_events()], [kind for _, _, kind in cases])
        result = self.run_bridge(self.claude("SessionEnd", turn=None, reason="other"), source="claude")
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertEqual(len(self.events()), 3)

    def test_claude_never_reads_codex_titles(self):
        (self.fake_home / ".codex" / "session_index.jsonl").write_text(
            json.dumps({"id": "c-a", "thread_name": "Codex 标题", "updated_at": "2026-01-01T00:00:00Z"}) + "\n")
        self.run_bridge(self.claude("Stop"), source="claude")
        self.assertNotIn("title", self.events()[0])

    def test_claude_terminal_metadata_uses_claude_process_tty(self):
        from signal_bridge import terminal_metadata
        result = subprocess.CompletedProcess([], 0, stdout="ttys013\n", stderr="")
        for agent_record in [(42, "claude", "claude"), (42, "/usr/local/bin/node", "node /usr/local/bin/claude --resume x")]:
            records = [agent_record, (1, "/bin/zsh", "zsh")]
            with patch("signal_bridge.process_record", side_effect=records), patch("signal_bridge.subprocess.run", return_value=result), \
                    patch.dict(os.environ, {"TERM_PROGRAM": "ghostty"}):
                self.assertEqual(terminal_metadata("claude"), {"terminalTTY": "/dev/ttys013", "terminalBundleID": "com.mitchellh.ghostty"})
        # A Codex receiver must not mistake Claude Code for its own CLI, and vice versa.
        with patch("signal_bridge.process_record", side_effect=[(42, "claude", "claude"), (1, "/bin/zsh", "zsh")]), \
                patch("signal_bridge.subprocess.run", return_value=result):
            self.assertEqual(terminal_metadata(), {})
        with patch("signal_bridge.process_record", side_effect=[(42, "/usr/local/bin/codex", "codex"), (1, "/bin/zsh", "zsh")]), \
                patch("signal_bridge.subprocess.run", return_value=result):
            self.assertEqual(terminal_metadata("claude"), {})

    def test_claude_configuration_registers_only_claude_events(self):
        from signal_bridge import CLAUDE_HOOKS
        result = subprocess.run([sys.executable, str(BRIDGE), "--print-hooks", "--source", "claude", "--data-dir", str(self.data)],
                                text=True, capture_output=True, env=self.environment, timeout=10)
        self.assertEqual(result.returncode, 0)
        hooks = json.loads(result.stdout)["hooks"]
        self.assertEqual(set(hooks), set(CLAUDE_HOOKS))
        self.assertEqual(hooks["Notification"][0]["matcher"], "idle_prompt")
        self.assertTrue(all("--source claude" in groups[0]["hooks"][0]["command"] for groups in hooks.values()))

if __name__ == "__main__":
    unittest.main(verbosity=2)

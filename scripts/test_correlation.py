#!/usr/bin/env python3
from concurrent.futures import ProcessPoolExecutor
import json
from pathlib import Path
import sqlite3
import stat
import tempfile
import unittest

from request_correlation import enrich_hook
from signal_bridge import normalize


def record_call(arguments):
    raw, source, root = arguments
    return enrich_hook(raw, source, Path(root))


class CorrelationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="signal-correlation-test-")
        self.root = Path(self.temporary.name) / "data"

    def tearDown(self):
        self.temporary.cleanup()

    def hook(self, name, tool_id=None, session="s-a", turn="t-a", command="/usr/bin/true"):
        value = {"hook_event_name": name, "session_id": session, "turn_id": turn, "tool_name": "Bash", "tool_input": {"command": command}, "cwd": "/private/project"}
        if tool_id is not None:
            value["tool_use_id"] = tool_id
        return value

    def enrich(self, value, source="cli"):
        return enrich_hook(value, source, self.root)

    def test_real_hook_shapes_share_request_identity_after_enrichment(self):
        self.enrich(self.hook("PreToolUse", "call-a"))
        approval_raw = self.hook("PermissionRequest")
        approval = normalize(self.enrich(approval_raw), "hook", "cli", now=10)
        resumed = normalize(self.enrich(self.hook("PostToolUse", "call-a")), "hook", "cli", now=11)
        self.assertEqual(approval["requestId"], "tool:call-a")
        self.assertEqual(resumed["requestId"], approval["requestId"])
        self.assertNotIn("tool_use_id", approval_raw)

    def test_approval_description_does_not_change_bash_identity(self):
        self.enrich(self.hook("PreToolUse", "call-a"))
        approval = self.hook("PermissionRequest")
        approval["tool_input"]["description"] = "Allow the harmless test?"
        self.assertEqual(self.enrich(approval)["tool_use_id"], "call-a")

    def test_ambiguous_calls_never_get_an_invented_identity(self):
        for tool_id in ["call-a", "call-b"]:
            self.enrich(self.hook("PreToolUse", tool_id))
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest")))
        self.enrich(self.hook("PostToolUse", "call-a"))
        self.assertEqual(self.enrich(self.hook("PermissionRequest"))["tool_use_id"], "call-b")

    def test_completed_call_cannot_reopen_from_duplicate_pre_event(self):
        self.enrich(self.hook("PreToolUse", "call-a"))
        self.enrich(self.hook("PostToolUse", "call-a"))
        self.enrich(self.hook("PreToolUse", "call-a"))
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest")))

    def test_post_before_pre_still_prevents_reopening(self):
        self.enrich(self.hook("PostToolUse", "call-a"))
        self.enrich(self.hook("PreToolUse", "call-a"))
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest")))

    def test_duplicate_pre_keeps_one_candidate(self):
        for _ in range(3):
            self.enrich(self.hook("PreToolUse", "call-a"))
        self.assertEqual(self.enrich(self.hook("PermissionRequest"))["tool_use_id"], "call-a")

    def test_sources_sessions_turns_and_inputs_are_isolated(self):
        self.enrich(self.hook("PreToolUse", "call-cli"))
        self.enrich(self.hook("PreToolUse", "call-desktop"), "desktop")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"))["tool_use_id"], "call-cli")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "desktop")["tool_use_id"], "call-desktop")
        for raw in [self.hook("PermissionRequest", session="s-other"), self.hook("PermissionRequest", turn="t-other"), self.hook("PermissionRequest", command="/bin/echo different")]:
            self.assertNotIn("tool_use_id", self.enrich(raw))

    def test_auto_adopts_one_legacy_owner_and_keeps_it_when_other_source_appears(self):
        self.enrich(self.hook("PreToolUse", "legacy-call"), "unknown")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "auto")["tool_use_id"], "legacy-call")
        self.enrich(self.hook("PreToolUse", "desktop-call"), "desktop")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "auto")["tool_use_id"], "legacy-call")
        self.enrich(self.hook("PostToolUse", "legacy-call"), "auto")
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest"), "auto"))
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "desktop")["tool_use_id"], "desktop-call")

    def test_auto_never_guesses_between_legacy_owners(self):
        self.enrich(self.hook("PreToolUse", "cli-call"), "cli")
        self.enrich(self.hook("PreToolUse", "desktop-call"), "desktop")
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest"), "auto"))
        self.enrich(self.hook("PreToolUse", "auto-call"), "auto")
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest"), "auto"))
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "cli")["tool_use_id"], "cli-call")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "desktop")["tool_use_id"], "desktop-call")

    def test_auto_honors_legacy_incomplete_marker(self):
        from request_correlation import _incomplete_marker, _mark_incomplete
        self.enrich(self.hook("PreToolUse", "legacy-call"), "unknown")
        _mark_incomplete(_incomplete_marker(self.root, "unknown", "s-a", "t-a"))
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest"), "auto"))

    def test_auto_honors_lost_legacy_pre_with_no_database_row(self):
        from request_correlation import _incomplete_marker, _mark_incomplete
        _mark_incomplete(_incomplete_marker(self.root, "unknown", "s-a", "t-a"))
        self.enrich(self.hook("PreToolUse", "auto-call"), "auto")
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest"), "auto"))

    def test_new_auto_owner_remains_separate_from_later_explicit_sources(self):
        self.enrich(self.hook("PreToolUse", "auto-call"), "auto")
        self.enrich(self.hook("PreToolUse", "cli-call"), "cli")
        self.enrich(self.hook("PreToolUse", "desktop-call"), "desktop")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "auto")["tool_use_id"], "auto-call")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "cli")["tool_use_id"], "cli-call")
        self.assertEqual(self.enrich(self.hook("PermissionRequest"), "desktop")["tool_use_id"], "desktop-call")

    def test_auto_lifecycle_cleans_owner_records(self):
        self.enrich(self.hook("PreToolUse", "auto-call"), "auto")
        self.enrich(self.hook("UserPromptSubmit", turn="next"), "auto")
        database = self.root / "correlation/requests.sqlite3"
        connection = sqlite3.connect(database)
        try:
            self.assertEqual(connection.execute("SELECT turn_id FROM auto_owners").fetchall(), [("next",)])
            self.assertEqual(connection.execute("SELECT tool_id FROM calls").fetchall(), [])
        finally:
            connection.close()

    def test_lifecycle_cleanup_does_not_touch_other_session(self):
        self.enrich(self.hook("PreToolUse", "call-a"))
        self.enrich(self.hook("PreToolUse", "call-other", session="s-other"))
        self.enrich(self.hook("UserPromptSubmit", turn="t-new"))
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest")))
        self.assertEqual(self.enrich(self.hook("PermissionRequest", session="s-other"))["tool_use_id"], "call-other")
        self.enrich(self.hook("PreToolUse", "call-new", turn="t-new"))
        self.enrich(self.hook("Interrupt", turn="t-new"))
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest", turn="t-new")))
        self.enrich(self.hook("Stop", session="s-other"))
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest", session="s-other")))

    def test_explicit_permission_id_is_preserved(self):
        self.enrich(self.hook("PreToolUse", "call-a"))
        result = self.enrich(self.hook("PermissionRequest", "explicit-other"))
        self.assertEqual(result["tool_use_id"], "explicit-other")

    def test_input_order_does_not_change_fingerprint(self):
        first = self.hook("PreToolUse", "call-a")
        first["tool_input"] = {"command": "true", "timeout": 1}
        self.enrich(first)
        second = self.hook("PermissionRequest")
        second["tool_input"] = {"timeout": 1, "command": "true"}
        self.assertEqual(self.enrich(second)["tool_use_id"], "call-a")

    def test_database_contains_no_tool_body_or_conversation(self):
        raw = self.hook("PreToolUse", "call-a", command="CONFIDENTIAL_TOOL_BODY_2514")
        raw["prompt"] = "CONFIDENTIAL_PROMPT_8193"
        self.enrich(raw)
        database = self.root / "correlation" / "requests.sqlite3"
        all_bytes = b"".join(path.read_bytes() for path in database.parent.iterdir() if path.is_file())
        for secret in [b"CONFIDENTIAL_TOOL_BODY_2514", b"CONFIDENTIAL_PROMPT_8193", b"/private/project"]:
            self.assertNotIn(secret, all_bytes)
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(database.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(database.stat().st_mode), 0o600)

    def test_database_busy_or_invalid_input_leaves_original_unchanged(self):
        self.enrich(self.hook("PreToolUse", "call-a"))
        database = self.root / "correlation" / "requests.sqlite3"
        connection = sqlite3.connect(database)
        connection.execute("BEGIN IMMEDIATE")
        try:
            raw = self.hook("PermissionRequest")
            self.assertEqual(self.enrich(raw), raw)
        finally:
            connection.rollback()
            connection.close()
        for raw in [{}, self.hook("PermissionRequest", session=""), self.hook("PermissionRequest", turn="")]:
            self.assertEqual(self.enrich(raw), raw)

    def test_lost_pre_during_database_lock_disables_turn_correlation(self):
        self.enrich(self.hook("PreToolUse", "call-a"))
        database = self.root / "correlation" / "requests.sqlite3"
        connection = sqlite3.connect(database)
        connection.execute("BEGIN IMMEDIATE")
        try:
            second = self.hook("PreToolUse", "call-b")
            self.assertEqual(self.enrich(second), second)
        finally:
            connection.rollback()
            connection.close()
        self.assertNotIn("tool_use_id", self.enrich(self.hook("PermissionRequest")))
        self.enrich(self.hook("UserPromptSubmit", turn="t-next"))
        self.enrich(self.hook("PreToolUse", "call-next", turn="t-next"))
        self.assertEqual(self.enrich(self.hook("PermissionRequest", turn="t-next"))["tool_use_id"], "call-next")

    def test_unknown_or_invalid_pre_does_not_create_correlation_files(self):
        for value in [self.hook("Unknown"), self.hook("PreToolUse"), self.hook("PreToolUse", "call-a", session="")]:
            self.assertEqual(self.enrich(value), value)
        self.assertFalse(self.root.exists())

    def test_symlink_database_is_refused(self):
        directory = self.root / "correlation"
        directory.mkdir(parents=True)
        outside = Path(self.temporary.name) / "outside.sqlite3"
        outside.write_bytes(b"untouched")
        (directory / "requests.sqlite3").symlink_to(outside)
        raw = self.hook("PreToolUse", "call-a")
        self.assertEqual(self.enrich(raw), raw)
        self.assertEqual(outside.read_bytes(), b"untouched")

    def test_parallel_processes_do_not_lose_distinct_calls(self):
        self.enrich(self.hook("UserPromptSubmit"))
        calls = [self.hook("PreToolUse", "call-" + str(index), command="command-" + str(index)) for index in range(12)]
        with ProcessPoolExecutor(max_workers=4) as pool:
            list(pool.map(record_call, [(raw, "cli", str(self.root)) for raw in calls]))
        for index in range(12):
            result = self.enrich(self.hook("PermissionRequest", command="command-" + str(index)))
            self.assertEqual(result.get("tool_use_id"), "call-" + str(index))


if __name__ == "__main__":
    unittest.main(verbosity=2)

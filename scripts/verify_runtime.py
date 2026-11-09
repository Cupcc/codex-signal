#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

from signal_bridge import validate_event, write_event


class RuntimeCheck:
    def __init__(self, app, directory):
        self.app = app
        self.directory = directory
        self.pids = set()
        self.results = []
        self.timestamp = time.time() - 1000

    def settings(self, enabled=False):
        value = {"speechEnabled": enabled, "quietHoursEnabled": False, "quietStart": 22, "quietEnd": 8}
        (self.directory / "settings.json").write_text(json.dumps(value))

    def snapshot(self):
        try:
            value = json.loads((self.directory / "runtime-status.json").read_text())
            pid = value.get("processID")
            if isinstance(pid, int) and self.owns_process(pid):
                self.pids.add(pid)
            return value
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def owns_process(self, pid):
        value = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
        return value.returncode == 0 and str(self.app / "Contents/MacOS/CodexSignal") in value.stdout and str(self.directory) in value.stdout

    def wait(self, predicate, label, timeout=20):
        deadline = time.monotonic() + timeout
        latest = {}
        while time.monotonic() < deadline:
            latest = self.snapshot()
            if predicate(latest):
                return latest
            time.sleep(0.1)
        raise AssertionError(label + "; last snapshot=" + json.dumps(latest, ensure_ascii=False))

    def launch(self):
        previous = self.snapshot().get("processID")
        subprocess.run(["open", "-n", str(self.app), "--args", "--data-dir", str(self.directory)], check=True, timeout=15)
        return self.wait(lambda value: value.get("processID") != previous and isinstance(value.get("processID"), int) and self.owns_process(value["processID"]), "new app process did not publish its snapshot")

    def stop(self):
        self.snapshot()
        for pid in tuple(self.pids):
            if self.owns_process(pid):
                os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 5
                while self.owns_process(pid) and time.monotonic() < deadline:
                    time.sleep(0.1)
                if self.owns_process(pid):
                    raise AssertionError("test app process did not terminate: " + str(pid))
            self.pids.discard(pid)

    def event(self, kind, session="runtime-main", turn="turn-0", request=None):
        self.timestamp += 0.01
        return validate_event({"schemaVersion": 1, "eventId": uuid.uuid4().hex, "source": "cli", "sessionId": session, "turnId": turn, "requestId": request, "project": "Runtime verification", "kind": kind, "occurredAt": self.timestamp, "isChild": False})

    def send(self, event):
        write_event(event, self.directory)
        self.wait(lambda _: not list((self.directory / "inbox").glob("*.json")), "inbox did not drain")
        return self.snapshot()

    def row(self, value, session="runtime-main"):
        return next((row for row in value.get("sessions", []) if row["sessionId"] == session), {})

    def expect_phase(self, phase, session="runtime-main"):
        return self.wait(lambda value: self.row(value, session).get("phase") == phase, "expected " + session + " to be " + phase)

    def passed(self, name, evidence):
        self.results.append({"name": name, "status": "VERIFIED", "evidence": evidence})
        print("PASS " + name, flush=True)

    def verify(self, check_speech):
        self.settings()
        self.launch()
        self.send(self.event("started"))
        self.expect_phase("running")
        self.stop()

        self.settings(enabled=check_speech)
        earlier = self.event("started", turn="turn-1")
        filler = [self.event("started", session="filler-" + str(index), turn="turn-a") for index in range(240)]
        later = self.event("question", turn="turn-1", request="backlog-question")
        events = [earlier] + filler + [later]
        inbox = self.directory / "inbox"
        for index, event in enumerate(events):
            path = inbox / (f"{len(events) - index:04d}" + ".json")
            path.write_text(json.dumps(event))
            path.chmod(0o600)
        self.launch()
        self.wait(lambda value: len(value.get("sessions", [])) == 241 and not list(inbox.glob("*.json")), "242 startup events did not drain", timeout=30)
        self.expect_phase("question")
        self.passed("startup backlog preserves event order", "242 events with filenames in reverse chronological order reached the latest question")
        time.sleep(3.5)
        assert self.snapshot()["speechCount"] == 0, "startup backlog replayed voice"
        if check_speech:
            self.passed("startup backlog does not replay voice", "speech was enabled and speechCount stayed zero beyond the aggregation window")
        else:
            self.results.append({"name": "startup voice suppression", "status": "NOT VERIFIED", "evidence": "speech disabled; rerun with --check-speech to distinguish startup suppression from mute"})
        self.stop()

        self.settings()
        self.launch()
        self.send(self.event("resumed", turn="turn-1", request="backlog-question"))
        self.expect_phase("running")
        self.send(self.event("approval", turn="turn-1", request="approval-one"))
        self.expect_phase("approval")
        self.send(self.event("resumed", turn="turn-1", request="wrong-request"))
        self.expect_phase("approval")
        self.send(self.event("resumed", turn="turn-1", request="approval-one"))
        self.expect_phase("running")
        self.send(self.event("started", turn="turn-2"))
        question = self.event("question", turn="turn-2", request="question-two")
        self.send(question)
        self.expect_phase("question")
        self.send(self.event("completed", turn="turn-1"))
        value = self.expect_phase("question")
        assert self.row(value)["pending"] is True
        self.passed("request matching and stale turn protection", "wrong request stays pending, matching request resumes, retired turn completion cannot clear the new question")

        before = self.snapshot()
        self.send(question)
        after = self.snapshot()
        assert before["sessions"] == after["sessions"], "duplicate changed session state"
        assert before["speechCount"] == after["speechCount"], "duplicate changed voice count"
        self.passed("duplicate event leaves state unchanged", "session records and speech count are identical after replaying the same event")

        metadata = dict(question, title="核对会话标题与等待状态", eventId=uuid.uuid4().hex)
        self.send(metadata)
        titled = self.snapshot()
        assert self.row(titled)["title"] == metadata["title"], "metadata-only event lost its title"
        assert self.row(titled)["phase"] == "question" and self.row(titled)["pending"] is True
        assert titled["speechCount"] == after["speechCount"], "metadata-only event triggered speech"
        self.passed("metadata refresh preserves lifecycle", "title changes without clearing the pending question or replaying voice")

        expected = titled["sessions"]
        self.stop()
        self.settings(enabled=check_speech)
        self.launch()
        value = self.snapshot()
        assert value["sessions"] == expected, "restart did not restore the same sessions"
        time.sleep(3.5)
        assert self.snapshot()["speechCount"] == 0, "restart replayed voice"
        self.passed("restart restores state", "session records are identical across process restart")
        if check_speech:
            self.passed("restart does not replay voice", "speech was enabled and speechCount stayed zero beyond the aggregation window")
        else:
            self.results.append({"name": "restart voice suppression", "status": "NOT VERIFIED", "evidence": "speech disabled; rerun with --check-speech for audible policy verification"})

        first_pid = self.snapshot()["processID"]
        digest_before = hashlib.sha256((self.directory / "state.json").read_bytes()).hexdigest()
        with (self.directory / "instance.lock").open("r+") as lock_file:
            try:
                fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                fcntl.flock(lock_file, fcntl.LOCK_UN)
                raise AssertionError("running app does not hold the data directory lock")
        second = subprocess.Popen(["open", "-n", "-W", str(self.app), "--args", "--data-dir", str(self.directory)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            output, error = second.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            self.snapshot()
            second.terminate()
            second.communicate(timeout=5)
            raise AssertionError("second app instance did not exit")
        assert second.returncode == 0, "second launch failed before testing app lock: " + error
        assert self.snapshot()["processID"] == first_pid, "second instance replaced runtime state"
        assert self.owns_process(first_pid), "original app exited"
        assert hashlib.sha256((self.directory / "state.json").read_bytes()).hexdigest() == digest_before, "second instance modified state"
        self.passed("second instance preserves the single writer", "lock is held, duplicate launch exits, original PID and state digest remain unchanged")


def main():
    parser = argparse.ArgumentParser(description="Verify the packaged macOS app with synthetic events in a temporary data directory.")
    parser.add_argument("--app", type=Path, default=Path(__file__).resolve().parent.parent / "dist/CodexSignal.app")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check-speech", action="store_true", help="enable speech during startup checks; expected silence, a regression may speak")
    args = parser.parse_args()
    app = args.app.resolve()
    if not (app / "Contents/MacOS/CodexSignal").is_file():
        parser.error("build dist/CodexSignal.app first")
    directory = Path(tempfile.mkdtemp(prefix="codex-signal-runtime-"))
    checker = RuntimeCheck(app, directory)
    report = {"artifact": str(app), "dataDirectory": str(directory), "input": "synthetic standard events; not live Codex", "checks": checker.results}
    status = 0
    try:
        checker.verify(args.check_speech)
        report["status"] = "VERIFIED" if args.check_speech else "PARTIAL"
    except Exception as error:
        status = 1
        report["status"] = "FAILED"
        report["error"] = str(error)
        print("FAIL " + str(error), flush=True)
    finally:
        try:
            checker.stop()
        except Exception as error:
            status = 1
            report["cleanupError"] = str(error)
        report_path = args.output or directory / "verification.json"
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps({"report": str(report_path), "dataDirectory": str(directory), "status": report.get("status")}, ensure_ascii=False))
    return status


if __name__ == "__main__":
    raise SystemExit(main())

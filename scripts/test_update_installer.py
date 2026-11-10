"""Exercise real app-directory swaps; substitute only Launch Services in a temp helper."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / "Sources/SignalApp/Resources/install-update.sh"


class UpdateInstallerTests(unittest.TestCase):
    def run_install(self, fail_launch=False, missing_destination=False):
        with tempfile.TemporaryDirectory(prefix="signal update '") as root:
            root = Path(root)
            destination = root / "Codex Signal.app"
            replacement = root / ".update.app"
            staging = root / "staging"
            staging.mkdir()
            replacement.mkdir()
            (replacement / "version").write_text("new")
            if not missing_destination:
                destination.mkdir()
                (destination / "version").write_text("old")
            # The stub fails only for the new app; old-app and browser opens succeed.
            launcher = root / "open-stub"
            launcher.write_text('#!/bin/bash\n' + (
                'if test -f "$1/version" && test "$(cat "$1/version")" = new; then exit 1; fi\n'
                if fail_launch else '') + 'exit 0\n')
            launcher.chmod(0o755)
            helper = root / "install.sh"
            import shlex
            helper.write_text(HELPER.read_text().replace("/usr/bin/open", shlex.quote(str(launcher))))
            receipt = root / "result.txt"
            # A reaped process provides a genuinely exited parent PID.
            parent = subprocess.Popen(["/usr/bin/true"])
            parent.wait()
            result = subprocess.run(["/bin/bash", str(helper), str(parent.pid), str(replacement),
                                     str(destination), str(receipt), str(staging), str(root / "data")], capture_output=True, timeout=10)
            if fail_launch:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((destination / "version").read_text(), "old")
                self.assertEqual(receipt.read_text().strip(), "failed")
            elif missing_destination:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((replacement / "version").read_text(), "new")
                self.assertEqual(receipt.read_text().strip(), "failed")
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((destination / "version").read_text(), "new")
                self.assertEqual((root / ".update-previous.app/version").read_text(), "old")
                self.assertEqual(receipt.read_text().strip(), "success")
                self.assertFalse(staging.exists())

    def test_success_keeps_backup(self):
        self.run_install()

    def test_launch_failure_restores_old_app(self):
        self.run_install(fail_launch=True)

    def test_missing_destination_preserves_download(self):
        self.run_install(missing_destination=True)


if __name__ == "__main__":
    unittest.main()

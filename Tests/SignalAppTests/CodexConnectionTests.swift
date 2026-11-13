import Foundation
import Testing
@testable import SignalApp

@MainActor
struct CodexConnectionTests {
    private func fixture() throws -> (root: URL, resources: URL, codex: URL, data: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signal-setup-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Resources")
        let bridge = resources.appendingPathComponent("Bridge")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts")
        for name in ["configure_hooks.py", "signal_bridge.py", "request_correlation.py"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: bridge.appendingPathComponent(name))
        }
        return (root, resources, root.appendingPathComponent("custom-codex"), root.appendingPathComponent("data"))
    }

    private func finished(_ connection: HookConnection) async throws {
        for _ in 0..<500 {
            if !connection.isConfiguring { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Hook installation did not finish")
    }

    @Test func missingComponentShowsRecoverableFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let connection = HookConnection(dataDirectory: directory, home: directory, resources: nil)
        #expect(connection.state == .idle)
        connection.configure()
        connection.configure()
        #expect(connection.isConfiguring)
        try await finished(connection)
        guard case .failed(let message) = connection.state else { Issue.record("Expected installation failure"); return }
        #expect(message.contains("重新安装"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("hooks.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex-connection.json").path))
        try FileManager.default.removeItem(at: directory)
    }

    @Test func manualConfigurationAlwaysRebuildsAndWaitsForEvent() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let connection = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources)
        connection.configure()
        try await finished(connection)
        #expect(connection.state == .configured)
        #expect(connection.needsReview)
        #expect(connection.installation?.changed == true)
        #expect(connection.installation?.hooksPath == f.codex.appendingPathComponent("hooks.json").path)
        connection.receivedEvent()
        #expect(connection.state == .receiving)
        #expect(!connection.needsReview)
        connection.configure()
        try await finished(connection)
        #expect(connection.state == .configured)
        #expect(connection.installation?.changed == true)
        #expect(connection.installation?.backupPath != nil)
    }

    @Test func normalStartupRestoresReceiptWithoutInspectingOrRepairingHooks() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources, installationID: "install-a")
        installed.configureAfterInstallation()
        try await finished(installed)
        #expect(installed.state == .configured)
        let receipt = f.data.appendingPathComponent("codex-connection.json")
        let originalReceipt = try Data(contentsOf: receipt)
        let originalDate = try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let hooks = f.codex.appendingPathComponent("hooks.json")
        try FileManager.default.removeItem(at: hooks)
        try FileManager.default.removeItem(at: f.data.appendingPathComponent("Bridge"))

        let relaunched = HookConnection(dataDirectory: f.data, home: f.codex, resources: nil, installationID: "install-a")
        relaunched.configureAfterInstallation()

        #expect(!relaunched.isConfiguring)
        #expect(relaunched.state == .configured)
        #expect(relaunched.installation?.hooksPath == hooks.path)
        #expect(!FileManager.default.fileExists(atPath: hooks.path))
        #expect(!FileManager.default.fileExists(atPath: f.data.appendingPathComponent("Bridge").path))
        #expect(try Data(contentsOf: receipt) == originalReceipt)
        #expect(try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
    }

    @Test func reinstallChecksOnceAndNextStartupSkipsInstaller() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources, installationID: "install-a")
        original.configureAfterInstallation()
        try await finished(original)
        let hooks = f.codex.appendingPathComponent("hooks.json")
        try FileManager.default.removeItem(at: hooks)

        let reinstalled = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources, installationID: "install-b")
        reinstalled.configureAfterInstallation()
        #expect(reinstalled.isConfiguring)
        try await finished(reinstalled)
        #expect(reinstalled.state == .configured)
        #expect(FileManager.default.fileExists(atPath: hooks.path))

        let relaunched = HookConnection(dataDirectory: f.data, home: f.codex, resources: nil, installationID: "install-b")
        relaunched.configureAfterInstallation()
        #expect(relaunched.state == .configured)
        #expect(!relaunched.isConfiguring)
    }

    @Test func installationWithUnchangedBridgeKeepsExistingConfiguration() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources, installationID: "install-a")
        original.configureAfterInstallation()
        try await finished(original)
        let hooks = f.codex.appendingPathComponent("hooks.json")
        let before = try Data(contentsOf: hooks)
        let modified = try hooks.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let upgraded = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources, installationID: "install-b")
        upgraded.configureAfterInstallation()
        #expect(upgraded.isConfiguring)
        try await finished(upgraded)

        #expect(upgraded.state == .configured)
        #expect(upgraded.installation?.changed == false)
        #expect(upgraded.installation?.backupPath == nil)
        #expect(try Data(contentsOf: hooks) == before)
        #expect(try hooks.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    @Test func failedInstallationWaitsForManualRetryAcrossRestarts() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let failed = HookConnection(dataDirectory: f.data, home: f.codex, resources: nil, installationID: "install-a")
        failed.configureAfterInstallation()
        try await finished(failed)
        guard case .failed = failed.state else { Issue.record("Expected component failure"); return }
        let receipt = try Data(contentsOf: f.data.appendingPathComponent("codex-connection.json"))

        let relaunched = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources, installationID: "install-a")
        relaunched.configureAfterInstallation()
        #expect(relaunched.state == failed.state)
        #expect(!relaunched.isConfiguring)
        #expect(!FileManager.default.fileExists(atPath: f.codex.path))
        #expect(try Data(contentsOf: f.data.appendingPathComponent("codex-connection.json")) == receipt)
        relaunched.configure()
        try await finished(relaunched)
        #expect(relaunched.state == .configured)
        #expect(relaunched.installation?.changed == true)
    }

    @Test func interruptedInstallationWaitsForManualRetry() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.data, withIntermediateDirectories: true)
        let receipt: [String: Any] = ["schemaVersion": 1, "installationID": "install-a", "codexHome": f.codex.standardizedFileURL.path,
                                      "outcome": ["pending": [:]]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: f.data.appendingPathComponent("codex-connection.json"))
        let connection = HookConnection(dataDirectory: f.data, home: f.codex, resources: f.resources, installationID: "install-a")
        connection.configureAfterInstallation()
        #expect(connection.state == .failed("上次配置未完成，请重试。"))
        #expect(!connection.isConfiguring)
        #expect(!FileManager.default.fileExists(atPath: f.codex.path))
        connection.configure()
        try await finished(connection)
        #expect(connection.state == .configured)
    }

    @Test func installIdentitySurvivesMoveAndChangesWhenSameVersionIsReinstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Signal.app")
        let executable = app.appendingPathComponent("Contents/MacOS/CodexSignal")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "io.github.cupcc.fixture.\(UUID().uuidString)", "CFBundleExecutable": "CodexSignal",
                     "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "6"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("original".utf8).write(to: executable)
        let initial = HookConnection.installationIdentifier(for: try #require(Bundle(url: app)))
        #expect(HookConnection.installationIdentifier(for: try #require(Bundle(url: app))) == initial)
        let moved = root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: app, to: moved)
        let bundle = try #require(Bundle(url: moved))
        #expect(HookConnection.installationIdentifier(for: bundle) == initial)
        let replacement = root.appendingPathComponent("replacement")
        try Data("same version reinstalled".utf8).write(to: replacement)
        let movedExecutable = moved.appendingPathComponent("Contents/MacOS/CodexSignal")
        try FileManager.default.removeItem(at: movedExecutable)
        try FileManager.default.moveItem(at: replacement, to: movedExecutable)
        #expect(HookConnection.installationIdentifier(for: bundle) != initial)
    }

    @Test func configurationDoesNotClaimAnEventWasReceived() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let connection = HookConnection(dataDirectory: directory, home: directory, resources: nil)
        #expect(connection.status == "尚未配置")
        #expect(!connection.needsReview)
        connection.receivedEvent()
        #expect(connection.status == "已接收事件")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func claudeSetupSkipsMissingHomeUntilRequested() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let home = f.root.appendingPathComponent("claude-home")
        let connection = HookConnection(agent: .claude, dataDirectory: f.data, home: home, resources: f.resources, installationID: "install-a")
        connection.configureAfterInstallation()
        #expect(connection.state == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: home.path))
        #expect(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("claude-connection.json").path))
        #expect(!FileManager.default.fileExists(atPath: f.data.appendingPathComponent("codex-connection.json").path))
        let relaunched = HookConnection(agent: .claude, dataDirectory: f.data, home: home, resources: nil, installationID: "install-a")
        relaunched.configureAfterInstallation()
        #expect(relaunched.state == .unavailable)
        connection.configure()
        try await finished(connection)
        #expect(connection.state == .configured)
        #expect(!connection.needsReview)
        #expect(connection.installation?.hooksPath == home.appendingPathComponent("settings.json").path)
    }

    @Test func claudeSetupMergesIntoExistingSettings() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let home = f.root.appendingPathComponent("claude-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: home.appendingPathComponent("settings.json"))
        let connection = HookConnection(agent: .claude, dataDirectory: f.data, home: home, resources: f.resources, installationID: "install-a")
        connection.configureAfterInstallation()
        try await finished(connection)
        #expect(connection.state == .configured)
        let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("settings.json"))) as? [String: Any])
        #expect(settings["model"] as? String == "opus")
        #expect((settings["hooks"] as? [String: Any])?["PermissionRequest"] != nil)
        #expect(!FileManager.default.fileExists(atPath: f.codex.path))
    }
}

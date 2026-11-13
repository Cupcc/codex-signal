import Foundation
import Testing
@testable import SignalApp

struct UpdateTests {
    private func release(version: String = "v0.3.0", digest: String? = "sha256:" + String(repeating: "a", count: 64),
                         host: String = "github.com", prerelease: Bool = false) throws -> UpdateRelease {
        let asset: [String: Any] = [
            "name": "CodexSignal-0.3.0-arm64.zip",
            "browser_download_url": "https://\(host)/Cupcc/codex-signal/releases/download/\(version)/CodexSignal-0.3.0-arm64.zip",
            "digest": digest as Any? ?? NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": version, "draft": false, "prerelease": prerelease, "assets": [asset]])
        return try JSONDecoder().decode(UpdateRelease.self, from: data)
    }

    @Test func versionsCompareNumerically() throws {
        #expect(try #require(AppVersion("0.10.0")) > #require(AppVersion("v0.9.9")))
        #expect(AppVersion("v1.2.3") == AppVersion("1.2.3"))
        #expect(AppVersion("1.2.3-beta") == nil)
        #expect(AppVersion("1.2") == nil)
        #expect(AppVersion("1.2.-1") == nil)
        #expect(AppVersion("1.2.999999999999999999999999") == nil)
    }

    @Test func onlyNewStableReleaseIsOffered() throws {
        let current = try #require(AppVersion("0.2.0"))
        #expect(try release().update(after: current)?.version == AppVersion("0.3.0"))
        #expect(try release().update(after: #require(AppVersion("0.3.0"))) == nil)
        #expect(try release().update(after: #require(AppVersion("0.4.0"))) == nil)
        #expect(try release(prerelease: true).update(after: current) == nil)
    }

    @Test func unverifiedOrForeignPackagesAreRejected() throws {
        let current = try #require(AppVersion("0.2.0"))
        #expect(throws: UpdateError.self) { try release(digest: nil).update(after: current) }
        #expect(throws: UpdateError.self) { try release(digest: "sha256:abc").update(after: current) }
        #expect(throws: UpdateError.self) { try release(host: "example.org").update(after: current) }
        #expect(throws: UpdateError.self) { try release(version: "invalid").update(after: current) }
    }

    @Test func corruptedDownloadDoesNotPassVerification() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try UpdateService.verifyChecksum(file, expected: expected)
        try Data("damaged".utf8).write(to: file)
        #expect(throws: UpdateError.self) { try UpdateService.verifyChecksum(file, expected: expected) }
    }

    @Test func httpFailuresAreNotTreatedAsCurrent() throws {
        let url = UpdateRelease.endpoint
        for code in [403, 404, 429, 500] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil))
            #expect(throws: UpdateError.self) { try UpdateService.validate(response) }
        }
    }

    @MainActor @Test func automaticPreferencePersistsAndDefaultsOn() throws {
        let suite = "UpdateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let updater = UpdateController(dataDirectory: directory, defaults: defaults)
        #expect(updater.automatic)
        updater.automatic = false
        #expect(!UpdateController(dataDirectory: directory, defaults: defaults).automatic)
        #expect(UpdateRelease.downloadPage.absoluteString == "https://github.com/Cupcc/codex-signal/releases/latest")
    }

    @MainActor @Test func failedInstallationRemainsVisibleOnStartup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let updates = directory.appendingPathComponent("Updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "failed\n".write(to: updates.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        let updater = UpdateController(dataDirectory: directory)
        guard case .failed(let message) = updater.state else { Issue.record("Installation failure was lost"); return }
        #expect(message.contains("GitHub"))
        #expect(!updater.isBusy)
    }

    @Test func unsignedBundleIsRejected() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let executable = macOS.appendingPathComponent("CodexSignal")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = ["CFBundleIdentifier": "io.github.cupcc.CodexSignal", "CFBundleExecutable": "CodexSignal",
                     "CFBundleShortVersionString": "0.3.0", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: UpdateError.self) { try UpdateService.validateBundle(app, version: #require(AppVersion("0.3.0"))) }
    }
}

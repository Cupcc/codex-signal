import Foundation
import Testing
@testable import SignalApp

struct UpdateTests {
    private let hash = String(repeating: "a", count: 64)

    private func release(_ checksums: String) throws -> UpdateRelease { try UpdateRelease(checksums: Data(checksums.utf8)) }

    private func release(version: String = "0.3.0") throws -> UpdateRelease {
        try release("\(hash)  CodexSignal-\(version)-arm64.zip\n\(String(repeating: "b", count: 64))  CodexSignal-\(version)-arm64.dmg\n")
    }

    @Test func versionsCompareNumerically() throws {
        #expect(try #require(AppVersion("0.10.0")) > #require(AppVersion("v0.9.9")))
        #expect(AppVersion("v1.2.3") == AppVersion("1.2.3"))
        #expect(AppVersion("1.2.3-beta") == nil)
        #expect(AppVersion("1.2") == nil)
        #expect(AppVersion("1.2.-1") == nil)
        #expect(AppVersion("1.2.999999999999999999999999") == nil)
    }

    @Test func onlyNewerReleaseIsOffered() throws {
        let older = try #require(AppVersion("0.2.0"))
        let package = try #require(try release().update(after: older))
        #expect(package.version == AppVersion("0.3.0"))
        #expect(package.url.absoluteString == "https://github.com/Cupcc/codex-signal/releases/download/v0.3.0/CodexSignal-0.3.0-arm64.zip")
        #expect(package.sha256 == hash)
        #expect(try release().update(after: #require(AppVersion("0.3.0"))) == nil)
        #expect(try release().update(after: #require(AppVersion("0.4.0"))) == nil)
    }

    @Test func publishedChecksumFileIsRead() throws {
        // SHA256SUMS.txt of v0.8.0 as uploaded by script/release.sh.
        let published = try release("""
            91e95878571f522d605501b2e3def6844db9a0919f914b8e08eff7e40852c744  CodexSignal-0.8.0-arm64.zip
            172a41d9060ee97ef2964051d04f03504e107a9e50da5cc822b041b522963cbe  CodexSignal-0.8.0-arm64.dmg

            """)
        #expect(published.version == AppVersion("0.8.0"))
        #expect(published.sha256 == "91e95878571f522d605501b2e3def6844db9a0919f914b8e08eff7e40852c744")
        #expect(UpdateRelease.checksums.absoluteString == "https://github.com/Cupcc/codex-signal/releases/latest/download/SHA256SUMS.txt")
    }

    @Test func releasesWithoutOneVerifiableArm64PackageAreRejected() throws {
        for checksums in ["", "\(hash)  CodexSignal-0.3.0-universal.zip\n", "abc  CodexSignal-0.3.0-arm64.zip\n",
                          "\(hash)  CodexSignal-0.3-arm64.zip\n", "\(hash)  Other-0.3.0-arm64.zip\n",
                          "\(hash)  CodexSignal-0.3.0-arm64.zip\n\(hash)  CodexSignal-0.4.0-arm64.zip\n", "<!DOCTYPE html>"] {
            #expect(throws: UpdateError.self, "\(checksums)") { try release(checksums) }
        }
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
        let url = UpdateRelease.checksums
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

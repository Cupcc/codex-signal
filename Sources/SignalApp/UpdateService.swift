import CryptoKit
import Foundation

actor UpdateService {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func latest(after version: AppVersion) async throws -> UpdatePackage? {
        var request = URLRequest(url: UpdateRelease.checksums, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("CodexSignal/\(version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try UpdateRelease(checksums: data).update(after: version)
    }

    func download(_ package: UpdatePackage, into directory: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let request = URLRequest(url: package.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
            let (temporary, response) = try await session.download(for: request)
            defer { try? fm.removeItem(at: temporary) }
            try Self.validate(response)
            let archive = staging.appendingPathComponent("update.zip")
            try fm.moveItem(at: temporary, to: archive)
            try Self.verifyChecksum(archive, expected: package.sha256)
            let entries = try Self.run("/usr/bin/unzip", ["-Z1", archive.path])
                .split(whereSeparator: \.isNewline)
            guard !entries.isEmpty, entries.allSatisfy({ entry in
                entry.hasPrefix("CodexSignal.app/") && !entry.split(separator: "/").contains("..")
            }) else { throw UpdateError.invalidBundle }
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
            let app = staging.appendingPathComponent("CodexSignal.app")
            try Self.validateBundle(app, version: package.version)
            try fm.removeItem(at: archive)
            return app
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func prepareInstallation(staged: URL, destination: URL, version: AppVersion) throws -> URL {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app", !destination.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: destination.path), fm.isWritableFile(atPath: parent.path),
              destination.resolvingSymlinksInPath().path == destination.standardizedFileURL.path else {
            throw UpdateError.installationLocation
        }
        try Self.validateBundle(staged, version: version)
        let replacement = parent.appendingPathComponent(".CodexSignal-update-\(UUID().uuidString).app")
        do {
            try Self.run("/usr/bin/ditto", [staged.path, replacement.path])
            try Self.validateBundle(replacement, version: version)
            return replacement
        } catch {
            try? fm.removeItem(at: replacement)
            throw error
        }
    }

    static func validate(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.network(status) }
    }

    static func verifyChecksum(_ file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw UpdateError.checksum }
    }

    static func validateBundle(_ app: URL, version: AppVersion) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: info)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values["CFBundleIdentifier"] as? String == "io.github.cupcc.CodexSignal",
              values["CFBundleExecutable"] as? String == "CodexSignal",
              values["CFBundleShortVersionString"] as? String == version.description,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/CodexSignal").path),
              let minimum = values["LSMinimumSystemVersion"] as? String,
              minimum.compare(ProcessInfo.processInfo.operatingSystemVersionStringForUpdate, options: .numeric) != .orderedDescending else {
            throw UpdateError.invalidBundle
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension ProcessInfo {
    var operatingSystemVersionStringForUpdate: String {
        let version = operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

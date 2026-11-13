import Foundation

struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }

    var description: String { components.map(String.init).joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

/// The latest stable release, read from its `SHA256SUMS.txt` instead of the REST API.
/// The API allows 60 anonymous requests per hour per address, which shared networks
/// exhaust (HTTP 403); release downloads have no such limit.
struct UpdateRelease {
    static let downloadPage = URL(string: "https://github.com/Cupcc/codex-signal/releases/latest")!
    static let checksums = URL(string: "https://github.com/Cupcc/codex-signal/releases/latest/download/SHA256SUMS.txt")!

    let version: AppVersion
    let sha256: String

    /// Reads the arm64 ZIP's line of `shasum -a 256` output: `<hash>  CodexSignal-<version>-arm64.zip`.
    init(checksums data: Data) throws {
        let packages = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { line -> (version: AppVersion, sha256: String)? in
                let fields = line.split(separator: " ")
                guard fields.count == 2 else { return nil }
                let name = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
                guard name.hasPrefix("CodexSignal-"), name.hasSuffix("-arm64.zip"),
                      let version = AppVersion(String(name.dropFirst(12).dropLast(10))) else { return nil }
                return (version, fields[0].lowercased())
            }
        guard packages.count == 1, let package = packages.first, package.sha256.count == 64,
              package.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw UpdateError.invalidRelease }
        (version, sha256) = package
    }

    func update(after current: AppVersion) -> UpdatePackage? {
        guard version > current else { return nil }
        let url = URL(string: "https://github.com/Cupcc/codex-signal/releases/download/v\(version)/CodexSignal-\(version)-arm64.zip")!
        return UpdatePackage(version: version, url: url, sha256: sha256)
    }
}

struct UpdatePackage: Equatable {
    let version: AppVersion
    let url: URL
    let sha256: String
}

enum UpdateError: LocalizedError {
    case invalidRelease, network(Int), checksum, invalidBundle, installationLocation, commandFailed
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "发布包不支持自动更新，请前往 GitHub 手动下载。"
        case .network(let status): return "检查或下载失败（HTTP \(status)），请重试或前往 GitHub 下载。"
        case .checksum: return "下载校验失败，请重试或前往 GitHub 下载。"
        case .invalidBundle: return "新版应用验证失败，请前往 GitHub 手动下载。"
        case .installationLocation: return "请将应用移至可写的“应用程序”目录，再重试更新。"
        case .commandFailed: return "更新准备失败，请重试或前往 GitHub 下载。"
        }
    }
}

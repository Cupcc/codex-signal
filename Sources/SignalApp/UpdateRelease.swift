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

struct UpdateRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?
        enum CodingKeys: String, CodingKey {
            case name, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
    }

    static let downloadPage = URL(string: "https://github.com/Cupcc/codex-signal/releases/latest")!
    static let endpoint = URL(string: "https://api.github.com/repos/Cupcc/codex-signal/releases/latest")!

    func update(after current: AppVersion) throws -> UpdatePackage? {
        guard !draft, !prerelease else { return nil }
        guard let version = AppVersion(tagName) else { throw UpdateError.invalidRelease }
        guard version > current else { return nil }
        let name = "CodexSignal-\(version)-arm64.zip"
        guard let asset = assets.first(where: { $0.name == name }),
              asset.browserDownloadURL.scheme == "https",
              asset.browserDownloadURL.host == "github.com",
              asset.browserDownloadURL.user == nil, asset.browserDownloadURL.password == nil,
              asset.browserDownloadURL.port == nil,
              asset.browserDownloadURL.path == "/Cupcc/codex-signal/releases/download/\(tagName)/\(name)",
              let digest = asset.digest, digest.hasPrefix("sha256:") else { throw UpdateError.invalidRelease }
        let hash = String(digest.dropFirst(7)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw UpdateError.invalidRelease }
        return UpdatePackage(version: version, url: asset.browserDownloadURL, sha256: hash)
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

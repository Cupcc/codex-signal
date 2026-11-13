import AppKit

enum AppProduct {
    static let name = "Codex Signal"
    static let summary = "屏幕顶部的 Codex 与 Claude Code 会话伙伴"
    static let homepage = URL(string: "https://github.com/Cupcc/codex-signal")!
    static let feedback = homepage.appendingPathComponent("issues")

    static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }

    static let icon: NSImage? = {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()

    @MainActor static func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let credits = NSMutableAttributedString(string: summary + "\n", attributes: attributes)
        var links: [(String, URL)] = [("项目主页", homepage), ("问题反馈", feedback)]
        if let licenses = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty", isDirectory: true),
           FileManager.default.fileExists(atPath: licenses.path) {
            links.append(("第三方许可", licenses))
        }
        for (index, link) in links.enumerated() {
            if index > 0 { credits.append(NSAttributedString(string: " · ", attributes: attributes)) }
            var linkedAttributes = attributes
            linkedAttributes[.link] = link.1
            linkedAttributes[.foregroundColor] = NSColor.linkColor
            credits.append(NSAttributedString(string: link.0, attributes: linkedAttributes))
        }
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: name,
            .credits: credits
        ]
        if let icon { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}

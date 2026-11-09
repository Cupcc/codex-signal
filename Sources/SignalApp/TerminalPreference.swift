enum TerminalPreference: String, Codable, CaseIterable, Identifiable {
    case automatic = "auto"
    case terminal = "com.apple.Terminal"
    case iTerm2 = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"

    var id: String { rawValue }
    var bundleID: String? { self == .automatic ? nil : rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .terminal: return "Terminal"
        case .iTerm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }
}

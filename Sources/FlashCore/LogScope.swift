import Foundation

/// Which lines the Logs window shows: every engine, one engine, or the
/// audit trail (secrets, keychain dialogs, agent hooks, ssh).
public enum LogScope: Hashable {
    case all
    case audit
    case tag(String)

    public static let auditTags: Set<String> = ["agent", "auth", "inbox", "ssh"]

    public func includes(_ tag: String?) -> Bool {
        switch self {
        case .all: return true
        case .audit: return tag.map(Self.auditTags.contains) ?? false
        case .tag(let wanted): return tag == wanted
        }
    }

    /// `flash://logs?view=audit`, `flash://logs?tag=agent`; nil when the
    /// URL names no scope (then the window keeps the one it had).
    public init?(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces).lowercased()
        }
        if let view = value("view") {
            switch view {
            case "audit": self = .audit
            case "all": self = .all
            default: return nil
            }
        } else if let tag = value("tag"), !tag.isEmpty {
            self = .tag(tag)
        } else {
            return nil
        }
    }
}

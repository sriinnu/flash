import Foundation

/// Who did it. Only `flash-notify` can tell (it walks the process tree of
/// whatever called it); folder watching alone sees *what* changed, never who.
enum Actor: Equatable {
    case agent(String)   // "Claude", "codex", …
    case you(String?)    // terminal / app it came from, when known
    case unknown

    /// From the `actor=` / `agent=` / `app=` fields flash-notify writes.
    init(fields: [String: String]) {
        let app = fields["app"].flatMap { $0.isEmpty ? nil : $0 }
        switch fields["actor"] {
        case "agent":
            let name = fields["agent"] ?? ""
            self = .agent(name.isEmpty ? (app ?? "Agent") : name)
        case "you":
            self = .you(app)
        default:
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .agent(let name): return name.prefix(1).uppercased() + name.dropFirst()
        case .you(let app): return app.map { "You · \($0)" } ?? "You"
        case .unknown: return ""
        }
    }

    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}

struct ActivityEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case commit, push, prompt
    }

    let id = UUID()
    let kind: Kind
    let repo: String?      // repo folder name
    let ref: String?       // branch, or remote/branch for pushes
    let summary: String    // commit subject, "Pushed …", prompt kind
    let sha: String?       // full sha — what hook attributions match on
    let date: Date
    var actor: Actor
}

/// The menu-bar panel's "what just happened" list. Oversight, not alerting:
/// nothing here ever flashes. In-memory, newest first, capped.
@MainActor
final class ActivityLog: ObservableObject {

    static let shared = ActivityLog()

    @Published private(set) var events: [ActivityEvent] = []

    private let capacity = 50

    /// Hook attributions that arrived before FSEvents reported the commit
    /// (the post-commit hook usually wins that race by a few hundred ms).
    private var pendingActors: [String: (actor: Actor, at: Date)] = [:]

    func record(_ event: ActivityEvent) {
        var event = event
        if let sha = event.sha, let pending = pendingActors.removeValue(forKey: sha) {
            event.actor = pending.actor
        }
        events.insert(event, at: 0)
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
    }

    /// A hook saying "that sha was me / that agent". Patches the entry if it's
    /// already listed, otherwise parks it for `record` to pick up.
    func attribute(sha: String, actor: Actor) {
        if let i = events.firstIndex(where: { $0.sha == sha && $0.actor == .unknown }) {
            events[i].actor = actor
            return
        }
        let cutoff = Date().addingTimeInterval(-60)
        pendingActors = pendingActors.filter { $0.value.at > cutoff }
        pendingActors[sha] = (actor, Date())
    }

    func clear() {
        events.removeAll()
    }
}

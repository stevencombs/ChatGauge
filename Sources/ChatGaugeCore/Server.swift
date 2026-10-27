import Foundation

/// A per-user LaunchAgent that runs `ollama serve`, read from its plist.
public struct OllamaAgent: Equatable, Sendable {
    public var label: String
    public var plistPath: String
    /// OLLAMA_MODELS from EnvironmentVariables, or from an `OLLAMA_MODELS=…` in a shell command line.
    public var modelsPath: String?
    public var runsOllama: Bool

    public init(label: String, plistPath: String, modelsPath: String?, runsOllama: Bool) {
        self.label = label
        self.plistPath = plistPath
        self.modelsPath = modelsPath
        self.runsOllama = runsOllama
    }

    /// The shared, neutral agent on the maker's Macs. Used if present; never restarted with -k by ChatGauge.
    public static let sharedLabel = "com.retrocombs.ollama-lexar"
    /// The agent ChatGauge would offer to install (only after the user approves).
    public static let ownLabel = "com.retrocombs.chatgauge.ollama"

    public static func parse(plist data: Data, path: String) -> OllamaAgent? {
        guard let o = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = o["Label"] as? String else { return nil }
        var args = (o["ProgramArguments"] as? [String]) ?? []
        if let p = o["Program"] as? String { args.insert(p, at: 0) }
        let joined = args.joined(separator: " ")
        let runs = joined.contains("ollama") && joined.contains("serve")
        var models = (o["EnvironmentVariables"] as? [String: String])?["OLLAMA_MODELS"]
        if models == nil, let r = joined.range(of: "OLLAMA_MODELS=") {
            let rest = joined[r.upperBound...]
            var value = ""
            var quote: Character? = nil
            for ch in rest {
                if value.isEmpty && quote == nil && (ch == "\"" || ch == "'") { quote = ch; continue }
                if let q = quote, ch == q { break }
                if quote == nil && (ch == " " || ch == ";") { break }
                value.append(ch)
            }
            if !value.isEmpty { models = value }
        }
        return OllamaAgent(label: label, plistPath: path, modelsPath: models, runsOllama: runs)
    }

    /// Every agent in ~/Library/LaunchAgents that runs `ollama serve`. The shared one sorts first.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser, fm: FileManager = .default) -> [OllamaAgent] {
        let dir = home.appendingPathComponent("Library/LaunchAgents")
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let agents = files.filter { $0.hasSuffix(".plist") }.compactMap { f -> OllamaAgent? in
            let p = dir.appendingPathComponent(f).path
            guard let d = fm.contents(atPath: p), let a = parse(plist: d, path: p), a.runsOllama else { return nil }
            return a
        }
        return agents.sorted { a, b in
            if (a.label == sharedLabel) != (b.label == sharedLabel) { return a.label == sharedLabel }
            return a.label < b.label
        }
    }
}

/// What to do to get a server that answers. Pure, so it is tested; the app runs the command it returns.
public enum ServerAction: Equatable, Sendable {
    /// /api/version answered.
    case useRunning
    /// Start a loaded agent: `launchctl kickstart gui/<uid>/<label>` (never `-k`).
    case kickstart(label: String)
    /// Load an agent that isn't loaded: `launchctl bootstrap gui/<uid> <plist>`.
    case bootstrap(label: String, plist: String)
    /// The models drive isn't connected; wait for it to mount.
    case waitForDrive(volume: String)
    /// No agent serves this folder; offer to install ChatGauge's own (only with the user's OK).
    case offerOwnAgent
}

public enum ServerPlan {
    public static func decide(answering: Bool, availability: ModelsAvailability, agents: [OllamaAgent],
                              loadedLabels: Set<String>, modelsPath: String) -> ServerAction {
        if answering { return .useRunning }
        if case .driveMissing(let v) = availability { return .waitForDrive(volume: v) }
        let norm = (modelsPath as NSString).standardizingPath
        let match = agents.first { a in
            guard let m = a.modelsPath else { return false }
            return (m as NSString).standardizingPath == norm
        } ?? agents.first { $0.label == OllamaAgent.sharedLabel }
        guard let a = match else { return .offerOwnAgent }
        return loadedLabels.contains(a.label) ? .kickstart(label: a.label) : .bootstrap(label: a.label, plist: a.plistPath)
    }

    /// The launchctl arguments for an action (nil when there is nothing to run).
    /// By design this never contains `-k`: ChatGauge never kills a server another app may be using.
    public static func launchctlArguments(_ action: ServerAction, uid: UInt32) -> [String]? {
        switch action {
        case .kickstart(let label): return ["kickstart", "gui/\(uid)/\(label)"]
        case .bootstrap(_, let plist): return ["bootstrap", "gui/\(uid)", plist]
        default: return nil
        }
    }
}

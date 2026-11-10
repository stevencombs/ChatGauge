import Foundation

/// One entry in ChatGauge's known-model list (sizes and one-line blurbs for menus and install).
public struct CatalogEntry: Equatable, Sendable, Identifiable {
    public var name: String
    public var bytes: Int64
    public var blurb: String
    public var vision: Bool
    public var uncensored: Bool
    public var id: String { name }

    public init(name: String, bytes: Int64, blurb: String, vision: Bool = true, uncensored: Bool = false) {
        self.name = name
        self.bytes = bytes
        self.blurb = blurb
        self.vision = vision
        self.uncensored = uncensored
    }

    public var option: ModelOption { ModelOption(name: name, bytes: bytes, note: blurb) }
}

/// Known chat models and their one-line descriptions. Installed models not listed still appear in menus
/// with a plain "vision" / "text" blurb from Ollama's capabilities (or the name heuristic).
public enum ModelCatalog {
    public static let standard: [CatalogEntry] = [
        CatalogEntry(name: "qwen2.5vl:3b", bytes: 3_200_000_000, blurb: "Small and quick (3.2 GB)"),
        CatalogEntry(name: "qwen2.5vl:7b", bytes: 6_000_000_000, blurb: "Standard vision, fast (6 GB)"),
        CatalogEntry(name: "qwen2.5vl:32b", bytes: 21_000_000_000, blurb: "Slower, more detailed (21 GB)"),
    ]

    public static let uncensored: [CatalogEntry] = [
        CatalogEntry(name: "huihui_ai/qwen2.5-vl-abliterated:7b", bytes: 6_000_000_000,
                     blurb: "Uncensored, vision, same speed as standard (6 GB)", uncensored: true),
        CatalogEntry(name: "huihui_ai/qwen3-vl-abliterated:8b-instruct", bytes: 6_100_000_000,
                     blurb: "Uncensored, newer Qwen3, better at images (6.1 GB)", uncensored: true),
    ]

    public static var all: [CatalogEntry] { standard + uncensored }

    public static func entry(_ name: String) -> CatalogEntry? {
        all.first { $0.name == name }
    }

    /// One-line description for menus: catalog blurb, else "vision" / "text" from the installed model.
    public static func description(for info: ModelInfo) -> String {
        if let e = entry(info.name) { return e.blurb }
        return info.supportsVision ? "vision" : "text"
    }

    public static func description(name: String, info: ModelInfo? = nil) -> String {
        if let e = entry(name) { return e.blurb }
        if let info { return description(for: info) }
        let n = name.lowercased()
        let vision = ["vl", "llava", "vision", "gemma3", "minicpm-v", "moondream"].contains { n.contains($0) }
        return vision ? "vision" : "text"
    }

    /// Lines shown before a pull (dry run). Uses the live server URL when given.
    public static func pullPlan(model: String, serverURL: String) -> [String] {
        let host = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return ["POST \(host)/api/pull {\"model\":\"\(model)\"}"]
    }

    /// Menu rows: installed first (catalog order, then others A–Z), then not-installed catalog entries.
    public static func menuRows(installed: [ModelInfo]) -> [ModelMenuRow] {
        let byName = Dictionary(uniqueKeysWithValues: installed.map { ($0.name, $0) })
        var rows: [ModelMenuRow] = []
        var seen = Set<String>()
        for e in all {
            if let info = byName[e.name] {
                rows.append(.installed(info, blurb: e.blurb))
                seen.insert(e.name)
            }
        }
        for info in installed.sorted(by: { $0.name < $1.name }) where !seen.contains(info.name) {
            rows.append(.installed(info, blurb: description(for: info)))
            seen.insert(info.name)
        }
        for e in all where !seen.contains(e.name) {
            rows.append(.notInstalled(e))
        }
        return rows
    }
}

public enum ModelMenuRow: Equatable, Sendable, Identifiable {
    case installed(ModelInfo, blurb: String)
    case notInstalled(CatalogEntry)

    public var id: String {
        switch self {
        case .installed(let m, _): return m.name
        case .notInstalled(let e): return e.name
        }
    }

    public var name: String {
        switch self {
        case .installed(let m, _): return m.name
        case .notInstalled(let e): return e.name
        }
    }

    public var blurb: String {
        switch self {
        case .installed(_, let b): return b
        case .notInstalled(let e): return e.blurb
        }
    }

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    public var supportsVision: Bool {
        switch self {
        case .installed(let m, _): return m.supportsVision
        case .notInstalled(let e): return e.vision
        }
    }
}


/// Pure rules for removing a model (tested). The UI only shows these and runs after a click.
public enum ModelRemoval {
    public enum Block: Equatable, Sendable {
        case streaming
        case loadedByOther
        case serverDown
    }

    public struct Plan: Equatable, Sendable {
        public var model: String
        public var bytes: Int64
        public var unloadFirst: Bool
        public var chatsUsing: Int
        public var lines: [String]
        public var warning: String?
        public var block: Block?

        public var freeLabel: String {
            ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
        }
    }

    /// What Remove will do. `mine` = models ChatGauge itself loaded (LoadLedger.mine).
    public static func plan(model: String, size: Int64, loaded: Set<String>, mine: Set<String>,
                            streamingModel: String?, chatCount: Int, serverURL: String) -> Plan {
        var block: Block? = nil
        if streamingModel == model { block = .streaming }
        else if loaded.contains(model) && !mine.contains(model) { block = .loadedByOther }
        let unload = block == nil && loaded.contains(model) && mine.contains(model)
        var lines: [String] = []
        if unload { lines.append("Unload \(model) (ChatGauge loaded it)") }
        let host = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        lines.append("DELETE \(host)/api/delete {\"model\":\"\(model)\"}")
        var warning: String? = nil
        if chatCount > 0 {
            warning = chatCount == 1
                ? "1 saved chat uses this model; it will fall back to the default when opened."
                : "\(chatCount) saved chats use this model; they will fall back to the default when opened."
        }
        if block == .streaming { warning = "This model is replying right now. Stop the reply first." }
        if block == .loadedByOther { warning = "Another app loaded this model; ChatGauge won't remove it while it's loaded." }
        return Plan(model: model, bytes: size, unloadFirst: unload, chatsUsing: chatCount, lines: lines, warning: warning, block: block)
    }
}

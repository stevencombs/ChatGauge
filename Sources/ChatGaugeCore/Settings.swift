import Foundation

/// Where Ollama keeps its models. ChatGauge never moves them; it only points the server at the folder.
public enum ModelsLocationKind: String, Codable, Sendable, CaseIterable {
    /// Ollama's default on this Mac (`~/.ollama/models`) or another folder on the internal disk.
    case local
    /// A folder on an external drive (`/Volumes/<name>/…`).
    case external
}

/// The model to chat with. `automatic` picks one by RAM tier.
public enum ModelChoice: Codable, Equatable, Sendable {
    case automatic
    case named(String)

    public var name: String? {
        if case .named(let n) = self { return n }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case mode, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = (try? c.decode(String.self, forKey: .mode)) ?? "automatic"
        if mode == "named", let n = try? c.decode(String.self, forKey: .name), !n.isEmpty {
            self = .named(n)
        } else {
            self = .automatic
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try c.encode("automatic", forKey: .mode)
        case .named(let n):
            try c.encode("named", forKey: .mode)
            try c.encode(n, forKey: .name)
        }
    }
}

public enum ChatFileFormat: String, Codable, Sendable, CaseIterable {
    case markdown, json
    public var fileExtension: String { self == .markdown ? "md" : "json" }
    public var title: String { self == .markdown ? "Markdown (.md)" : "JSON (.json)" }
}

public enum UpdateMode: String, Codable, Sendable, CaseIterable {
    /// Post a notification and show the popover row; nothing installs until you click Update.
    case notify
    /// Install when nothing is generating and DaVinci Resolve isn't open, then say what changed.
    case autoWhenIdle

    public var title: String {
        switch self {
        case .notify: return "Notify me and I'll update"
        case .autoWhenIdle: return "Install automatically when idle"
        }
    }
}

/// What the menu bar item shows next to the mark.
public enum MenuBarText: String, Codable, Sendable, CaseIterable {
    case none, modelName, status
    public var title: String {
        switch self {
        case .none: return "Icon only"
        case .modelName: return "Model name"
        case .status: return "Status (Ready, Loading…)"
        }
    }
}

/// A global shortcut stored as a Carbon key code plus Carbon modifier flags.
public struct HotKey: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    // Carbon modifier bits (Events.h)
    public static let cmdKey: UInt32 = 1 << 8
    public static let shiftKey: UInt32 = 1 << 9
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 13

    public init(enabled: Bool = true, keyCode: UInt32, carbonModifiers: UInt32) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// ⌃⌥C (taken over from ClipGauge, which is retired). kVK_ANSI_C = 8.
    public static let standard = HotKey(keyCode: 8, carbonModifiers: controlKey | optionKey)

    /// At least one of ⌃ ⌥ ⌘ is required so a plain letter never becomes global.
    public var isValid: Bool { carbonModifiers & (Self.cmdKey | Self.optionKey | Self.controlKey) != 0 }

    public var display: String {
        var s = ""
        if carbonModifiers & Self.controlKey != 0 { s += "⌃" }
        if carbonModifiers & Self.optionKey != 0 { s += "⌥" }
        if carbonModifiers & Self.shiftKey != 0 { s += "⇧" }
        if carbonModifiers & Self.cmdKey != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "key \(keyCode)")
    }

    /// ANSI key codes → labels (enough for letters, digits and a few keys).
    public static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M", 49: "Space", 36: "Return",
    ]
}

/// Per-Mac preferences, stored as `settings.json` in Application Support. Export/Import moves them by hand.
/// Every field decodes with a default so older or hand-edited files never fail to load.
public struct ChatSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    // Model & Server
    public var modelsLocation: ModelsLocationKind = .local
    /// nil = Ollama's default (`~/.ollama/models`) when local; required when external.
    public var modelsPath: String? = nil
    public var model: ModelChoice = .automatic
    /// Keep the model in memory while ChatGauge is open (keep_alive -1). Off on the Air tier by default.
    public var keepLoaded: Bool? = nil
    /// Switch to a smaller installed model when memory is low, and say so.
    public var lowMemoryFallback: Bool = true
    /// One note per DaVinci Resolve session.
    public var warnWhenResolveOpen: Bool = true
    /// Loopback only; anything else is refused.
    public var serverURL: String = "http://127.0.0.1:11434"
    /// Force a tier instead of detecting it from RAM ("air" / "pro").
    public var tierOverride: String? = nil

    // Chat
    public var chatsFolder: String? = nil              // nil = ~/Library/Application Support/ChatGauge/Chats
    public var chatFormat: ChatFileFormat = .markdown
    public var saveChats: Bool = true
    public var hotKey: HotKey = .standard
    public var sendWithReturn: Bool = true

    // Menu bar
    public var menuBarText: MenuBarText = .none
    public var showStatusDot: Bool = true
    public var launchAtLogin: Bool = false

    // Updates
    public var checkForUpdates: Bool = true
    public var updateMode: UpdateMode = .notify
    public var checkTools: Bool = true
    public var checkModels: Bool = true

    // Voice
    public var voiceEnabled: Bool = true
    /// nil = by tier (Pro large-v3-turbo, Air base.en).
    public var whisperModel: String? = nil

    public var modifiedAt: Date = Date(timeIntervalSince1970: 0)

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case modelsLocation, modelsPath, model, keepLoaded, lowMemoryFallback, warnWhenResolveOpen, serverURL,
             tierOverride, chatsFolder, chatFormat, saveChats, hotKey, sendWithReturn, menuBarText, showStatusDot,
             launchAtLogin, checkForUpdates, updateMode, checkTools, checkModels, voiceEnabled, whisperModel, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? def }
        modelsLocation = v(.modelsLocation, d.modelsLocation)
        modelsPath = v(.modelsPath, d.modelsPath as String?)
        model = v(.model, d.model)
        keepLoaded = v(.keepLoaded, d.keepLoaded as Bool?)
        lowMemoryFallback = v(.lowMemoryFallback, d.lowMemoryFallback)
        warnWhenResolveOpen = v(.warnWhenResolveOpen, d.warnWhenResolveOpen)
        serverURL = v(.serverURL, d.serverURL)
        tierOverride = v(.tierOverride, d.tierOverride as String?)
        chatsFolder = v(.chatsFolder, d.chatsFolder as String?)
        chatFormat = v(.chatFormat, d.chatFormat)
        saveChats = v(.saveChats, d.saveChats)
        hotKey = v(.hotKey, d.hotKey)
        sendWithReturn = v(.sendWithReturn, d.sendWithReturn)
        menuBarText = v(.menuBarText, d.menuBarText)
        showStatusDot = v(.showStatusDot, d.showStatusDot)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        checkForUpdates = v(.checkForUpdates, d.checkForUpdates)
        updateMode = v(.updateMode, d.updateMode)
        checkTools = v(.checkTools, d.checkTools)
        checkModels = v(.checkModels, d.checkModels)
        voiceEnabled = v(.voiceEnabled, d.voiceEnabled)
        whisperModel = v(.whisperModel, d.whisperModel as String?)
        modifiedAt = v(.modifiedAt, d.modifiedAt)
    }

    /// Keep-loaded in effect: the explicit choice, else on for the Pro tier and off for the Air.
    public func keepsLoaded(tier: RAMTier) -> Bool { keepLoaded ?? (tier == .pro) }

    /// Equal ignoring `modifiedAt`.
    public func sameContent(as other: ChatSettings) -> Bool {
        var a = self, b = other
        a.modifiedAt = .init(timeIntervalSince1970: 0)
        b.modifiedAt = a.modifiedAt
        return a == b
    }
}

/// The settings file and the Export/Import envelope. Preferences only: no chats, no instructions.
public struct SettingsEnvelope: Codable, Equatable, Sendable {
    public var app: String
    public var schema: Int
    public var settings: ChatSettings

    public init(settings: ChatSettings) {
        app = "ChatGauge"
        schema = ChatSettings.schemaVersion
        self.settings = settings
    }
}

public enum SettingsFileError: Error, Equatable, CustomStringConvertible {
    case notChatGauge(String)
    case newerSchema(Int)
    case unreadable

    public var description: String {
        switch self {
        case .notChatGauge(let a): return "This file is for \(a), not ChatGauge."
        case .newerSchema(let s): return "This file was written by a newer ChatGauge (schema \(s)). Update ChatGauge first."
        case .unreadable: return "This isn't a ChatGauge settings file."
        }
    }
}

public enum SettingsFile {
    public static let fileName = "settings.json"

    public static func encode(_ s: ChatSettings) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(SettingsEnvelope(settings: s))
    }

    public static func decode(_ data: Data) throws -> ChatSettings {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let env = try? d.decode(SettingsEnvelope.self, from: data) else {
            // A bare settings object (no envelope) is accepted too.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["app"] == nil,
               obj["settings"] == nil, let s = try? d.decode(ChatSettings.self, from: data) { return s }
            throw SettingsFileError.unreadable
        }
        guard env.app == "ChatGauge" else { throw SettingsFileError.notChatGauge(env.app) }
        guard env.schema <= ChatSettings.schemaVersion else { throw SettingsFileError.newerSchema(env.schema) }
        return env.settings
    }

    /// Loads settings, or defaults when the file is missing or broken (a broken file is kept as `.bad`).
    public static func load(from url: URL, fm: FileManager = .default) -> ChatSettings {
        guard let data = fm.contents(atPath: url.path) else { return ChatSettings() }
        if let s = try? decode(data) { return s }
        let bad = url.deletingPathExtension().appendingPathExtension("bad.json")
        try? fm.removeItem(at: bad)
        try? fm.copyItem(at: url, to: bad)
        return ChatSettings()
    }

    public static func save(_ s: ChatSettings, to url: URL, fm: FileManager = .default) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(s).write(to: url, options: .atomic)
    }
}

/// Standard folders under ~/Library/Application Support/ChatGauge.
public enum AppPaths {
    public static func support(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ChatGauge", isDirectory: true)
    }
    public static func settingsFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        support(home: home).appendingPathComponent(SettingsFile.fileName)
    }
    public static func instructionsFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        support(home: home).appendingPathComponent("instructions.json")
    }
    public static func defaultChats(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        support(home: home).appendingPathComponent("Chats", isDirectory: true)
    }
    public static func stateFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        support(home: home).appendingPathComponent("state.json")
    }

    /// The chats folder in effect.
    public static func chats(_ s: ChatSettings, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let p = s.chatsFolder, !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true) }
        return defaultChats(home: home)
    }
}

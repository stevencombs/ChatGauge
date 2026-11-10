import CryptoKit
import Foundation

// First-run setup: the pure parts (what to recommend, what to skip, what a step will run), so they are tested.
// The wizard window (ChatGauge/SetupWizard.swift) only shows these and runs a step after a click.

public enum SetupStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, check, location, tools, models, server, test, done
    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .check: return "Check this Mac"
        case .location: return "Models folder"
        case .tools: return "Install tools"
        case .models: return "Download models"
        case .server: return "Ollama server"
        case .test: return "Test"
        case .done: return "Done"
        }
    }

    public var symbol: String {
        switch self {
        case .welcome: return "hand.wave"
        case .check: return "checklist"
        case .location: return "externaldrive"
        case .tools: return "wrench.and.screwdriver"
        case .models: return "shippingbox"
        case .server: return "bolt.horizontal.circle"
        case .test: return "checkmark.bubble"
        case .done: return "flag.checkered"
        }
    }

    /// Steps that are skipped when already satisfied (Welcome, Check, Test and Done always show).
    public var skippable: Bool { [.location, .tools, .models, .server].contains(self) }
}

// MARK: - Model recommendation by RAM

public struct ModelOption: Equatable, Sendable, Identifiable {
    public var name: String
    public var bytes: Int64
    public var note: String
    public var id: String { name }
    public init(name: String, bytes: Int64, note: String) {
        self.name = name
        self.bytes = bytes
        self.note = note
    }
}

public enum SetupCatalog {
    /// Download sizes from the Ollama library (rounded up a little).
    public static let chat: [String: ModelOption] = Dictionary(uniqueKeysWithValues: ModelCatalog.standard.map { ($0.name, $0.option) })
    /// Optional uncensored vision models (Install only; never auto-selected).
    public static let uncensored: [String: ModelOption] = Dictionary(uniqueKeysWithValues: ModelCatalog.uncensored.map { ($0.name, $0.option) })
    /// whisper.cpp ggml model sizes (exact file sizes on Hugging Face, rounded).
    public static let whisper: [String: ModelOption] = [
        "tiny.en": ModelOption(name: "tiny.en", bytes: 77_700_000, note: "Fastest, least accurate"),
        "base.en": ModelOption(name: "base.en", bytes: 148_000_000, note: "Quick dictation in English"),
        "small.en": ModelOption(name: "small.en", bytes: 488_000_000, note: "More accurate English"),
        "medium.en": ModelOption(name: "medium.en", bytes: 1_530_000_000, note: "Accurate, slower"),
        "large-v3-turbo": ModelOption(name: "large-v3-turbo", bytes: 1_625_000_000, note: "Best accuracy at good speed, any language"),
    ]
    /// Homebrew installs, roughly (ffmpeg brings most of it).
    public static let toolsBytes: Int64 = 1_000_000_000
}

public enum RAMBand: String, Sendable {
    case under32, from32to47, atLeast48

    public init(gb: Double) {
        if gb < 32 { self = .under32 } else if gb < 48 { self = .from32to47 } else { self = .atLeast48 }
    }

    public var title: String {
        switch self {
        case .under32: return "under 32 GB"
        case .from32to47: return "32–47 GB"
        case .atLeast48: return "48 GB or more"
        }
    }
}

public struct SetupRecommendation: Equatable, Sendable {
    public var band: RAMBand
    /// Chat models offered, the default first.
    public var chat: [ModelOption]
    public var defaultChat: String
    /// Offered but unticked by default.
    public var optionalChat: [String]
    public var whisper: ModelOption

    /// under 32 GB: qwen2.5vl:3b or 7b (3b below 16 GB) + base.en; 32–47 GB: 7b + large-v3-turbo;
    /// 48 GB or more: 7b by default, 32b optional + large-v3-turbo.
    public static func forRAM(gb: Double) -> SetupRecommendation {
        let c = SetupCatalog.chat, w = SetupCatalog.whisper
        switch RAMBand(gb: gb) {
        case .under32:
            let small = gb < 16
            return SetupRecommendation(band: .under32, chat: small ? [c["qwen2.5vl:3b"]!, c["qwen2.5vl:7b"]!] : [c["qwen2.5vl:7b"]!, c["qwen2.5vl:3b"]!],
                                       defaultChat: small ? "qwen2.5vl:3b" : "qwen2.5vl:7b", optionalChat: [], whisper: w["base.en"]!)
        case .from32to47:
            return SetupRecommendation(band: .from32to47, chat: [c["qwen2.5vl:7b"]!], defaultChat: "qwen2.5vl:7b",
                                       optionalChat: [], whisper: w["large-v3-turbo"]!)
        case .atLeast48:
            return SetupRecommendation(band: .atLeast48, chat: [c["qwen2.5vl:7b"]!, c["qwen2.5vl:32b"]!], defaultChat: "qwen2.5vl:7b",
                                       optionalChat: ["qwen2.5vl:32b"], whisper: w["large-v3-turbo"]!)
        }
    }

    public static func forRAM(bytes: UInt64) -> SetupRecommendation { forRAM(gb: Double(bytes) / 1_073_741_824) }

    /// Space for the chosen models (+10% for Ollama's partial files).
    public static func neededBytes(chat: [String], whisper: String?) -> Int64 {
        let c = chat.compactMap { SetupCatalog.chat[$0]?.bytes ?? SetupCatalog.uncensored[$0]?.bytes }.reduce(0, +)
        let w = whisper.flatMap { SetupCatalog.whisper[$0]?.bytes } ?? 0
        return (c + w) + (c + w) / 10
    }
}

// MARK: - Volumes

public struct VolumeInfo: Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    /// e.g. "APFS", "ExFAT", "MS-DOS (FAT32)", "Mac OS Extended (Journaled)".
    public var format: String
    public var availableBytes: Int64?
    public var totalBytes: Int64?
    public var isInternal: Bool
    public var isReadOnly: Bool
    public var isNetwork: Bool
    public var id: String { path }

    public init(path: String, name: String, format: String, availableBytes: Int64?, totalBytes: Int64? = nil,
                isInternal: Bool, isReadOnly: Bool = false, isNetwork: Bool = false) {
        self.path = path
        self.name = name
        self.format = format
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.isNetwork = isNetwork
    }
}

public enum VolumeIssue: Equatable, Sendable {
    case readOnly
    case notWritable
    case notEnoughSpace(need: Int64, have: Int64)
    case unknownSpace
    case fatFormat(String)
    case network
    case notADirectory

    public var isError: Bool {
        switch self {
        case .readOnly, .notWritable, .notEnoughSpace, .notADirectory: return true
        case .unknownSpace, .fatFormat, .network: return false
        }
    }

    public var message: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        switch self {
        case .readOnly: return "This drive is read-only."
        case .notWritable: return "ChatGauge can't write to this folder."
        case .notEnoughSpace(let need, let have):
            return "Not enough room: the models need about \(f.string(fromByteCount: need)), and \(f.string(fromByteCount: have)) is free."
        case .unknownSpace: return "macOS didn't report the free space on this drive; check it has room before downloading."
        case .fatFormat(let fmt):
            return "\(fmt) drive: macOS writes hidden \u{201C}._\u{201D} files here (ChatGauge and Ollama ignore them), and symlinks don't work, so the server must be told the folder with OLLAMA_MODELS (ChatGauge's server does this). APFS is better if you can reformat."
        case .network: return "Network drive: models load slowly and the server stops when the share disconnects."
        case .notADirectory: return "That path is a file, not a folder."
        }
    }
}

public enum VolumeCheck {
    public static func isFATFamily(_ format: String) -> Bool {
        let f = format.lowercased()
        return f.contains("exfat") || f.contains("fat32") || f.contains("ms-dos") || f.contains("msdos") || f == "fat"
    }

    /// Problems with putting `needBytes` of models in a folder on `volume`. `writable` is nil when not probed yet.
    public static func evaluate(_ volume: VolumeInfo, needBytes: Int64, writable: Bool?, isFile: Bool = false) -> [VolumeIssue] {
        var out: [VolumeIssue] = []
        if isFile { out.append(.notADirectory) }
        if volume.isReadOnly { out.append(.readOnly) } else if writable == false { out.append(.notWritable) }
        if let have = volume.availableBytes, have > 0 {
            if have < needBytes { out.append(.notEnoughSpace(need: needBytes, have: have)) }
        } else {
            out.append(.unknownSpace)
        }
        if isFATFamily(volume.format) { out.append(.fatFormat(volume.format)) }
        if volume.isNetwork { out.append(.network) }
        return out
    }

    public static func canUse(_ issues: [VolumeIssue]) -> Bool { !issues.contains(where: \.isError) }

    /// The folder offered on a volume: Ollama's standard folder on this Mac, `<drive>/ChatGauge/models` elsewhere.
    public static func suggestedFolder(on volume: VolumeInfo, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if volume.path == "/" { return ModelsLocation.defaultLocal(home: home) }
        return (volume.path as NSString).appendingPathComponent("ChatGauge/models")
    }

    /// The mounted volume a path lives on (longest matching mount point).
    public static func volume(for path: String, in volumes: [VolumeInfo]) -> VolumeInfo? {
        let p = (path as NSString).standardizingPath
        return volumes.filter { v in v.path == "/" || p == v.path || p.hasPrefix(v.path.hasSuffix("/") ? v.path : v.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
}

// MARK: - Tools

public enum SetupTool: String, CaseIterable, Sendable, Identifiable {
    case ollama, whisper, ffmpeg
    public var id: String { rawValue }
    /// The Homebrew formula.
    public var formula: String {
        switch self {
        case .ollama: return "ollama"
        case .whisper: return "whisper-cpp"
        case .ffmpeg: return "ffmpeg"
        }
    }
    public var executable: String {
        switch self {
        case .ollama: return "ollama"
        case .whisper: return "whisper-cli"
        case .ffmpeg: return "ffmpeg"
        }
    }
    public var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .whisper: return "whisper.cpp"
        case .ffmpeg: return "ffmpeg"
        }
    }
    public var purpose: String {
        switch self {
        case .ollama: return "Runs the chat model"
        case .whisper: return "Voice input (optional)"
        case .ffmpeg: return "Converts recordings for voice input (optional)"
        }
    }
    /// Ollama is required; the voice tools are optional.
    public var required: Bool { self == .ollama }
}

public enum ToolVersionParser {
    /// `brew --version` -> "4.6.3".
    public static func brew(_ out: String) -> String? {
        first(#"Homebrew\s+([0-9][0-9A-Za-z.\-_]*)"#, in: out)
    }

    /// `ollama --version` -> "0.12.6" (also when it warns that no server is running).
    public static func ollama(_ out: String) -> String? {
        first(#"version is\s+([0-9][0-9A-Za-z.\-_]*)"#, in: out) ?? first(#"ollama version\s+([0-9][0-9A-Za-z.\-_]*)"#, in: out)
    }

    /// `ffmpeg -version` -> "7.1.1".
    public static func ffmpeg(_ out: String) -> String? {
        first(#"ffmpeg version\s+(\S+)"#, in: out)
    }

    /// `brew list --versions a b c` -> [formula: newest version].
    public static func brewList(_ out: String) -> [String: String] {
        var r: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            r[parts[0]] = parts.last
        }
        return r
    }

    private static func first(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}

// MARK: - An Ollama server that is already there

public enum ExistingServer: Equatable, Sendable {
    case none
    /// Something answers /api/version. `managedBy` is the LaunchAgent label when one is loaded.
    case running(version: String?, modelsPath: String?, managedBy: String?)
    /// A LaunchAgent runs Ollama but nothing answers right now (e.g. its drive isn't connected).
    case agentNotRunning(label: String, modelsPath: String?)

    public var isPresent: Bool { self != .none }

    /// ChatGauge offers its own LaunchAgent only when no other server or agent exists, so it never competes with one.
    public var offersOwnAgent: Bool { self == .none }

    public var modelsPath: String? {
        switch self {
        case .none: return nil
        case .running(_, let p, _), .agentNotRunning(_, let p): return p
        }
    }

    public var label: String? {
        switch self {
        case .none: return nil
        case .running(_, _, let l): return l
        case .agentNotRunning(let l, _): return l
        }
    }

    /// Whether the server serves `folder` (nil = unknown).
    public func serves(_ folder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool? {
        guard isPresent else { return false }
        let mine = (folder as NSString).standardizingPath
        guard let p = modelsPath else {
            // No OLLAMA_MODELS anywhere: Ollama uses its standard folder.
            if case .running(_, nil, nil) = self { return mine == (ModelsLocation.defaultLocal(home: home) as NSString).standardizingPath ? true : nil }
            return mine == (ModelsLocation.defaultLocal(home: home) as NSString).standardizingPath
        }
        return (p as NSString).standardizingPath == mine
    }
}

public enum ServerDetection {
    /// OLLAMA_MODELS from `ps -E -o command= -p <pid>` (arguments, then the environment, space separated).
    /// A value may contain spaces, so it runs until the next ` NAME=`.
    public static func modelsFromProcess(_ line: String) -> String? {
        guard let r = line.range(of: "OLLAMA_MODELS=") else { return nil }
        let rest = line[r.upperBound...]
        let end = rest.range(of: #" [A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression)?.lowerBound ?? rest.endIndex
        let v = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public static func describe(answering: Bool, version: String?, agents: [OllamaAgent], loadedLabels: Set<String>,
                                processModels: String?) -> ExistingServer {
        let sorted = agents  // discover() already puts the shared agent first
        if answering {
            let loaded = sorted.first { loadedLabels.contains($0.label) }
            return .running(version: version, modelsPath: processModels ?? loaded?.modelsPath, managedBy: loaded?.label)
        }
        if let a = sorted.first { return .agentNotRunning(label: a.label, modelsPath: a.modelsPath) }
        return .none
    }
}

// MARK: - Should the wizard open by itself?

public struct SetupSnapshot: Equatable, Sendable {
    /// settings.json was there before this launch (ChatGauge has run on this Mac before).
    public var settingsFileExisted: Bool
    public var setupCompletedAt: Date?
    /// LaunchAgents that run Ollama (any label).
    public var agents: [OllamaAgent]
    /// Chat models found on disk in the chosen models folder.
    public var modelsOnDisk: Int
    public var ollamaInstalled: Bool

    public init(settingsFileExisted: Bool, setupCompletedAt: Date?, agents: [OllamaAgent], modelsOnDisk: Int, ollamaInstalled: Bool) {
        self.settingsFileExisted = settingsFileExisted
        self.setupCompletedAt = setupCompletedAt
        self.agents = agents
        self.modelsOnDisk = modelsOnDisk
        self.ollamaInstalled = ollamaInstalled
    }
}

public enum SetupGate {
    /// A server agent that sets its own models folder, or Ollama with models installed, counts as a finished setup.
    public static func existingSetupLooksComplete(_ s: SetupSnapshot) -> Bool {
        if s.agents.contains(where: { ($0.modelsPath ?? "").isEmpty == false }) { return true }
        return s.ollamaInstalled && s.modelsOnDisk > 0
    }

    /// Opens only on a Mac that has never run ChatGauge and has no working Ollama setup.
    public static func shouldAutoShow(_ s: SetupSnapshot) -> Bool {
        if s.setupCompletedAt != nil { return false }
        if s.settingsFileExisted { return false }
        return !existingSetupLooksComplete(s)
    }
}

// MARK: - Which steps to skip

public struct SetupProgress: Equatable, Sendable {
    public var locationReady: Bool
    public var toolsReady: Bool
    public var modelsReady: Bool
    public var serverReady: Bool
    public init(locationReady: Bool = false, toolsReady: Bool = false, modelsReady: Bool = false, serverReady: Bool = false) {
        self.locationReady = locationReady
        self.toolsReady = toolsReady
        self.modelsReady = modelsReady
        self.serverReady = serverReady
    }
}

public enum SetupFlow {
    public static func isSatisfied(_ step: SetupStep, _ p: SetupProgress) -> Bool {
        switch step {
        case .location: return p.locationReady
        case .tools: return p.toolsReady
        case .models: return p.modelsReady
        case .server: return p.serverReady
        default: return false
        }
    }

    /// The next step to show, jumping over skippable steps that are already done.
    public static func next(after step: SetupStep, _ p: SetupProgress) -> SetupStep {
        var i = step.rawValue + 1
        while let s = SetupStep(rawValue: i) {
            if !(s.skippable && isSatisfied(s, p)) { return s }
            i += 1
        }
        return .done
    }

    public static func previous(before step: SetupStep, _ p: SetupProgress) -> SetupStep {
        var i = step.rawValue - 1
        while let s = SetupStep(rawValue: i) {
            if !(s.skippable && isSatisfied(s, p)) { return s }
            i -= 1
        }
        return .welcome
    }
}

// MARK: - Installed models on disk

public enum ModelManifests {
    static let roots = ["manifests-v2/ollama.com", "manifests-v2/registry.ollama.ai", "manifests/registry.ollama.ai"]

    /// "name:tag" for every library model in an Ollama models folder (the server needn't run).
    public static func installed(in folder: URL, fm: FileManager = .default) -> [String] {
        var out = Set<String>()
        for r in roots {
            let lib = folder.appendingPathComponent(r).appendingPathComponent("library")
            for name in (try? fm.contentsOfDirectory(atPath: lib.path)) ?? [] where !name.hasPrefix(".") {
                for tag in (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent(name).path)) ?? [] where !tag.hasPrefix(".") {
                    out.insert("\(name):\(tag)")
                }
            }
        }
        return out.sorted()
    }
}

// MARK: - What a step will run (shown before it runs)

public enum SetupPlan {
    public static func quote(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9_./:@%+=-]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func brewInstall(brew: String, tool: SetupTool) -> [String] { ["\(quote(brew)) install \(tool.formula)"] }

    public static func createFolder(_ path: String) -> [String] { ["mkdir -p \(quote(path))"] }

    /// The temporary download server: ChatGauge's own `ollama serve` on another port, stopped when downloads finish.
    public static let downloadPort = 11435

    public static func pull(models: [String], ollama: String, folder: String, viaExisting: String?) -> [String] {
        var out: [String] = []
        let host: String
        if let viaExisting {
            host = viaExisting
        } else {
            host = "http://127.0.0.1:\(downloadPort)"
            out.append("OLLAMA_HOST=127.0.0.1:\(downloadPort) OLLAMA_MODELS=\(quote(folder)) \(quote(ollama)) serve   # stopped when the downloads finish")
        }
        for m in models { out.append("POST \(host)/api/pull {\"model\":\"\(m)\"}") }
        return out
    }

    public static func whisperDownload(_ name: String, folder: String, url: URL) -> [String] {
        ["mkdir -p \(quote(folder))",
         "download \(url.absoluteString) -> \(quote((folder as NSString).appendingPathComponent("ggml-\(name).bin")))",
         "check the SHA-256 against Hugging Face's published hash"]
    }

    public static func agentInstall(plistPath: String, uid: UInt32) -> [String] {
        ["write \(quote(plistPath))", "launchctl bootstrap gui/\(uid) \(quote(plistPath))"]
    }

    public static func agentRemove(plistPath: String, uid: UInt32) -> [String] {
        ["launchctl bootout gui/\(uid)/\(OwnOllamaAgent.label)", "rm \(quote(plistPath))"]
    }
}

// MARK: - ChatGauge's own LaunchAgent

public enum OwnOllamaAgent {
    public static let label = OllamaAgent.ownLabel

    public static func plistPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    public static func logPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appendingPathComponent("Library/Logs/ChatGauge/ollama.log").path
    }

    /// The shell line the agent runs: for an external drive it waits for the folder to appear, then serves.
    public static func script(ollama: String, modelsPath: String) -> String {
        let q = SetupPlan.quote
        if ModelsLocation.volumeRoot(of: modelsPath) != nil {
            return "while [ ! -d \(q(modelsPath)) ]; do sleep 10; done; exec \(q(ollama)) serve"
        }
        return "exec \(q(ollama)) serve"
    }

    public static func plist(ollama: String, modelsPath: String, logPath: String, port: Int = 11434) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", script(ollama: ollama, modelsPath: modelsPath)],
            "EnvironmentVariables": ["OLLAMA_MODELS": modelsPath, "OLLAMA_HOST": "127.0.0.1:\(port)"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    public static func plistData(ollama: String, modelsPath: String, logPath: String, port: Int = 11434) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(ollama: ollama, modelsPath: modelsPath, logPath: logPath, port: port),
                                           format: .xml, options: 0)
    }

    /// ChatGauge removes only its own agent.
    public static func mayRemove(label l: String) -> Bool { l == label }
}

// MARK: - Whisper download checksum

public enum WhisperChecksum {
    /// Hugging Face's `X-Linked-Etag` for an LFS file is its SHA-256 (quoted). Anything else -> nil.
    public static func sha256(fromLinkedEtag raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("W/") { s.removeFirst(2) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        s = s.lowercased()
        return s.count == 64 && s.allSatisfy(\.isHexDigit) ? s : nil
    }

    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

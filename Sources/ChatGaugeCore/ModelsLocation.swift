import Foundation

/// Resolves the models folder and whether it is reachable right now.
public struct ModelsLocation: Equatable, Sendable {
    public var kind: ModelsLocationKind
    public var path: String

    public init(kind: ModelsLocationKind, path: String) {
        self.kind = kind
        self.path = path
    }

    public static func defaultLocal(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appendingPathComponent(".ollama/models").path
    }

    public static func from(_ s: ChatSettings, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ModelsLocation {
        let raw = s.modelsPath.map { ($0 as NSString).expandingTildeInPath }.flatMap { $0.isEmpty ? nil : $0 }
        switch s.modelsLocation {
        case .local: return ModelsLocation(kind: .local, path: raw ?? defaultLocal(home: home))
        case .external: return ModelsLocation(kind: .external, path: raw ?? "")
        }
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// `/Volumes/<name>` for a path on another volume, else nil.
    public var volumeRoot: String? { Self.volumeRoot(of: path) }

    public static func volumeRoot(of path: String) -> String? {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    public var volumeName: String? { volumeRoot.map { ($0 as NSString).lastPathComponent } }

    /// The whisper folder used for voice: `<models>/whisper`, ClipGauge's layout.
    public var whisperFolder: URL { url.appendingPathComponent("whisper", isDirectory: true) }

    /// ClipGauge's project root is the models folder's parent (`<root>/models`).
    public var projectRoot: URL { url.deletingLastPathComponent() }

    /// ClipGauge's custom instructions, if this models folder came from a ClipGauge project.
    public var clipGaugeInstructions: URL { projectRoot.appendingPathComponent("config/custom-instructions.json") }

    /// ClipGauge's `ram-tiers.json`, read when present.
    public var ramTiersFile: URL { projectRoot.appendingPathComponent("config/ram-tiers.json") }
}

public enum ModelsAvailability: Equatable, Sendable {
    case ready
    /// The external drive isn't mounted. Chat pauses; nothing writes to the missing drive.
    case driveMissing(volume: String)
    /// The volume is there but the folder isn't.
    case folderMissing
    /// External chosen but no folder picked yet.
    case notChosen
}

public extension ModelsLocation {
    func availability(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ModelsAvailability {
        if path.isEmpty { return .notChosen }
        if let v = volumeRoot, !fileExists(v) { return .driveMissing(volume: (v as NSString).lastPathComponent) }
        if !fileExists(path) {
            // Ollama creates ~/.ollama/models on first use; a missing default local folder is fine.
            return kind == .local && volumeRoot == nil ? .ready : .folderMissing
        }
        return .ready
    }

    /// Free space on the volume that holds the models folder (nil if unknown or the drive is missing).
    public var freeBytes: Int64? {
        let root = volumeRoot ?? path
        let u = URL(fileURLWithPath: root)
        guard let vals = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let important = vals.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let avail = vals.volumeAvailableCapacity { return Int64(avail) }
        return nil
    }
}

import Foundation

/// Limits match ClipGauge's instructions so a glossary moves between the apps cleanly.
public enum InstructionLimits {
    public static let standingChars = 2000
    public static let presetNameChars = 40
    public static let presets = 12
    public static let glossaryTerms = 80
    public static let glossaryTermChars = 40
    /// whisper-cli's initial prompt is capped at about 224 tokens; stay well under.
    public static let glossaryChars = 600
}

public enum InstructionText {
    /// Plain text only: no control characters (except newlines and tabs), tidy line ends, at most `limit` characters.
    public static func sanitize(_ text: String, limit: Int) -> String {
        var t = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = String(String.UnicodeScalarView(t.unicodeScalars.filter { s in
            s == "\n" || s == "\t" || !(s.properties.generalCategory == .control || s.properties.generalCategory == .format && s.value != 0x200D)
        }))
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        t = t.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > limit { t = String(t.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return t
    }

    /// Newline, comma or semicolon separated terms → unique terms, each ≤ 40 characters, at most 80 terms / 600 characters.
    public static func parseGlossary(_ raw: String) -> [String] {
        parseGlossary(raw.components(separatedBy: CharacterSet(charactersIn: "\n,;")))
    }

    public static func parseGlossary(_ terms: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var total = 0
        for term in terms {
            let t = sanitize(term, limit: InstructionLimits.glossaryTermChars)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard !t.isEmpty, !seen.contains(t.lowercased()) else { continue }
            if out.count >= InstructionLimits.glossaryTerms || total + t.count + 2 > InstructionLimits.glossaryChars { break }
            seen.insert(t.lowercased())
            out.append(t)
            total += t.count + 2
        }
        return out
    }

    /// How many characters the glossary uses (as counted against the 600 limit).
    public static func glossaryLength(_ terms: [String]) -> Int { terms.reduce(0) { $0 + $1.count + 2 } }
}

public struct InstructionPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var standing: String

    public init(id: UUID = UUID(), name: String, standing: String) {
        self.id = id
        self.name = name
        self.standing = standing
    }
}

/// ~/Library/Application Support/ChatGauge/instructions.json: presets (one active), plus a shared glossary.
public struct InstructionsFile: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var app = "ChatGauge"
    public var schema = InstructionsFile.schemaVersion
    public var presets: [InstructionPreset]
    public var activePresetID: UUID?
    public var glossary: [String]
    /// When off, no system prompt is sent at all.
    public var enabled: Bool
    public var updatedAt: Date

    public init(presets: [InstructionPreset], activePresetID: UUID? = nil, glossary: [String] = [], enabled: Bool = true,
                updatedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.presets = presets
        self.activePresetID = activePresetID ?? presets.first?.id
        self.glossary = glossary
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    public static var standard: InstructionsFile {
        InstructionsFile(presets: [
            InstructionPreset(name: "Default", standing: """
            You are a helpful assistant running locally on this Mac. Answer clearly and briefly. \
            When an image is attached, describe what you can actually see and say plainly when something isn't readable.
            """),
            InstructionPreset(name: "Script helper", standing: """
            You help write and tighten video scripts. Keep a friendly, conversational tone and short sentences that read well aloud. \
            Offer an outline first when asked for a full script.
            """),
            InstructionPreset(name: "Spec sheet", standing: """
            You help write spec sheets for tech product reviews.
            Answer with short bullet lists. Read labels, ports and model numbers from photos when you can, and say plainly when something isn't readable instead of guessing.
            Use US spelling. Don't invent prices or release dates.
            """),
        ])
    }

    public var active: InstructionPreset? {
        presets.first { $0.id == activePresetID } ?? presets.first
    }

    /// The system message: the active preset's standing instructions, then the glossary as a spelling line.
    public func systemPrompt() -> String? {
        guard enabled else { return nil }
        var parts: [String] = []
        let standing = InstructionText.sanitize(active?.standing ?? "", limit: InstructionLimits.standingChars)
        if !standing.isEmpty { parts.append(standing) }
        if !glossary.isEmpty { parts.append("Spell these names exactly as written: " + glossary.joined(separator: ", ") + ".") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// whisper-cli --prompt text: the glossary only (long prose hurts Whisper).
    public func whisperPrompt() -> String? {
        glossary.isEmpty ? nil : glossary.joined(separator: ", ")
    }

    /// Popover summary, e.g. "Spec sheet" or "Off".
    public var summary: String { enabled ? (active?.name ?? "None") : "Off" }

    /// Cleans every field to the limits; keeps at least one preset and a valid active id.
    public func normalized() -> InstructionsFile {
        var f = self
        var names = Set<String>()
        f.presets = presets.prefix(InstructionLimits.presets).map { p in
            var p = p
            var n = InstructionText.sanitize(p.name, limit: InstructionLimits.presetNameChars).replacingOccurrences(of: "\n", with: " ")
            if n.isEmpty { n = "Untitled" }
            var unique = n
            var i = 2
            while names.contains(unique.lowercased()) { unique = "\(n) \(i)"; i += 1 }
            names.insert(unique.lowercased())
            p.name = unique
            p.standing = InstructionText.sanitize(p.standing, limit: InstructionLimits.standingChars)
            return p
        }
        if f.presets.isEmpty { f.presets = InstructionsFile.standard.presets }
        if !f.presets.contains(where: { $0.id == f.activePresetID }) { f.activePresetID = f.presets.first?.id }
        f.glossary = InstructionText.parseGlossary(glossary)
        return f
    }

    // MARK: File

    public static func decode(_ data: Data) throws -> InstructionsFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let f = try d.decode(InstructionsFile.self, from: data)
        guard f.app == "ChatGauge" else { throw SettingsFileError.notChatGauge(f.app) }
        guard f.schema <= schemaVersion else { throw SettingsFileError.newerSchema(f.schema) }
        return f.normalized()
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// Missing file → standard presets. Unreadable file → moved aside as instructions.bad.json, then standard.
    public static func load(from url: URL, fm: FileManager = .default) -> InstructionsFile {
        guard let data = fm.contents(atPath: url.path) else { return .standard }
        if let f = try? decode(data) { return f }
        let bad = url.deletingPathExtension().appendingPathExtension("bad.json")
        try? fm.removeItem(at: bad)
        try? fm.moveItem(at: url, to: bad)
        return .standard
    }

    public func save(to url: URL, fm: FileManager = .default) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try normalized().encoded().write(to: url, options: .atomic)
    }

    private enum CodingKeys: String, CodingKey { case app, schema, presets, activePresetID, glossary, enabled, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? c.decode(String.self, forKey: .app)) ?? "?"
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        presets = (try? c.decode([InstructionPreset].self, forKey: .presets)) ?? []
        activePresetID = try? c.decodeIfPresent(UUID.self, forKey: .activePresetID)
        glossary = (try? c.decode([String].self, forKey: .glossary)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Reads ClipGauge's config/custom-instructions.json (written for naming clips). Only the glossary
/// and, if asked, the standing text come across; ClipGauge's file is never written.
public enum ClipGaugeImport {
    public struct Found: Equatable, Sendable {
        public var glossary: [String]
        public var standing: String
    }

    public static func read(_ data: Data) -> Found? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let g: [String]
        if let list = o["glossary"] as? [String] { g = InstructionText.parseGlossary(list) }
        else if let s = o["glossary"] as? String { g = InstructionText.parseGlossary(s) }
        else { g = [] }
        let standing = InstructionText.sanitize((o["standing"] as? String) ?? "", limit: InstructionLimits.standingChars)
        if g.isEmpty && standing.isEmpty { return nil }
        return Found(glossary: g, standing: standing)
    }

    /// Merges imported terms after the existing ones (no duplicates, within the limits).
    public static func merge(_ existing: [String], _ imported: [String]) -> [String] {
        InstructionText.parseGlossary(existing + imported)
    }
}

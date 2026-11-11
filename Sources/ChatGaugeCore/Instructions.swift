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

/// ~/Library/Application Support/ChatGauge/instructions.json.
/// Schema 2: each chat model has its own instructions (OT-79). Named presets from schema 1 are kept on disk
/// so an older file still loads, but the system prompt comes from `defaultStanding` or a per-model override.
public struct InstructionsFile: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public var app = "ChatGauge"
    public var schema = InstructionsFile.schemaVersion
    public var presets: [InstructionPreset]
    public var activePresetID: UUID?
    public var glossary: [String]
    /// When off, no system prompt is sent at all.
    public var enabled: Bool
    public var updatedAt: Date
    /// Used for every model that has no override of its own.
    public var defaultStanding: String
    /// Standing instructions keyed by chat-model name.
    public var modelInstructions: [String: String]
    /// OT-100: the ClipGauge glossary import is one-time.
    public var clipGaugeGlossaryImported: Bool

    public init(presets: [InstructionPreset], activePresetID: UUID? = nil, glossary: [String] = [], enabled: Bool = true,
                updatedAt: Date = Date(timeIntervalSince1970: 0), defaultStanding: String? = nil,
                modelInstructions: [String: String] = [:], clipGaugeGlossaryImported: Bool = false) {
        self.presets = presets
        self.activePresetID = activePresetID ?? presets.first?.id
        self.glossary = glossary
        self.enabled = enabled
        self.updatedAt = updatedAt
        self.defaultStanding = defaultStanding
            ?? presets.first(where: { $0.name == "Default" })?.standing
            ?? presets.first?.standing
            ?? ""
        self.modelInstructions = modelInstructions
        self.clipGaugeGlossaryImported = clipGaugeGlossaryImported
    }

    public static let defaultStandingText = """
            You are a helpful assistant running locally on this Mac. Answer clearly and briefly. \
            When an image is attached, describe what you can actually see and say plainly when something isn't readable.
            """

    public static var standard: InstructionsFile {
        InstructionsFile(presets: [
            InstructionPreset(name: "Default", standing: defaultStandingText),
            InstructionPreset(name: "Script helper", standing: """
            You help write and tighten video scripts. Keep a friendly, conversational tone and short sentences that read well aloud. \
            Offer an outline first when asked for a full script.
            """),
            InstructionPreset(name: "Spec sheet", standing: """
            You help write spec sheets for tech product reviews.
            Answer with short bullet lists. Read labels, ports and model numbers from photos when you can, and say plainly when something isn't readable instead of guessing.
            Use US spelling. Don't invent prices or release dates.
            """),
        ], defaultStanding: defaultStandingText)
    }

    public var active: InstructionPreset? {
        presets.first { $0.id == activePresetID } ?? presets.first
    }

    /// Standing text used for `model` (its own override, else the default).
    public func standing(for model: String?) -> String {
        if let model {
            let own = modelInstructions[model] ?? ""
            if !InstructionText.sanitize(own, limit: InstructionLimits.standingChars).isEmpty {
                return InstructionText.sanitize(own, limit: InstructionLimits.standingChars)
            }
        }
        return InstructionText.sanitize(defaultStanding, limit: InstructionLimits.standingChars)
    }

    public mutating func setStanding(_ text: String, for model: String?) {
        let s = InstructionText.sanitize(text, limit: InstructionLimits.standingChars)
        if let model {
            if s.isEmpty || s == InstructionText.sanitize(defaultStanding, limit: InstructionLimits.standingChars) {
                modelInstructions.removeValue(forKey: model)
            } else {
                modelInstructions[model] = s
            }
        } else {
            defaultStanding = s
        }
    }

    /// The system message for a chat on `model`: that model's instructions (or the default), then the glossary.
    public func systemPrompt(for model: String? = nil) -> String? {
        guard enabled else { return nil }
        var parts: [String] = []
        let standing = standing(for: model)
        if !standing.isEmpty { parts.append(standing) }
        if !glossary.isEmpty { parts.append("Spell these names exactly as written: " + glossary.joined(separator: ", ") + ".") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// whisper-cli --prompt text: the glossary only (long prose hurts Whisper).
    public func whisperPrompt() -> String? {
        glossary.isEmpty ? nil : glossary.joined(separator: ", ")
    }

    /// Popover summary, e.g. "Default" or "Off".
    public var summary: String {
        guard enabled else { return "Off" }
        return "Per model"
    }

    /// Cleans every field to the limits. Schema 1 files fill `defaultStanding` from the Default preset.
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
        if f.defaultStanding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            f.defaultStanding = f.presets.first(where: { $0.name == "Default" })?.standing
                ?? f.presets.first?.standing
                ?? ""
        }
        f.defaultStanding = InstructionText.sanitize(f.defaultStanding, limit: InstructionLimits.standingChars)
        if f.presets.isEmpty && f.defaultStanding.isEmpty {
            f = InstructionsFile.standard
            f.glossary = InstructionText.parseGlossary(glossary)
            f.enabled = enabled
            f.clipGaugeGlossaryImported = clipGaugeGlossaryImported
            return f
        }
        if !f.presets.isEmpty, !f.presets.contains(where: { $0.id == f.activePresetID }) { f.activePresetID = f.presets.first?.id }
        var cleaned: [String: String] = [:]
        for (k, v) in modelInstructions {
            let key = InstructionText.sanitize(k, limit: 200).replacingOccurrences(of: "\n", with: " ")
            let val = InstructionText.sanitize(v, limit: InstructionLimits.standingChars)
            if !key.isEmpty, !val.isEmpty { cleaned[key] = val }
        }
        f.modelInstructions = cleaned
        f.glossary = InstructionText.parseGlossary(glossary)
        if f.schema < InstructionsFile.schemaVersion { f.schema = InstructionsFile.schemaVersion }
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

    private enum CodingKeys: String, CodingKey {
        case app, schema, presets, activePresetID, glossary, enabled, updatedAt
        case defaultStanding, modelInstructions, clipGaugeGlossaryImported
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? c.decode(String.self, forKey: .app)) ?? "?"
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        presets = (try? c.decode([InstructionPreset].self, forKey: .presets)) ?? []
        activePresetID = try? c.decodeIfPresent(UUID.self, forKey: .activePresetID)
        glossary = (try? c.decode([String].self, forKey: .glossary)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date(timeIntervalSince1970: 0)
        let decodedDefault = try? c.decodeIfPresent(String.self, forKey: .defaultStanding)
        defaultStanding = decodedDefault
            ?? presets.first(where: { $0.name == "Default" })?.standing
            ?? presets.first?.standing
            ?? ""
        modelInstructions = (try? c.decode([String: String].self, forKey: .modelInstructions)) ?? [:]
        clipGaugeGlossaryImported = (try? c.decode(Bool.self, forKey: .clipGaugeGlossaryImported)) ?? false
    }
}

/// Reads ClipGauge's config/custom-instructions.json (written for naming clips). Only the glossary
/// is imported (OT-100). ClipGauge's file is never written. The import is one-time and starts with a dry run.
public enum ClipGaugeImport {
    public struct Found: Equatable, Sendable {
        public var glossary: [String]
        public var standing: String
    }

    public struct Plan: Equatable, Sendable {
        public var sourcePath: String
        public var termsToAdd: [String]
        public var alreadyPresent: [String]
        public var skippedForLimit: [String]
        public var alreadyImported: Bool
        public var lines: [String]
        public var canApply: Bool
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

    /// Dry-run: what a one-time, read-only glossary import would add. Never writes ClipGauge's file.
    public static func plan(existing: [String], imported: [String], alreadyImported: Bool, sourcePath: String) -> Plan {
        var lines: [String] = ["Read \(sourcePath) (ClipGauge's file is not changed)."]
        if alreadyImported {
            lines.append("This import already ran once; it will not run again.")
            return Plan(sourcePath: sourcePath, termsToAdd: [], alreadyPresent: [], skippedForLimit: [],
                        alreadyImported: true, lines: lines, canApply: false)
        }
        let have = InstructionText.parseGlossary(existing)
        let incoming = InstructionText.parseGlossary(imported)
        let haveSet = Set(have.map { $0.lowercased() })
        let already = incoming.filter { haveSet.contains($0.lowercased()) }
        let fresh = incoming.filter { !haveSet.contains($0.lowercased()) }
        let merged = merge(have, incoming)
        let added = merged.filter { t in !haveSet.contains(t.lowercased()) }
        let skipped = fresh.filter { t in !added.contains(where: { $0.lowercased() == t.lowercased() }) }
        if added.isEmpty && already.isEmpty && skipped.isEmpty {
            lines.append("No glossary terms to import.")
        } else {
            if !added.isEmpty { lines.append("Would add \(added.count) term(s): \(added.joined(separator: ", ")).") }
            if !already.isEmpty { lines.append("Already in ChatGauge (\(already.count)): \(already.joined(separator: ", ")).") }
            if !skipped.isEmpty { lines.append("Would skip \(skipped.count) term(s) that do not fit the glossary limit.") }
        }
        lines.append("One-time import. After it runs, the button stays off.")
        return Plan(sourcePath: sourcePath, termsToAdd: added, alreadyPresent: already, skippedForLimit: skipped,
                    alreadyImported: false, lines: lines, canApply: !added.isEmpty)
    }

    public static func apply(_ file: InstructionsFile, plan: Plan) -> InstructionsFile {
        guard plan.canApply, !file.clipGaugeGlossaryImported else { return file }
        var f = file
        f.glossary = merge(f.glossary, plan.termsToAdd)
        f.clipGaugeGlossaryImported = true
        return f
    }
}

import Foundation

/// Where the voice tools live. Homebrew paths first (Apple silicon, then Intel).
public enum VoiceTools {
    public static let whisperCandidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
    public static let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    public static func find(_ candidates: [String], fm: FileManager = .default) -> String? {
        candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static var whisperCLI: String? { find(whisperCandidates) }
    public static var ffmpeg: String? { find(ffmpegCandidates) }
}

/// Picks the whisper model: the one chosen in Settings, else the tier's list in order, else any installed one.
/// Never downloads anything by itself.
public enum WhisperModelPicker {
    /// "ggml-base.en.bin" -> "base.en". Skips VAD and Core ML encoder files.
    public static func modelName(fromFile f: String) -> String? {
        guard f.hasPrefix("ggml-"), f.hasSuffix(".bin") else { return nil }
        let name = String(f.dropFirst(5).dropLast(4))
        let l = name.lowercased()
        if name.isEmpty || l.contains("silero") || l.contains("vad") || l.hasSuffix("-encoder") { return nil }
        return name
    }

    public static func installed(in folder: URL, fm: FileManager = .default) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap(modelName(fromFile:)).sorted()
    }

    public static func pick(installed: [String], tier: RAMTier, rules: TierRules = .standard, override: String? = nil) -> String? {
        if let o = override, !o.isEmpty, installed.contains(o) { return o }
        for name in rules.whisper[tier] ?? [] where installed.contains(name) { return name }
        // Something installed but not on the tier list: prefer small over huge on the Air tier.
        let bySize = installed.sorted { sizeRank($0) < sizeRank($1) }
        return tier == .air ? bySize.first : bySize.last
    }

    /// The name to offer for download when nothing is installed.
    public static func suggested(tier: RAMTier, rules: TierRules = .standard) -> String {
        (rules.whisper[tier] ?? []).first ?? (tier == .pro ? "large-v3-turbo" : "base.en")
    }

    public static func fileURL(_ name: String, in folder: URL) -> URL {
        folder.appendingPathComponent("ggml-\(name).bin")
    }

    /// The whisper.cpp model repo on Hugging Face.
    public static func downloadURL(_ name: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")!
    }

    /// Rough download size for the confirmation text.
    public static func approximateSize(_ name: String) -> String {
        let n = name.lowercased()
        if n.hasPrefix("tiny") { return "75 MB" }
        if n.hasPrefix("base") { return "142 MB" }
        if n.hasPrefix("small") { return "466 MB" }
        if n.hasPrefix("medium") { return "1.5 GB" }
        if n.contains("turbo") { return "1.6 GB" }
        if n.hasPrefix("large") { return "2.9 GB" }
        return "a few hundred MB"
    }

    static func sizeRank(_ name: String) -> Int {
        let n = name.lowercased()
        for (i, p) in ["tiny", "base", "small", "medium", "large"].enumerated() where n.hasPrefix(p) {
            return i * 10 + (n.contains("turbo") ? -3 : 0) + (n.contains("q5") || n.contains("q8") ? -1 : 0)
        }
        return 25
    }
}

/// Command lines for ffmpeg and whisper-cli.
public enum VoiceCommands {
    /// Any recording -> 16 kHz mono 16-bit WAV, which is what whisper.cpp wants.
    public static func ffmpegArgs(input: String, output: String) -> [String] {
        ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input,
         "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", output]
    }

    public static func whisperArgs(model: String, modelName: String, wav: String, prompt: String?, threads: Int) -> [String] {
        var a = ["-m", model, "-f", wav, "-nt", "-np", "-t", String(max(1, min(threads, 8)))]
        a += ["-l", modelName.lowercased().contains(".en") ? "en" : "auto"]
        if let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            a += ["--prompt", String(p.prefix(InstructionLimits.glossaryChars))]
        }
        return a
    }

    /// whisper-cli stdout -> one clean paragraph. Drops markers like [BLANK_AUDIO] and (music).
    public static func cleanTranscript(_ out: String) -> String {
        var lines: [String] = []
        for raw in out.components(separatedBy: .newlines) {
            var l = raw.trimmingCharacters(in: .whitespaces)
            // Timestamps, if a build ignores -nt: "[00:00:00.000 --> 00:00:02.000]  text"
            if l.hasPrefix("["), let close = l.firstIndex(of: "]"), l[..<close].contains("-->") {
                l = String(l[l.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            let markerPattern = #"^[\[\(][^\]\)]*[\]\)]$"#
            if l.isEmpty || l.range(of: markerPattern, options: .regularExpression) != nil { continue }
            lines.append(l)
        }
        return lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Adds dictated text to the composer draft without sending.
    public static func insert(_ text: String, into draft: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return draft }
        if draft.isEmpty { return t }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + t : draft + " " + t
    }
}

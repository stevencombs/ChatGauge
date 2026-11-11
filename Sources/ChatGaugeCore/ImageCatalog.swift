import Foundation

/// One optional image-generation model or companion encoder in ChatGauge's catalog.
public struct ImageModelEntry: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case model
        case textEncoder
    }

    public var id: String
    public var title: String
    public var repo: String
    public var bytes: Int64
    public var blurb: String
    public var license: String
    public var uncensored: Bool
    public var kind: Kind
    /// Built-in mflux family name passed as `--base-model`.
    public var baseModel: String
    /// mflux generate executable (not used for a text-encoder-only install).
    public var command: String
    /// Catalog id this encoder pairs with, if any.
    public var pairsWith: String?

    public init(id: String, title: String, repo: String, bytes: Int64, blurb: String, license: String,
                uncensored: Bool = false, kind: Kind = .model, baseModel: String, command: String,
                pairsWith: String? = nil) {
        self.id = id
        self.title = title
        self.repo = repo
        self.bytes = bytes
        self.blurb = blurb
        self.license = license
        self.uncensored = uncensored
        self.kind = kind
        self.baseModel = baseModel
        self.command = command
        self.pairsWith = pairsWith
    }

    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    public var folderName: String { repo.split(separator: "/").last.map(String.init) ?? id }
}

/// Known optional image models. Sizes are current Hugging Face file totals as of 10 Nov 2026.
public enum ImageCatalog {
    /// Official mflux 4-bit Klein 4B: 4,619,704,206 bytes. Apache 2.0.
    public static let klein4b = ImageModelEntry(
        id: "flux2-klein-4b",
        title: "FLUX.2 Klein 4B",
        repo: "mflux-community/flux2-klein-4b-mflux-q4",
        bytes: 4_619_704_206,
        blurb: "Main optional model, Apache 2.0, 4-bit mflux build (4.6 GB). Fast default on Apple silicon.",
        license: "Apache 2.0",
        baseModel: "flux2-klein-4b",
        command: "mflux-generate-flux2"
    )

    /// Official mflux 4-bit Z-Image Turbo: 5,902,988,435 bytes. Apache 2.0.
    public static let zImageTurbo = ImageModelEntry(
        id: "z-image-turbo",
        title: "Z-Image Turbo",
        repo: "mflux-community/z-image-turbo-mflux-q4",
        bytes: 5_902_988_435,
        blurb: "Second optional model, Apache 2.0, 4-bit mflux build (5.9 GB). Strong on photorealism and text.",
        license: "Apache 2.0",
        baseModel: "z-image-turbo",
        command: "mflux-generate-z-image-turbo"
    )

    /// ponpoke abliterated Klein 4B text encoder, safetensors folder only: 8,056,410,867 bytes.
    /// Card license is other / flux-non-commercial-v2.1 (see plan). mflux cannot load it as-is.
    public static let kleinUncensoredEncoder = ImageModelEntry(
        id: "flux2-klein-4b-uncensored-te",
        title: "Klein 4B uncensored text encoder",
        repo: "ponpoke/flux2-klein-4b-uncensored-text-encoder",
        bytes: 8_056_410_867,
        blurb: "Uncensored text encoder for Klein 4B (8.0 GB). Safety filter removed. The model card marks license flux-non-commercial-v2.1 (gated). mflux has no documented way to load this encoder as-is.",
        license: "other / flux-non-commercial-v2.1 (card; linked LICENSE.md is official Klein 4B Apache 2.0)",
        uncensored: true,
        kind: .textEncoder,
        baseModel: "flux2-klein-4b",
        command: "mflux-generate-flux2",
        pairsWith: klein4b.id
    )

    public static var standard: [ImageModelEntry] { [klein4b, zImageTurbo] }
    public static var uncensored: [ImageModelEntry] { [kleinUncensoredEncoder] }
    public static var all: [ImageModelEntry] { standard + uncensored }

    public static func entry(_ id: String) -> ImageModelEntry? { all.first { $0.id == id } }

    /// Default suggested model from `hw.memsize`. Klein 4B is the default on every tier in this build;
    /// Z-Image Turbo is offered more readily at 32 GB and up.
    public static func suggested(memBytes: UInt64) -> ImageModelEntry {
        klein4b
    }

    public static func suggestionLabel(memBytes: UInt64) -> String {
        let gb = Int((Double(memBytes) / 1_073_741_824).rounded())
        if gb < 32 {
            return "This Mac has about \(gb) GB of memory. Suggested: \(klein4b.title) (\(klein4b.sizeLabel)). Z-Image Turbo may be tight if a chat model is also loaded."
        }
        if gb < 64 {
            return "This Mac has about \(gb) GB of memory. Suggested: \(klein4b.title) (\(klein4b.sizeLabel)). Z-Image Turbo (\(zImageTurbo.sizeLabel)) is a reasonable optional install at this size."
        }
        return "This Mac has about \(gb) GB of memory. Suggested: \(klein4b.title) (\(klein4b.sizeLabel)). Z-Image Turbo (\(zImageTurbo.sizeLabel)) should also fit."
    }

    /// Lines shown before an install (dry run). Never starts a download.
    public static func installPlan(_ entry: ImageModelEntry, into folder: URL) -> [String] {
        let dest = folder.appendingPathComponent(entry.folderName, isDirectory: true)
        var lines = [
            "download Hugging Face repo \(entry.repo)",
            "into \(dest.path)",
            "about \(entry.sizeLabel) · license: \(entry.license)"
        ]
        if entry.kind == .textEncoder {
            lines.append("This is a text encoder, not a full image model. It pairs with \(entry.pairsWith ?? "Klein 4B").")
            lines.append("mflux has no documented flag to load this encoder as-is. ChatGauge will not silently use the official encoder if you pick this option.")
        }
        if entry.uncensored {
            lines.append("Optional and never the default. The repo is gated and asks you to accept a safety warning on Hugging Face.")
        }
        return lines
    }

    public static func installDestination(_ entry: ImageModelEntry, in folder: URL) -> URL {
        folder.appendingPathComponent(entry.folderName, isDirectory: true)
    }

    public static func isInstalled(_ entry: ImageModelEntry, in folder: URL, fm: FileManager = .default) -> Bool {
        let dest = installDestination(entry, in: folder)
        return fm.fileExists(atPath: dest.appendingPathComponent(".installed").path)
            || fm.fileExists(atPath: dest.path)
            && ((try? fm.contentsOfDirectory(atPath: dest.path))?.contains { !$0.hasPrefix(".") } == true)
    }
}

public enum ImageRemoval {
    public struct Plan: Equatable, Sendable {
        public var id: String
        public var title: String
        public var bytes: Int64
        public var path: String
        public var lines: [String]
        public var warning: String?

        public var freeLabel: String {
            ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
        }
    }

    /// What Remove will do. Never points at the Ollama models folder itself.
    public static func plan(_ entry: ImageModelEntry, folder: URL, installedBytes: Int64? = nil) -> Plan {
        let dest = ImageCatalog.installDestination(entry, in: folder)
        let bytes = installedBytes ?? entry.bytes
        return Plan(
            id: entry.id,
            title: entry.title,
            bytes: bytes,
            path: dest.path,
            lines: ["delete \(dest.path)", "frees about \(ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file))"],
            warning: "This does not touch Ollama or the chat-models folder."
        )
    }
}

/// Optional mflux toolchain. Installed only after a click; never bundled in the app.
public enum MfluxInstall {
    public static let tool = "mflux"
    public static let generateFlux2 = "mflux-generate-flux2"
    public static let generateZImage = "mflux-generate-z-image-turbo"

    /// Dry-run lines. `brew` and `uv` are resolved paths when known.
    public static func plan(brew: String?, uv: String?) -> [String] {
        var lines: [String] = []
        if uv == nil {
            let b = brew ?? "brew"
            lines.append("\(SetupPlan.quote(b)) install uv")
        }
        let uvBin = uv ?? "uv"
        lines.append("\(SetupPlan.quote(uvBin)) tool install mflux")
        lines.append("mflux stays a separate tool; ChatGauge does not compile it into the app.")
        return lines
    }

    public static func removePlan(uv: String?) -> [String] {
        let uvBin = uv ?? "uv"
        return ["\(SetupPlan.quote(uvBin)) tool uninstall mflux"]
    }
}

public enum ImageGenerateError: Error, Equatable, Sendable, CustomStringConvertible {
    case mfluxMissing
    case modelNotInstalled(String)
    case encoderNotInstalled
    case uncensoredNotLoadable
    case driveMissing(String)
    case emptyPrompt

    public var description: String {
        switch self {
        case .mfluxMissing: return "mflux isn’t installed. Install it from Settings or the setup guide (nothing is installed until you click)."
        case .modelNotInstalled(let name): return "\(name) isn’t installed yet."
        case .encoderNotInstalled: return "The uncensored Klein 4B text encoder isn’t installed yet."
        case .uncensoredNotLoadable:
            return "mflux has no documented way to load the uncensored Klein 4B text encoder as-is. ChatGauge will not silently use the official encoder."
        case .driveMissing(let name): return "The models drive “\(name)” isn’t connected."
        case .emptyPrompt: return "Type a prompt first."
        }
    }
}

/// Builds the mflux command ChatGauge would run. Tests assert the argv; a live mflux process is never started from tests.
public enum ImageGenerate {
    public struct Command: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var output: URL
        public var environment: [String: String]

        public var argv: [String] { [executable] + arguments }
        public var display: String { argv.map(SetupPlan.quote).joined(separator: " ") }
    }

    public static func defaultSteps(for entry: ImageModelEntry) -> Int {
        entry.baseModel == "z-image-turbo" ? 9 : 4
    }

    /// `uncensoredLoadable` is only true in tests that plant a verified layout, or if a later live check confirms one.
    public static func command(
        entry: ImageModelEntry,
        prompt: String,
        output: URL,
        modelsFolder: URL,
        mflux: String,
        uncensored: Bool = false,
        uncensoredLoadable: Bool = false,
        width: Int = 768,
        height: Int = 1024,
        steps: Int? = nil,
        seed: UInt64? = nil,
        quantize: Int = 4
    ) -> Result<Command, ImageGenerateError> {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyPrompt) }

        var model = entry
        var useUncensored = uncensored
        if entry.uncensored {
            useUncensored = true
            guard let base = entry.pairsWith.flatMap(ImageCatalog.entry) else {
                return .failure(.modelNotInstalled(entry.title))
            }
            model = base
        }

        let modelDir = ImageCatalog.installDestination(model, in: modelsFolder)
        var arguments = [
            "--model", modelDir.path,
            "--base-model", model.baseModel,
            "--prompt", trimmed,
            "--output", output.path,
            "--width", "\(width)",
            "--height", "\(height)",
            "--steps", "\(steps ?? defaultSteps(for: model))",
            "--quantize", "\(quantize)"
        ]
        if let seed { arguments += ["--seed", "\(seed)"] }

        if useUncensored {
            let enc = ImageCatalog.kleinUncensoredEncoder
            let encDir = ImageCatalog.installDestination(enc, in: modelsFolder)
            // Presence of the files is not enough: official mflux has no documented custom-TE flag,
            // and the ponpoke safetensors layout does not match the mflux q4 text_encoder shards.
            // Only a verified assembled layout (uncensoredLoadable) may proceed. Never fall back.
            if !uncensoredLoadable {
                return .failure(.uncensoredNotLoadable)
            }
            arguments = [
                "--model", encDir.path, // placeholder only when a later verified layout exists
                "--base-model", model.baseModel,
                "--prompt", trimmed,
                "--output", output.path,
                "--width", "\(width)",
                "--height", "\(height)",
                "--steps", "\(steps ?? defaultSteps(for: model))",
                "--quantize", "\(quantize)"
            ]
            if let seed { arguments += ["--seed", "\(seed)"] }
        }

        return .success(Command(executable: mflux, arguments: arguments, output: output, environment: [:]))
    }

    public static func outputURL(in folder: URL, model: String, prompt: String, date: Date = Date(), seed: UInt64? = nil) -> URL {
        let slug = slugify(prompt)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis") ?? .current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        var name = "\(fmt.string(from: date))-\(model)-\(slug)"
        if let seed { name += "-\(seed)" }
        return folder.appendingPathComponent(name + ".png")
    }

    public static func slugify(_ prompt: String, limit: Int = 40) -> String {
        let ok = CharacterSet.alphanumerics.union(.init(charactersIn: "-"))
        let raw = prompt.lowercased().replacingOccurrences(of: " ", with: "-")
        var s = String(raw.unicodeScalars.map { ok.contains($0) ? Character($0) : "-" })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.isEmpty { s = "image" }
        if s.count > limit { s = String(s.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return s
    }
}

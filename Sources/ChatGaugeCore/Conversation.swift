import Foundation

public enum ChatRole: String, Codable, Sendable {
    case user, assistant, system
}

/// One message in a chat. Images are kept as JPEG/PNG bytes in memory; chat files store them alongside.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    public var images: [Data]
    public var createdAt: Date
    /// The model that wrote an assistant reply.
    public var model: String?
    /// A note shown under the reply (e.g. the low-memory fallback).
    public var note: String?
    /// Set when the reply failed or was stopped.
    public var error: String?
    /// File names of saved images (filled by the chat store).
    public var imageFiles: [String]

    public init(id: UUID = UUID(), role: ChatRole, text: String, images: [Data] = [], createdAt: Date = Date(),
                model: String? = nil, note: String? = nil, error: String? = nil, imageFiles: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.createdAt = createdAt
        self.model = model
        self.note = note
        self.error = error
        self.imageFiles = imageFiles
    }
}

/// Where a chat's title came from. Only `.firstLine` titles are replaced by a model title; `.user` (renamed by
/// hand) is never changed automatically.
public enum TitleSource: String, Codable, Sendable {
    case firstLine, model, user
}

public struct Conversation: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// Pinned chats sit at the top of the history (stored as `pinned: true` in the file header).
    public var pinned: Bool = false
    public var titleSource: TitleSource = .firstLine
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    /// The instructions preset in effect when the chat started.
    public var instructions: String?
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), title: String = "", createdAt: Date = Date(), updatedAt: Date? = nil,
                model: String? = nil, instructions: String? = nil, messages: [ChatMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.model = model
        self.instructions = instructions
        self.messages = messages
    }

    public var isEmpty: Bool { !messages.contains { $0.role == .user } }

    /// The reply still waiting for its first words, shown as the "Thinking…" row. Only while a reply streams, and
    /// only the last message: once text arrives, the stream ends, or it fails, the row becomes the reply bubble.
    public func pendingReplyID(streaming: Bool) -> UUID? {
        guard streaming, let last = messages.last, last.role == .assistant, last.text.isEmpty, last.error == nil
        else { return nil }
        return last.id
    }

    /// Title from the first user message: first line, at most 60 characters.
    public static func makeTitle(from text: String, hasImage: Bool = false) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return hasImage ? "Image" : "New chat" }
        if line.count <= 60 { return line }
        let cut = line.prefix(60)
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > 30 { return String(cut[..<sp]) + "…" }
        return String(cut) + "…"
    }

    /// The messages sent to Ollama: the system prompt (when any), then the history.
    /// Failed or empty assistant replies are left out; images are only sent with the newest `imageTurns`
    /// user messages that have them, which keeps long chats from re-sending every picture.
    public func wire(system: String?, imageTurns: Int = 4) -> [WireMessage] {
        var out: [WireMessage] = []
        if let s = system?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            out.append(WireMessage(role: "system", content: s))
        }
        let withImages = messages.enumerated().filter { $0.element.role == .user && !$0.element.images.isEmpty }.map(\.offset)
        let keep = Set(withImages.suffix(imageTurns))
        for (i, m) in messages.enumerated() {
            switch m.role {
            case .system: continue
            case .assistant:
                if m.text.isEmpty { continue }
                out.append(WireMessage(role: "assistant", content: m.text))
            case .user:
                out.append(WireMessage(role: "user", content: m.text, images: keep.contains(i) ? m.images : []))
            }
        }
        return out
    }
}

/// What the popover's status line shows.
public enum EngineStatus: Equatable, Sendable {
    case checking
    case driveMissing(volume: String)
    case folderMissing(path: String)
    case notChosen
    case serverDown
    case startingServer
    case noModels
    /// A model is picked but not loaded yet (it loads on the first message or when the popover opens).
    case idle(model: String)
    case loading(model: String)
    case ready(model: String)
    case generating(model: String)
    case failed(String)

    public enum Level: Sendable { case ok, busy, problem, neutral }

    public var level: Level {
        switch self {
        case .ready, .idle: return .ok
        case .loading, .generating, .startingServer, .checking: return .busy
        case .driveMissing, .folderMissing, .serverDown, .noModels, .failed, .notChosen: return .problem
        }
    }

    public var title: String {
        switch self {
        case .checking: return "Checking…"
        case .driveMissing(let v): return "Drive “\(v)” isn't connected"
        case .folderMissing: return "Models folder not found"
        case .notChosen: return "Choose a models folder"
        case .serverDown: return "Ollama isn't running"
        case .startingServer: return "Starting Ollama…"
        case .noModels: return "No chat models installed"
        case .idle: return "Ready"
        case .loading: return "Loading model…"
        case .ready: return "Ready"
        case .generating: return "Replying…"
        case .failed(let m): return m
        }
    }

    /// A longer hint under the title, when there is one.
    public var detail: String? {
        switch self {
        case .driveMissing(let v): return "Connect “\(v)” and ChatGauge picks up where it left off. Nothing is written while it's away."
        case .folderMissing(let p): return "ChatGauge can't find \(p). Pick the folder in Settings › Model & Server."
        case .notChosen: return "Pick the folder that holds your Ollama models in Settings › Model & Server."
        case .serverDown: return "Start Ollama, or click Start to ask macOS to start its service."
        case .noModels: return "Pull a vision model such as qwen2.5vl:7b (Settings › Diagnostics)."
        case .loading(let m): return "Loading \(m) into memory. The first load can take about 10 seconds."
        case .idle(let m): return "\(m) loads when you send the first message."
        default: return nil
        }
    }

    public var canChat: Bool {
        switch self {
        case .idle, .ready, .loading: return true
        default: return false
        }
    }

    public var model: String? {
        switch self {
        case .idle(let m), .loading(let m), .ready(let m), .generating(let m): return m
        default: return nil
        }
    }
}

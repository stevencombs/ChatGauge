import Foundation

/// One installed model from /api/tags.
public struct ModelInfo: Equatable, Sendable, Identifiable {
    public var name: String
    public var size: Int64
    public var digest: String?
    public var family: String?
    public var parameterSize: String?
    public var capabilities: [String]

    public var id: String { name }

    public init(name: String, size: Int64 = 0, digest: String? = nil, family: String? = nil,
                parameterSize: String? = nil, capabilities: [String] = []) {
        self.name = name
        self.size = size
        self.digest = digest
        self.family = family
        self.parameterSize = parameterSize
        self.capabilities = capabilities
    }

    /// Vision support: from capabilities when Ollama reports them, else by known family names.
    public var supportsVision: Bool {
        if !capabilities.isEmpty { return capabilities.contains("vision") }
        let n = name.lowercased()
        return ["vl", "llava", "vision", "gemma3", "minicpm-v", "moondream"].contains { n.contains($0) }
    }

    /// The part before the tag, e.g. "qwen2.5vl".
    public var base: String { String(name.split(separator: ":", maxSplits: 1).first ?? Substring(name)) }
    public var tag: String { name.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? "latest" }

    /// Billions of parameters from the tag ("7b", "32b", "3b") or parameter_size ("7.6B").
    public var billions: Double? {
        func num(_ s: String) -> Double? {
            let t = s.lowercased()
            guard t.hasSuffix("b"), let d = Double(t.dropLast()) else { return nil }
            return d
        }
        if let b = num(tag) { return b }
        if let p = parameterSize, let b = num(p) { return b }
        return nil
    }
}

/// One loaded model from /api/ps.
public struct LoadedModel: Equatable, Sendable {
    public var name: String
    public var size: Int64
    public var sizeVRAM: Int64
    public init(name: String, size: Int64, sizeVRAM: Int64) {
        self.name = name
        self.size = size
        self.sizeVRAM = sizeVRAM
    }
}

public enum OllamaParse {
    private static let shadow = try! NSRegularExpression(pattern: "^(llamacpp|ggml|mlx|ollama):[0-9a-f]{64}$")

    /// A name a person would pick: not Ollama 0.40's rollback shadow tag ("llamacpp:<digest>"), not a bare digest,
    /// not a ClipGauge update backup tag, not an embedding model.
    public static func isRealName(_ n: String) -> Bool {
        let t = n.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t == n else { return false }
        if shadow.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil { return false }
        let tag = n.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        if tag.count == 64 && tag.allSatisfy({ $0.isHexDigit }) { return false }
        if n.hasSuffix("-prev") { return false }
        return !n.lowercased().contains("embed")
    }

    private static func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

    /// /api/tags → unique chat models, sorted by name.
    public static func tags(_ data: Data) -> [ModelInfo]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = o["models"] as? [[String: Any]] else { return nil }
        var out: [ModelInfo] = []
        for d in rows {
            guard let n = (d["name"] as? String) ?? (d["model"] as? String), isRealName(n),
                  !out.contains(where: { $0.name == n }) else { continue }
            let caps = (d["capabilities"] as? [String]) ?? []
            if !caps.isEmpty && !caps.contains("completion") { continue }
            let det = d["details"] as? [String: Any]
            out.append(ModelInfo(name: n, size: int64(d["size"]), digest: d["digest"] as? String,
                                 family: det?["family"] as? String, parameterSize: det?["parameter_size"] as? String,
                                 capabilities: caps))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// /api/ps → loaded models.
    public static func ps(_ data: Data) -> [LoadedModel]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = o["models"] as? [[String: Any]] else { return nil }
        return rows.compactMap { d in
            guard let n = (d["name"] as? String) ?? (d["model"] as? String) else { return nil }
            return LoadedModel(name: n, size: int64(d["size"]), sizeVRAM: int64(d["size_vram"]))
        }
    }

    /// /api/version → "0.40.11".
    public static func version(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String
    }
}

/// A message sent to /api/chat. Images are raw JPEG/PNG bytes, sent base64.
public struct WireMessage: Equatable, Sendable {
    public var role: String
    public var content: String
    public var images: [Data]
    public init(role: String, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

public enum ChatRequest {
    /// keep_alive: -1 keeps the model loaded, 0 unloads it, nil uses Ollama's default (5 min).
    public static func body(model: String, messages: [WireMessage], keepAlive: Int? = nil, stream: Bool = true,
                            options: [String: Any]? = nil) -> Data {
        var o: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": messages.map { m -> [String: Any] in
                var d: [String: Any] = ["role": m.role, "content": m.content]
                if !m.images.isEmpty { d["images"] = m.images.map { $0.base64EncodedString() } }
                return d
            },
        ]
        if let k = keepAlive { o["keep_alive"] = k }
        if let options { o["options"] = options }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    /// Preload (`keep_alive` -1 or a duration) or unload (`keep_alive` 0) with an empty /api/generate request.
    public static func keepAliveBody(model: String, keepAlive: Int) -> Data {
        let o: [String: Any] = ["model": model, "keep_alive": keepAlive]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }
}

/// One parsed line of a streamed /api/chat reply.
public struct ChatChunk: Equatable, Sendable {
    public var content: String
    public var done: Bool
    public var error: String?
    public var doneReason: String?
    public var evalCount: Int?
    public var evalDurationNs: Int64?
    public var loadDurationNs: Int64?

    public init(content: String = "", done: Bool = false, error: String? = nil, doneReason: String? = nil,
                evalCount: Int? = nil, evalDurationNs: Int64? = nil, loadDurationNs: Int64? = nil) {
        self.content = content
        self.done = done
        self.error = error
        self.doneReason = doneReason
        self.evalCount = evalCount
        self.evalDurationNs = evalDurationNs
        self.loadDurationNs = loadDurationNs
    }

    public static func parse(_ line: Data) -> ChatChunk? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let msg = o["message"] as? [String: Any]
        return ChatChunk(content: (msg?["content"] as? String) ?? (o["response"] as? String) ?? "",
                         done: (o["done"] as? Bool) ?? false,
                         error: o["error"] as? String,
                         doneReason: o["done_reason"] as? String,
                         evalCount: (o["eval_count"] as? NSNumber)?.intValue,
                         evalDurationNs: (o["eval_duration"] as? NSNumber)?.int64Value,
                         loadDurationNs: (o["load_duration"] as? NSNumber)?.int64Value)
    }

    /// Tokens per second, when Ollama reported it.
    public var tokensPerSecond: Double? {
        guard let c = evalCount, let d = evalDurationNs, d > 0 else { return nil }
        return Double(c) / (Double(d) / 1e9)
    }
}

/// Splits a byte stream into NDJSON lines; partial lines wait for the next chunk.
public struct NDJSONBuffer: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) -> [ChatChunk] {
        buffer.append(data)
        var out: [ChatChunk] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let c = ChatChunk.parse(Data(line)) { out.append(c) }
        }
        return out
    }

    /// Whatever is left when the stream ends (a last line without a newline).
    public mutating func finish() -> [ChatChunk] {
        defer { buffer = Data() }
        let rest = buffer.trimmingWhitespace()
        guard !rest.isEmpty, let c = ChatChunk.parse(rest) else { return [] }
        return [c]
    }
}

extension Data {
    func trimmingWhitespace() -> Data {
        let ws: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        guard let s = firstIndex(where: { !ws.contains($0) }), let e = lastIndex(where: { !ws.contains($0) }) else { return Data() }
        return Data(self[s...e])
    }
}

public enum OllamaError: Error, Equatable, CustomStringConvertible {
    case notLoopback
    case unreachable(String)
    case http(Int, String?)
    case server(String)

    public var description: String {
        switch self {
        case .notLoopback: return "The server address isn't on this Mac. ChatGauge only talks to a local Ollama."
        case .unreachable(let m): return "Ollama isn't answering (\(m))."
        case .http(let c, let m): return "Ollama answered HTTP \(c)\(m.map { ": \($0)" } ?? "")."
        case .server(let m): return Self.friendly(m)
        }
    }

    public static func friendly(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("not found") && (l.contains("model") || l.contains("pull")) {
            return "That model isn't installed in this Ollama. Pick another in the model menu."
        }
        if l.contains("does not support") && l.contains("image") { return "This model can't read images. Pick a vision model such as qwen2.5vl." }
        return raw
    }
}

/// HTTP client for a loopback Ollama. Sends nothing anywhere else.
public final class OllamaClient: @unchecked Sendable {
    public let base: URL
    private let session: URLSession

    /// Returns nil when the URL isn't loopback.
    public init?(baseURL: String, session: URLSession? = nil) {
        guard let u = Self.loopback(baseURL) else { return nil }
        base = u
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 10
            c.urlCache = nil
            c.httpCookieStorage = nil
            self.session = URLSession(configuration: c)
        }
    }

    public static func loopback(_ s: String) -> URL? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let h = u.host,
              u.scheme == "http" || u.scheme == "https",
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(h.lowercased()) else { return nil }
        return u
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        r.httpMethod = "GET"
        do {
            let (d, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw OllamaError.http(code, nil) }
            return d
        } catch let e as OllamaError { throw e } catch { throw OllamaError.unreachable(error.localizedDescription) }
    }

    public func version(timeout: TimeInterval = 3) async throws -> String {
        guard let v = OllamaParse.version(try await get("api/version", timeout: timeout)) else { throw OllamaError.server("bad /api/version") }
        return v
    }

    public func tags(timeout: TimeInterval = 5) async throws -> [ModelInfo] {
        guard let t = OllamaParse.tags(try await get("api/tags", timeout: timeout)) else { throw OllamaError.server("bad /api/tags") }
        return t
    }

    public func ps(timeout: TimeInterval = 5) async throws -> [LoadedModel] {
        guard let p = OllamaParse.ps(try await get("api/ps", timeout: timeout)) else { throw OllamaError.server("bad /api/ps") }
        return p
    }

    /// Loads (keepAlive -1 / seconds) or unloads (0) a model. Loading can take a while on a cold start.
    public func keepAlive(model: String, _ keepAlive: Int, timeout: TimeInterval = 180) async throws {
        var r = URLRequest(url: base.appendingPathComponent("api/generate"), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = ChatRequest.keepAliveBody(model: model, keepAlive: keepAlive)
        do {
            let (d, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
                throw OllamaError.http(code, msg)
            }
        } catch let e as OllamaError { throw e } catch { throw OllamaError.unreachable(error.localizedDescription) }
    }

    /// The streaming chat request (the app runs it with a delegate so it can stop mid-reply).
    public func chatRequest(model: String, messages: [WireMessage], keepAlive: Int?, timeout: TimeInterval = 600) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent("api/chat"), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = ChatRequest.body(model: model, messages: messages, keepAlive: keepAlive)
        return r
    }

    /// One non-streaming /api/chat reply (used for chat titles). Never pulls: an unknown model is just an error.
    public func chatOnce(model: String, messages: [WireMessage], keepAlive: Int?, maxTokens: Int = 32,
                         timeout: TimeInterval = 60) async throws -> String {
        var r = URLRequest(url: base.appendingPathComponent("api/chat"), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = ChatRequest.body(model: model, messages: messages, keepAlive: keepAlive, stream: false,
                                      options: ["num_predict": maxTokens, "temperature": 0.2])
        do {
            let (d, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let chunk = ChatChunk.parse(d.trimmingWhitespace()) else {
                throw OllamaError.http(code, ChatChunk.parse(d)?.error)
            }
            if let e = chunk.error { throw OllamaError.http(code, e) }
            return chunk.content
        } catch let e as OllamaError { throw e } catch { throw OllamaError.unreachable(error.localizedDescription) }
    }

    /// /api/pull request body (only ever sent from a button the user clicked).
    public func pullRequest(model: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent("api/pull"), timeoutInterval: 3600)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        return r
    }
}

/// Pull progress line from /api/pull.
public struct PullProgress: Equatable, Sendable {
    public var status: String
    public var total: Int64?
    public var completed: Int64?
    public var error: String?
    public static func parse(_ line: Data) -> PullProgress? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return PullProgress(status: (o["status"] as? String) ?? "", total: (o["total"] as? NSNumber)?.int64Value,
                            completed: (o["completed"] as? NSNumber)?.int64Value, error: o["error"] as? String)
    }
    public var fraction: Double? {
        guard let t = total, t > 0, let c = completed else { return nil }
        return min(1, Double(c) / Double(t))
    }
}

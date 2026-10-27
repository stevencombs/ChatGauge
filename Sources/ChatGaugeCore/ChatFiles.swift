import Foundation

/// A saved chat in the history list.
public struct ChatSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    public var preview: String
    public var messageCount: Int
    public var url: URL
    /// Lower-cased title and text, for search.
    public var searchText: String

    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { searchText.contains($0) }
    }
}

/// Reads and writes chat files. Markdown (with a small front matter and per-message markers so it can be
/// read back) or JSON. Images live in `_images/<chat id>/` next to the chat files.
public enum ChatCodec {
    public static let formatVersion = 1
    static let marker = "<!-- chatgauge-message "

    static var iso: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func date(_ s: String) -> Date? {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// The relative image folder for a chat.
    public static func imageFolder(for id: UUID) -> String { "_images/\(id.uuidString.lowercased())" }

    // MARK: Markdown

    struct Meta: Codable {
        var role: ChatRole
        var id: UUID
        var createdAt: String
        var model: String?
        var note: String?
        var error: String?
        var images: [String]?
    }

    public static func markdown(_ c: Conversation, displayDate: (Date) -> String = defaultDisplay) -> String {
        var out = "---\n"
        out += "chatgauge: \(formatVersion)\n"
        out += "id: \(c.id.uuidString.lowercased())\n"
        out += "title: \(yamlString(c.title))\n"
        out += "created: \(iso.string(from: c.createdAt))\n"
        out += "updated: \(iso.string(from: c.updatedAt))\n"
        if let m = c.model { out += "model: \(yamlString(m))\n" }
        if let i = c.instructions { out += "instructions: \(yamlString(i))\n" }
        out += "---\n\n# \(c.title.isEmpty ? "Chat" : c.title)\n"
        for m in c.messages where m.role != .system {
            let meta = Meta(role: m.role, id: m.id, createdAt: iso.string(from: m.createdAt), model: m.model, note: m.note,
                            error: m.error, images: m.imageFiles.isEmpty ? nil : m.imageFiles)
            out += "\n" + marker + safeJSON(meta) + " -->\n"
            let who = m.role == .user ? "You" : (m.model ?? "Assistant")
            out += "**\(who)** · \(displayDate(m.createdAt))\n\n"
            if !m.text.isEmpty { out += m.text + "\n" }
            for (i, f) in m.imageFiles.enumerated() {
                out += "\n![Image \(i + 1)](\(f.replacingOccurrences(of: " ", with: "%20")))\n"
            }
            if let n = m.note { out += "\n> \(n.replacingOccurrences(of: "\n", with: " "))\n" }
            if let e = m.error { out += "\n> ⚠️ \(e.replacingOccurrences(of: "\n", with: " "))\n" }
        }
        return out
    }

    public static func defaultDisplay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    /// Reads a file written by `markdown(_:)`. Images are not loaded (see `imageFiles`).
    public static func parseMarkdown(_ s: String) -> Conversation? {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fm: [String: String] = [:]
        for l in lines[1..<end] {
            guard let colon = l.firstIndex(of: ":") else { continue }
            let k = String(l[..<colon]).trimmingCharacters(in: .whitespaces)
            fm[k] = unyaml(String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        guard fm["chatgauge"] != nil, let id = fm["id"].flatMap(UUID.init(uuidString:)) else { return nil }
        let created = fm["created"].flatMap(date) ?? Date(timeIntervalSince1970: 0)
        var c = Conversation(id: id, title: fm["title"] ?? "", createdAt: created,
                             updatedAt: fm["updated"].flatMap(date) ?? created, model: fm["model"], instructions: fm["instructions"])

        var current: (Meta, [String])?
        func flush() {
            guard let (meta, body) = current else { return }
            var b = body
            // Drop the "**You** · date" line and the blank line after it.
            if let first = b.firstIndex(where: { !$0.isEmpty }), b[first].hasPrefix("**") { b.removeSubrange(...first) }
            // Drop trailing rendering we added: image links, note and error quotes, blank lines.
            let imageLines = Set((meta.images ?? []).enumerated().map { "![Image \($0.offset + 1)](\($0.element.replacingOccurrences(of: " ", with: "%20")))" })
            while let last = b.last, last.isEmpty || imageLines.contains(last)
                    || (meta.note != nil && last == "> \(meta.note!.replacingOccurrences(of: "\n", with: " "))")
                    || (meta.error != nil && last == "> ⚠️ \(meta.error!.replacingOccurrences(of: "\n", with: " "))") {
                b.removeLast()
            }
            while let f = b.first, f.isEmpty { b.removeFirst() }
            c.messages.append(ChatMessage(id: meta.id, role: meta.role, text: b.joined(separator: "\n"),
                                          createdAt: date(meta.createdAt) ?? created, model: meta.model, note: meta.note,
                                          error: meta.error, imageFiles: meta.images ?? []))
        }
        for l in lines[(end + 1)...] {
            if l.hasPrefix(marker), l.hasSuffix(" -->") {
                flush()
                let json = String(l.dropFirst(marker.count).dropLast(4))
                if let meta = try? JSONDecoder().decode(Meta.self, from: Data(json.utf8)) {
                    current = (meta, [])
                } else {
                    current = nil
                }
            } else if current != nil {
                current!.1.append(l)
            }
        }
        flush()
        return c
    }

    static func safeJSON<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let s = (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // Keep the HTML comment intact: escape '>' and newlines can't occur (JSON escapes them).
        return s.replacingOccurrences(of: ">", with: "\\u003e").replacingOccurrences(of: "--", with: "-\\u002d")
    }

    static func yamlString(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        let data = (try? JSONEncoder().encode(one)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func unyaml(_ s: String) -> String {
        if s.hasPrefix("\""), let v = try? JSONDecoder().decode(String.self, from: Data(s.utf8)) { return v }
        return s
    }

    // MARK: JSON

    struct JSONChat: Codable {
        var app = "ChatGauge"
        var formatVersion = ChatCodec.formatVersion
        var id: UUID
        var title: String
        var createdAt: String
        var updatedAt: String
        var model: String?
        var instructions: String?
        var messages: [JSONMessage]
    }

    struct JSONMessage: Codable {
        var id: UUID
        var role: ChatRole
        var text: String
        var createdAt: String
        var model: String?
        var note: String?
        var error: String?
        var images: [String]?
    }

    public static func json(_ c: Conversation) -> Data {
        let j = JSONChat(id: c.id, title: c.title, createdAt: iso.string(from: c.createdAt), updatedAt: iso.string(from: c.updatedAt),
                         model: c.model, instructions: c.instructions,
                         messages: c.messages.filter { $0.role != .system }.map {
                             JSONMessage(id: $0.id, role: $0.role, text: $0.text, createdAt: iso.string(from: $0.createdAt), model: $0.model,
                                         note: $0.note, error: $0.error, images: $0.imageFiles.isEmpty ? nil : $0.imageFiles)
                         })
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(j)) ?? Data()
    }

    public static func parseJSON(_ d: Data) -> Conversation? {
        guard let j = try? JSONDecoder().decode(JSONChat.self, from: d), j.app == "ChatGauge" else { return nil }
        let created = date(j.createdAt) ?? Date(timeIntervalSince1970: 0)
        return Conversation(id: j.id, title: j.title, createdAt: created, updatedAt: date(j.updatedAt) ?? created,
                            model: j.model, instructions: j.instructions,
                            messages: j.messages.map {
                                ChatMessage(id: $0.id, role: $0.role, text: $0.text, createdAt: date($0.createdAt) ?? created,
                                            model: $0.model, note: $0.note, error: $0.error, imageFiles: $0.images ?? [])
                            })
    }

    // MARK: Names

    /// "2026-10-26 2304 Title words [ab12cd34].md": readable, sortable, unique by the id suffix.
    public static func fileName(for c: Conversation, format: ChatFileFormat) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let title = safeTitle(c.title)
        return "\(f.string(from: c.createdAt)) \(title.isEmpty ? "Chat" : title) [\(shortID(c.id))].\(format.fileExtension)"
    }

    public static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    static func safeTitle(_ t: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^\n\r\t").union(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView(t.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
            .split(separator: " ").joined(separator: " ")
        return String(cleaned.prefix(50)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
    }
}

/// The chats folder: list, save, load, rename, delete. Everything stays in the folder the user chose.
public struct ChatLibrary: Sendable {
    public var folder: URL

    public init(folder: URL) { self.folder = folder }

    private var fm: FileManager { .default }

    public func list() -> [ChatSummary] {
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> ChatSummary? in
            guard let c = read(url) else { return nil }
            let body = c.messages.map(\.text).joined(separator: " ")
            let preview = c.messages.last(where: { !$0.text.isEmpty })?.text.replacingOccurrences(of: "\n", with: " ") ?? ""
            return ChatSummary(id: c.id, title: c.title.isEmpty ? "Chat" : c.title, createdAt: c.createdAt, updatedAt: c.updatedAt,
                               model: c.model, preview: String(preview.prefix(120)), messageCount: c.messages.count, url: url,
                               searchText: (c.title + " " + body).lowercased())
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Reads a chat (without image bytes).
    public func read(_ url: URL) -> Conversation? {
        guard let d = fm.contents(atPath: url.path) else { return nil }
        switch url.pathExtension.lowercased() {
        case "md": return ChatCodec.parseMarkdown(String(decoding: d, as: UTF8.self))
        case "json": return ChatCodec.parseJSON(d)
        default: return nil
        }
    }

    /// Reads a chat and its images.
    public func load(_ url: URL) -> Conversation? {
        guard var c = read(url) else { return nil }
        for i in c.messages.indices {
            c.messages[i].images = c.messages[i].imageFiles.compactMap { fm.contents(atPath: folder.appendingPathComponent($0).path) }
        }
        return c
    }

    /// Files already saved for this chat id (any format, any title).
    public func existing(_ id: UUID) -> [URL] {
        let tag = "[\(ChatCodec.shortID(id))]."
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.contains(tag) && read($0)?.id == id }
    }

    /// Writes the chat (images first), replacing an older file for the same chat. Returns the saved file
    /// and the conversation with `imageFiles` filled in.
    @discardableResult
    public func save(_ conversation: Conversation, format: ChatFileFormat) throws -> (URL, Conversation) {
        var c = conversation
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let imgDir = ChatCodec.imageFolder(for: c.id)
        for i in c.messages.indices where !c.messages[i].images.isEmpty && c.messages[i].imageFiles.count != c.messages[i].images.count {
            try fm.createDirectory(at: folder.appendingPathComponent(imgDir), withIntermediateDirectories: true)
            var names: [String] = []
            for (n, data) in c.messages[i].images.enumerated() {
                let ext = Self.isPNG(data) ? "png" : "jpg"
                let rel = "\(imgDir)/\(ChatCodec.shortID(c.messages[i].id))-\(n + 1).\(ext)"
                try data.write(to: folder.appendingPathComponent(rel), options: .atomic)
                names.append(rel)
            }
            c.messages[i].imageFiles = names
        }
        let url = folder.appendingPathComponent(ChatCodec.fileName(for: c, format: format))
        let data = format == .markdown ? Data(ChatCodec.markdown(c).utf8) : ChatCodec.json(c)
        try data.write(to: url, options: .atomic)
        for old in existing(c.id) where old.standardizedFileURL != url.standardizedFileURL {
            try? fm.removeItem(at: old)
        }
        return (url, c)
    }

    public func rename(_ id: UUID, to title: String, format: ChatFileFormat) throws {
        guard let url = existing(id).first, var c = load(url) else { return }
        c.title = String(title.replacingOccurrences(of: "\n", with: " ").prefix(120))
        let fmt = ChatFileFormat(rawValue: url.pathExtension == "json" ? "json" : "markdown") ?? format
        try save(c, format: fmt)
    }

    /// Moves the chat file and its images to the Trash.
    public func delete(_ id: UUID) throws {
        for url in existing(id) { try fm.trashItem(at: url, resultingItemURL: nil) }
        let img = folder.appendingPathComponent(ChatCodec.imageFolder(for: id))
        if fm.fileExists(atPath: img.path) { try? fm.trashItem(at: img, resultingItemURL: nil) }
    }

    static func isPNG(_ d: Data) -> Bool { d.starts(with: [0x89, 0x50, 0x4E, 0x47]) }
}

import Foundation

/// The history sections, in sidebar order.
public enum ChatGroup: String, CaseIterable, Sendable {
    case pinned = "Pinned"
    case today = "Today"
    case yesterday = "Yesterday"
    case lastWeek = "Last 7 days"
    case older = "Older"
}

public struct ChatSection: Equatable, Sendable {
    public var group: ChatGroup
    public var chats: [ChatSummary]
}

/// Groups and orders the chat history. `now` and `calendar` are passed in so it can be tested.
public enum ChatGrouping {
    public static func group(of s: ChatSummary, now: Date, calendar: Calendar) -> ChatGroup {
        if s.pinned { return .pinned }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: s.updatedAt)
        if day >= today { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), day >= y { return .yesterday }
        if let w = calendar.date(byAdding: .day, value: -7, to: today), day >= w { return .lastWeek }
        return .older
    }

    /// Non-empty sections in order, newest first within each.
    public static func sections(_ chats: [ChatSummary], now: Date = Date(), calendar: Calendar = .current) -> [ChatSection] {
        let sorted = chats.sorted { $0.updatedAt > $1.updatedAt }
        var by: [ChatGroup: [ChatSummary]] = [:]
        for c in sorted { by[group(of: c, now: now, calendar: calendar), default: []].append(c) }
        return ChatGroup.allCases.compactMap { g in by[g].map { ChatSection(group: g, chats: $0) } }
    }

    /// The sidebar order flattened (pinned first, then newest), used for previous/next.
    public static func ordered(_ chats: [ChatSummary], now: Date = Date(), calendar: Calendar = .current) -> [ChatSummary] {
        sections(chats, now: now, calendar: calendar).flatMap(\.chats)
    }

    /// The chat above (`step` -1) or below (+1) `current` in `ordered`. An unsaved/unknown current chat steps to
    /// the top of the list. Stops at the ends (no wrap); nil when there's nowhere to go.
    public static func neighbor(of current: UUID?, in ordered: [ChatSummary], step: Int) -> ChatSummary? {
        guard !ordered.isEmpty else { return nil }
        guard let id = current, let i = ordered.firstIndex(where: { $0.id == id }) else { return ordered.first }
        let j = i + step
        return ordered.indices.contains(j) ? ordered[j] : nil
    }

    /// The popover's switcher list: pinned first, then the most recent, `limit` in all.
    public static func switcher(_ chats: [ChatSummary], limit: Int = 10) -> [ChatSummary] {
        let sorted = chats.sorted { $0.updatedAt > $1.updatedAt }
        return Array((sorted.filter(\.pinned) + sorted.filter { !$0.pinned }).prefix(limit))
    }

    /// The chat to reopen at launch: the one most recently updated.
    public static func lastChat(_ chats: [ChatSummary]) -> ChatSummary? {
        chats.max { $0.updatedAt < $1.updatedAt }
    }
}

/// Short chat titles from the local model: the prompt, and cleanup of what comes back.
public enum AutoTitle {
    public static let instruction = "Write a short title (3 to 6 words) for this chat. Reply with the title only: no quotes, no punctuation at the end, no explanation."

    /// The request messages: the first exchange (text only, trimmed) and the instruction.
    public static func messages(for c: Conversation) -> [WireMessage]? {
        guard let q = c.messages.first(where: { $0.role == .user }),
              let a = c.messages.first(where: { $0.role == .assistant && !$0.text.isEmpty && $0.error == nil })
        else { return nil }
        let user = q.text.isEmpty ? "(an image)" : String(q.text.prefix(1500))
        return [WireMessage(role: "user", content: user),
                WireMessage(role: "assistant", content: String(a.text.prefix(1500))),
                WireMessage(role: "user", content: instruction)]
    }

    /// Cleans a model's reply into a title, or nil if it isn't usable (then the first-line title stays).
    public static func clean(_ raw: String) -> String? {
        var s = raw
        // Reasoning models may wrap their thinking in <think>…</think>.
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }
        s = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        for p in ["title:", "chat title:", "**title:**"] where s.lowercased().hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
        let strip = CharacterSet(charactersIn: "\"'“”‘’`*_ .:;!?,-–—").union(.whitespaces)
        s = s.trimmingCharacters(in: strip)
        s = s.split(separator: " ").joined(separator: " ")
        let words = s.split(separator: " ")
        guard !words.isEmpty else { return nil }
        if words.count > 8 { s = words.prefix(8).joined(separator: " ") }
        s = String(s.prefix(60)).trimmingCharacters(in: strip)
        return s.isEmpty ? nil : s
    }
}

/// ⌘⌫ moves the chat to the Trash only when it wouldn't eat text: no text field is being edited, or the one
/// being edited is empty. (In a text field with text, ⌘⌫ keeps its usual "delete to start of line".)
public enum TrashShortcut {
    public static func handles(editingText: Bool, fieldIsEmpty: Bool) -> Bool { !editingText || fieldIsEmpty }
}

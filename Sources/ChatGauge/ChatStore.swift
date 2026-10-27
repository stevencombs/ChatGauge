import AppKit
import ChatGaugeCore
import Combine
import UniformTypeIdentifiers

/// Saved chats in the folder chosen in Settings → Chat.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var summaries: [ChatSummary] = []
    @Published var query = ""
    @Published private(set) var lastError: String?

    /// Bumped to move keyboard focus to the chat window's search field (⌘F, "Search…" in the popover).
    @Published var searchFocusToken = 0
    /// The chat engine, for switching chats (set by the app delegate).
    weak var engine: ChatEngine?

    private let settingsStore: SettingsStore
    private var format: ChatFileFormat { settingsStore.settings.chatFormat }
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        settingsStore.$settings.map(\.chatsFolder).removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
    }

    var folder: URL { AppPaths.chats(settingsStore.settings) }
    var library: ChatLibrary { ChatLibrary(folder: folder) }

    /// A short, home-relative folder path for display.
    var folderDisplay: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = folder.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    var filtered: [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? summaries : summaries.filter { $0.matches(q) }
    }

    func refresh() {
        summaries = library.list()
    }

    /// Saves a chat (when saving is on). Returns the conversation with image file names filled in.
    @discardableResult
    func save(_ c: Conversation) -> Conversation? {
        guard settingsStore.settings.saveChats, !c.isEmpty else { return nil }
        do {
            let (_, saved) = try library.save(c, format: settingsStore.settings.chatFormat)
            lastError = nil
            refresh()
            return saved
        } catch {
            lastError = "Couldn't save the chat: \(error.localizedDescription)"
            return nil
        }
    }

    func load(_ s: ChatSummary) -> Conversation? { library.load(s.url) }

    func rename(_ id: UUID, to title: String) {
        if let e = engine, e.conversation.id == id {
            e.conversation.title = title
            e.conversation.titleSource = .user
        }
        do { try library.rename(id, to: title, format: format) } catch {
            lastError = "Couldn't rename: \(error.localizedDescription)"
        }
        refresh()
    }

    func delete(_ id: UUID) {
        do { try library.delete(id) } catch { lastError = "Couldn't delete: \(error.localizedDescription)" }
        if let e = engine, e.conversation.id == id { e.open(Conversation()) }
        refresh()
    }

    // MARK: Organizing

    /// History sections (Pinned, Today, Yesterday, Last 7 days, Older). While searching: one flat list.
    var sections: [ChatSection] { ChatGrouping.sections(summaries) }
    /// The sidebar order, for previous/next.
    var ordered: [ChatSummary] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? ChatGrouping.ordered(summaries) : filtered
    }
    /// The popover switcher's chats: pinned first, then recent, 10 in all.
    var switcher: [ChatSummary] { ChatGrouping.switcher(summaries, limit: 10) }
    var current: ChatSummary? { engine.flatMap { e in summaries.first { $0.id == e.conversation.id } } }

    /// Opens a saved chat (saving the current one first). Not while a reply is streaming.
    @discardableResult
    func open(_ s: ChatSummary) -> Bool {
        guard let e = engine, !e.isStreaming else { NSSound.beep(); return false }
        guard s.id != e.conversation.id else { return true }
        if !e.conversation.isEmpty { save(e.conversation) }
        guard let c = load(s) else { lastError = "Couldn't open that chat."; return false }
        e.open(c)
        return true
    }

    /// ⌘⌥↑ (-1) / ⌘⌥↓ (+1): the chat above or below in the sidebar.
    @discardableResult
    func step(_ n: Int) -> Bool {
        guard let e = engine, let s = ChatGrouping.neighbor(of: e.conversation.id, in: ordered, step: n) else {
            NSSound.beep(); return false
        }
        return open(s)
    }

    func setPinned(_ s: ChatSummary, _ pinned: Bool) {
        if let e = engine, e.conversation.id == s.id { e.conversation.pinned = pinned }
        do { try library.setPinned(s.id, pinned, format: format) } catch {
            lastError = "Couldn't pin: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Duplicates a chat and opens the copy.
    @discardableResult
    func duplicate(_ s: ChatSummary) -> Conversation? {
        if let e = engine, e.conversation.id == s.id, !e.conversation.isEmpty { save(e.conversation) }
        do {
            let copy = try library.duplicate(s.id, format: format)
            refresh()
            if let copy, let cs = summaries.first(where: { $0.id == copy.id }) { open(cs) }
            return copy
        } catch {
            lastError = "Couldn't duplicate: \(error.localizedDescription)"
            return nil
        }
    }

    /// A model-made title for a chat that isn't open any more (kept only if it still has its first-line title).
    func applyModelTitle(_ id: UUID, _ title: String) {
        _ = try? library.applyModelTitle(id, title, format: format)
        refresh()
    }

    func exportMarkdown(_ s: ChatSummary, to url: URL, copyImages: Bool) -> Bool {
        if let e = engine, e.conversation.id == s.id, !e.conversation.isEmpty { save(e.conversation) }
        do { try library.exportMarkdown(s.id, to: url, copyImages: copyImages); return true } catch {
            lastError = "Couldn't export: \(error.localizedDescription)"
            return false
        }
    }

    /// "Export as Markdown…": a save panel with a "Copy images" checkbox.
    func exportWithPanel(_ s: ChatSummary) {
        let hasImages = (library.read(s.url)?.messages.contains { !$0.imageFiles.isEmpty }) ?? false
        let panel = NSSavePanel()
        panel.title = "Export Chat as Markdown"
        let base = ChatCodec.safeTitle(s.title)
        panel.nameFieldStringValue = (base.isEmpty ? "Chat" : base) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let box = NSButton(checkboxWithTitle: "Copy images into a folder beside it", target: nil, action: nil)
        box.state = hasImages ? .on : .off
        box.isEnabled = hasImages
        let pad = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        box.frame.origin = NSPoint(x: 12, y: 8)
        box.sizeToFit()
        pad.addSubview(box)
        panel.accessoryView = pad
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if exportMarkdown(s, to: url, copyImages: box.state == .on) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// At launch (Settings → Chat → Reopen the last chat): open the most recently updated chat.
    @discardableResult
    func reopenLast() -> Bool {
        refresh()
        guard let s = ChatGrouping.lastChat(summaries), let e = engine, e.conversation.isEmpty,
              let c = load(s) else { return false }
        e.open(c)
        return true
    }

    /// Asks before moving a chat to the Trash: a sheet on `window` when given, otherwise a dialog.
    func confirmTrash(_ s: ChatSummary, window: NSWindow?, done: ((Bool) -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = "Move this chat to the Trash?"
        a.informativeText = s.title
        a.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            let yes = r == .alertFirstButtonReturn
            if yes { self?.delete(s.id) }
            done?(yes)
        }
        if let window { a.beginSheetModal(for: window, completionHandler: finish) } else { finish(a.runModal()) }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func reveal(_ s: ChatSummary) { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
}

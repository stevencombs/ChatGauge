import AppKit
import ChatGaugeCore
import Combine

/// Saved chats in the folder chosen in Settings → Chat.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var summaries: [ChatSummary] = []
    @Published var query = ""
    @Published private(set) var lastError: String?

    private let settingsStore: SettingsStore
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
        do { try library.rename(id, to: title, format: settingsStore.settings.chatFormat) } catch {
            lastError = "Couldn't rename: \(error.localizedDescription)"
        }
        refresh()
    }

    func delete(_ id: UUID) {
        do { try library.delete(id) } catch { lastError = "Couldn't delete: \(error.localizedDescription)" }
        refresh()
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func reveal(_ s: ChatSummary) { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
}

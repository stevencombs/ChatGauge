import AppKit
import ChatGaugeCore
import Combine
import SwiftUI

/// The full chat window: history on the left, the current chat on the right.
struct ChatWindowView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var store: ChatStore
    @ObservedObject var actions: AppActions
    @ObservedObject var hub: FeatureHub
    @ViewState private var renaming: ChatSummary?
    @ViewState private var deleting: ChatSummary?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $renaming) { s in
            NamePrompt(title: "Rename chat", initial: s.title) { name in
                store.rename(s.id, to: name)
                renaming = nil
            }
        }
        .alert("Move this chat to the Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let d = deleting { store.delete(d.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.title ?? "")
        }
        .onAppear { store.refresh() }
        .onReceive(store.$searchFocusToken.dropFirst()) { _ in searchFocused = true }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats", text: $store.query).textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = store.filtered.first { open(first) } }
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.25)))
                Button { engine.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .help("New chat (⌘N)").keyboardShortcut("n", modifiers: .command)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !engine.conversation.isEmpty && !store.summaries.contains(where: { $0.id == engine.conversation.id }) {
                        sectionLabel("CURRENT")
                        row(title: engine.conversation.title.isEmpty ? "New chat" : engine.conversation.title,
                            subtitle: engine.settings.saveChats ? "Not saved yet" : "Saving is off", selected: true)
                    }
                    if store.query.isEmpty {
                        ForEach(store.sections, id: \.group) { sec in
                            sectionLabel(sec.group.rawValue.uppercased())
                            ForEach(sec.chats) { s in chatRow(s) }
                        }
                    } else {
                        sectionLabel("RESULTS")
                        ForEach(store.filtered) { s in chatRow(s) }
                    }
                    if store.filtered.isEmpty {
                        Text(store.query.isEmpty ? "No saved chats yet." : "No chats match.")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                }
            }
            if let e = store.lastError { Text(e).font(.caption).foregroundStyle(Palette.red) }
            Button { store.revealFolder() } label: {
                Label(store.folderDisplay, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open the chats folder (change it in Settings → Chat)")
        }
        .padding(10)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 8).padding(.bottom, 2).padding(.horizontal, 2)
    }

    private func chatRow(_ s: ChatSummary) -> some View {
        row(title: s.title, subtitle: Self.when(s.updatedAt), selected: s.id == engine.conversation.id, pinned: s.pinned)
            // Pinning moves a row to another section; a fresh identity makes sure the pin mark is redrawn with it.
            .id("\(s.id.uuidString)-\(s.pinned)")
            .contentShape(Rectangle())
            .onTapGesture { open(s) }
            .contextMenu {
                Button(s.pinned ? "Unpin" : "Pin") { store.setPinned(s, !s.pinned) }
                Button("Rename…") { renaming = s }
                Button("Duplicate") { store.duplicate(s) }
                Button("Export as Markdown…") { store.exportWithPanel(s) }
                Button("Show in Finder") { store.reveal(s) }
                Divider()
                Button("Move to Trash…") { deleting = s }
            }
    }

    private func row(title: String, subtitle: String, selected: Bool, pinned: Bool = false) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(selected ? Color.primary.opacity(0.7) : .secondary)
            }
            Spacer(minLength: 0)
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).rotationEffect(.degrees(30))
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func open(_ s: ChatSummary) { store.open(s) }

    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.timeStyle = .short; return f.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        f.setLocalizedDateFormatFromTemplate(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy")
        return f.string(from: d)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: engine.composerMode == .image ? "photo" : "sparkles").foregroundStyle(.purple)
                Picker("", selection: $engine.composerMode) {
                    Text("Chat").tag(ChatComposerMode.chat)
                    Text("Generate image").tag(ChatComposerMode.image)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                if engine.composerMode == .chat {
                    ModelChip(engine: engine, onInstall: { actions.installModel($0) })
                } else {
                    ImageModelChip(engine: engine)
                }
                if let menu = hub.instructionsMenu { menu }
                Spacer()
                Button { copyChat() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy this chat as Markdown")
                    .disabled(engine.conversation.messages.isEmpty)
                Button { store.revealFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Open the chats folder")
            }
            BannerView(engine: engine)
            Group {
                if engine.conversation.messages.isEmpty {
                    EmptyStateView(engine: engine, actions: actions)
                } else {
                    MessagesView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .modifier(ImageDropModifier(engine: engine))
            ComposerView(engine: engine, voice: hub.voiceButton, attach: { actions.attachImages() })
            HStack(spacing: 6) {
                StatusDot(level: engine.status.level)
                StatusLine(engine: engine)
                Text("· \(footerPlace) · nothing leaves this Mac")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
        }
        .padding(14)
    }

    private var footerPlace: String {
        let where_ = engine.location.volumeName ?? "This Mac"
        let u = URL(string: engine.settings.serverURL)
        let server = u.map { "\($0.host ?? "127.0.0.1"):\($0.port ?? 11434)" } ?? engine.settings.serverURL
        return "\(where_) · \(server)"
    }

    private func copyChat() {
        let md = ChatCodec.markdown(engine.conversation)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}

/// The popover header's chat switcher: New chat, about 10 recent chats (pinned first), Search…, Show all.
struct ChatSwitcherMenu: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var engine: ChatEngine
    var search: () -> Void
    var showAll: () -> Void

    var body: some View {
        Menu {
            Button("New Chat") { engine.newChat() }
            Divider()
            let items = store.switcher
            if items.isEmpty { Text("No saved chats yet") }
            ForEach(items) { s in
                Button { store.open(s) } label: {
                    if s.id == engine.conversation.id {
                        Label(s.title, systemImage: "checkmark")
                    } else if s.pinned {
                        Label(s.title, systemImage: "pin.fill")
                    } else {
                        Text(s.title)
                    }
                }
            }
            Divider()
            Button("Previous Chat  ⌥⌘↑") { store.step(-1) }.disabled(items.isEmpty)
            Button("Next Chat  ⌥⌘↓") { store.step(1) }.disabled(items.isEmpty)
            Divider()
            Button("Search…") { search() }
            Button("Show All in Chat Window") { showAll() }
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch chat")
        .onAppear { store.refresh() }
    }
}

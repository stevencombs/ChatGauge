import AppKit
import ChatGaugeCore
import SwiftUI

/// The full chat window: history on the left, the current chat on the right.
struct ChatWindowView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var store: ChatStore
    @ObservedObject var actions: AppActions
    @ObservedObject var hub: FeatureHub
    @ViewState private var renaming: ChatSummary?
    @ViewState private var deleting: ChatSummary?

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
                if engine.conversation.id == s.id { engine.conversation.title = name }
                renaming = nil
            }
        }
        .alert("Move this chat to the Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let d = deleting {
                    store.delete(d.id)
                    if engine.conversation.id == d.id { engine.open(Conversation()) }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.title ?? "")
        }
        .onAppear { store.refresh() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats", text: $store.query).textFieldStyle(.plain)
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
            Text(store.query.isEmpty ? "RECENT" : "RESULTS")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !engine.conversation.isEmpty && !store.summaries.contains(where: { $0.id == engine.conversation.id }) {
                        row(title: engine.conversation.title.isEmpty ? "New chat" : engine.conversation.title,
                            subtitle: engine.settings.saveChats ? "Not saved yet" : "Saving is off", selected: true)
                    }
                    ForEach(store.filtered) { s in
                        row(title: s.title, subtitle: Self.when(s.updatedAt), selected: s.id == engine.conversation.id)
                            .contentShape(Rectangle())
                            .onTapGesture { open(s) }
                            .contextMenu {
                                Button("Rename…") { renaming = s }
                                Button("Show in Finder") { store.reveal(s) }
                                Divider()
                                Button("Move to Trash…") { deleting = s }
                            }
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

    private func row(title: String, subtitle: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(selected ? Color.primary.opacity(0.7) : .secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func open(_ s: ChatSummary) {
        guard s.id != engine.conversation.id else { return }
        if !engine.conversation.isEmpty { store.save(engine.conversation) }
        if let c = store.load(s) { engine.open(c) }
    }

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
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("Chat").font(.headline)
                ModelChip(engine: engine)
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
            ComposerView(engine: engine, voice: hub.voiceButton)
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

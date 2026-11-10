import AppKit
import ChatGaugeCore
import SwiftUI
import UniformTypeIdentifiers

/// The closures the popover and windows call (wired up by the app delegate).
@MainActor
final class AppActions: ObservableObject {
    var openSettings: (String?) -> Void = { _ in }
    var openChatWindow: () -> Void = {}
    var openInstructions: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var showAbout: () -> Void = {}
    var closePopover: () -> Void = {}
    /// The paperclip: shows the image picker (the app decides where; see PopoverPolicy.attachInChatWindow).
    var attachImages: () -> Void = {}
    var quit: () -> Void = { NSApp.terminate(nil) }
    /// The first-run setup guide (also Settings › Model & Server › Run Setup Again…).
    var openSetup: () -> Void = {}
    /// Install a catalog model (dry-run alert, then pull through the existing server).
    var installModel: (String) -> Void = { _ in }
}

// MARK: Status

struct StatusDot: View {
    var level: EngineStatus.Level
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(Palette.color(level)).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// "Loading model… 4 s" / "Thinking…" while a reply hasn't started.
struct PendingLine: View {
    @ObservedObject var engine: ChatEngine
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let since = engine.loadingSince {
                    let secs = max(0, Int(ctx.date.timeIntervalSince(since)))
                    Text("Loading \(engine.status.model ?? "model")… \(secs) s")
                        .foregroundStyle(.secondary)
                    if secs < 30 { Text("(first load ~10 s)").foregroundStyle(.tertiary) }
                } else {
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}

// MARK: Messages

struct MessageBubble: View {
    var message: ChatMessage
    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if !message.images.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, d in
                            if let img = NSImage(data: d) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(Self.markdown(message.text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(message.role == .user ? Color.accentColor.opacity(0.85) : Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                        .overlay(message.role == .assistant ? RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)) : nil)
                }
                if let e = message.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Palette.color(.problem))
                }
                if let n = message.note {
                    Label(n, systemImage: "memorychip").font(.caption).foregroundStyle(Palette.color(.busy))
                }
            }
            if message.role == .assistant { Spacer(minLength: 24) }
        }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct MessagesView: View {
    @ObservedObject var engine: ChatEngine
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not LazyVStack: the lazy stack kept showing the cached "Thinking…" row after the
                // reply arrived (the row swapped view types under the same explicit id and was never redrawn).
                let pendingID = engine.conversation.pendingReplyID(streaming: engine.isStreaming)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(engine.conversation.messages) { m in
                        MessageRow(message: m, pending: m.id == pendingID, engine: engine)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: engine.conversation.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: engine.conversation.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

/// One row: the "Thinking…" line while the reply has no words yet, then the reply bubble.
struct MessageRow: View {
    var message: ChatMessage
    var pending: Bool
    @ObservedObject var engine: ChatEngine
    var body: some View {
        if pending { PendingLine(engine: engine) } else { MessageBubble(message: message) }
    }
}

// MARK: Empty / problem states

struct EmptyStateView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var actions: AppActions

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            switch engine.status.level {
            case .problem:
                Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Palette.color(.problem))
                Text(engine.status.title).font(.headline)
                if let d = engine.status.detail { Text(d).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if let m = engine.serverActionMessage { Text(m).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                HStack {
                    if engine.status == .serverDown { Button("Start Ollama") { engine.startServer() }.keyboardShortcut(.defaultAction) }
                    switch engine.status {
                    case .folderMissing, .notChosen: Button("Model & Server…") { actions.openSettings("model") }
                    case .noModels: Button("Diagnostics…") { actions.openSettings("diagnostics") }
                    default: EmptyView()
                    }
                    switch engine.status {
                    case .driveMissing, .notChosen, .noModels, .serverDown, .folderMissing: Button("Run Setup…") { actions.openSetup() }
                    default: EmptyView()
                    }
                    Button("Check Again") { Task { await engine.refresh() } }
                }
            default:
                ChatMarkView(size: 34).foregroundStyle(.secondary)
                Text("Ask anything, or drop in an image.").font(.headline)
                Text("Runs on this Mac with \(engine.status.model ?? "a local model"). Nothing leaves your computer.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if case .loading = engine.status { PendingLine(engine: engine) }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var icon: String {
        switch engine.status {
        case .driveMissing: return "externaldrive.badge.xmark"
        case .serverDown, .startingServer: return "bolt.horizontal.circle"
        case .noModels: return "shippingbox"
        default: return "exclamationmark.triangle"
        }
    }
}

// MARK: Composer

struct AttachmentChips: View {
    @ObservedObject var engine: ChatEngine
    var body: some View {
        if !engine.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(engine.attachments) { a in
                        HStack(spacing: 4) {
                            Image(nsImage: a.preview).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(a.name).font(.caption).lineLimit(1).frame(maxWidth: 110)
                            Button { engine.attachments.removeAll { $0.id == a.id } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain).help("Remove")
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    }
                }
            }
        }
    }
}

struct ComposerView: View {
    @ObservedObject var engine: ChatEngine
    /// The voice button (added by the voice feature; nil hides it).
    var voice: AnyView? = nil
    /// Shows the image picker. nil runs a plain modal picker here.
    var attach: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentChips(engine: engine)
            HStack(alignment: .bottom, spacing: 6) {
                Button { if let attach { attach() } else { pickImages() } } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless).help("Attach an image (or drop or paste one)")
                TextField(placeholder, text: $engine.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { if engine.settings.sendWithReturn { engine.send() } }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                if let voice { voice }
                if engine.isStreaming {
                    Button { engine.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless).help("Stop the reply")
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { engine.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless).disabled(!engine.canSend).help("Send (Return)")
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .onAppear { focused = true }
    }

    private var placeholder: String {
        engine.status.canChat ? "Message \(engine.status.model ?? "the model")…" : "Chat is paused: \(engine.status.title)"
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        engine.addAttachments(panel.urls.compactMap(Attachment.make(fromFile:)))
    }
}

/// Accepts dropped image files and images.
struct ImageDropModifier: ViewModifier {
    @ObservedObject var engine: ChatEngine
    @ViewState private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.accentColor.opacity(0.06))
                        .overlay(Label("Drop image to attach", systemImage: "photo").font(.headline))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                engine.lastDropAt = Date()
                for p in providers {
                    if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    if let a = Attachment.make(fromFile: url) { engine.addAttachments([a]) }
                                }
                            }
                        }
                    } else if p.canLoadObject(ofClass: NSImage.self) {
                        _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                            guard let img = obj as? NSImage else { return }
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    if let a = Attachment.make(from: img, name: "Dropped image") { engine.addAttachments([a]) }
                                }
                            }
                        }
                    }
                }
                return true
            }
    }
}

// MARK: Model chip

struct ModelChip: View {
    @ObservedObject var engine: ChatEngine
    /// When set, Install… opens Settings / runs the given pull (popover and chat window pass this).
    var onInstall: ((String) -> Void)? = nil

    private var selected: String? { engine.conversation.model }
    private var usingAutomatic: Bool { selected == nil }
    private var rows: [ModelMenuRow] { ModelCatalog.menuRows(installed: engine.models) }

    var body: some View {
        Menu {
            Button {
                engine.chooseForChat(.automatic)
            } label: {
                Text((usingAutomatic ? "✓ " : "") + "Automatic (\(engine.tier.rawValue.capitalized) tier)")
            }
            Divider()
            ForEach(rows) { row in
                if row.isInstalled {
                    Button {
                        engine.chooseForChat(.named(row.name))
                    } label: {
                        label(for: row, checked: selected == row.name || (usingAutomatic && engine.preferredModel == row.name && engine.settings.model.name == row.name))
                    }
                } else {
                    Button {
                        onInstall?(row.name)
                    } label: {
                        Text("\(row.name) — Install…")
                            .foregroundStyle(.secondary)
                    }
                    .disabled(onInstall == nil || engine.isPulling)
                }
            }
            if rows.isEmpty { Text("No models installed").foregroundStyle(.secondary) }
        } label: {
            HStack(spacing: 4) {
                Text(engine.status.model ?? engine.preferredModel ?? "No model").font(.caption.weight(.medium)).lineLimit(1)
                if let m = engine.preferredModel, engine.models.first(where: { $0.name == m })?.supportsVision == true {
                    Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
        .disabled(engine.isStreaming)
        .help(engine.isStreaming ? "Wait for the reply to finish before changing models" : "Choose the model for this chat")
    }

    @ViewBuilder private func label(for row: ModelMenuRow, checked: Bool) -> some View {
        let mark = checked ? "✓ " : ""
        let vision = row.supportsVision ? " · vision" : ""
        let size: String = {
            if case .installed(let m, _) = row, m.size > 0 {
                return " · " + MemoryStats.gb(m.size)
            }
            return ""
        }()
        Text(mark + row.name + vision + size + " — " + row.blurb)
    }
}

struct StatusLine: View {
    @ObservedObject var engine: ChatEngine
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(level: engine.status.level)
            Text(engine.status.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let s = engine.lastReplySpeed, !engine.isStreaming {
                Text(String(format: "· %.0f tok/s", s)).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct BannerView: View {
    @ObservedObject var engine: ChatEngine
    var body: some View {
        if let b = engine.banner {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill").foregroundStyle(Palette.color(.busy))
                Text(b).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { engine.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
            }
            .padding(8)
            .background(Palette.color(.busy).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

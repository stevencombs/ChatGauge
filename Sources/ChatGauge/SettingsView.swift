import AppKit
import ChatGaugeCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case model, instructions, chat, menubar, updates, diagnostics, whatsnew, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: return "Model & Server"
        case .instructions: return "Instructions"
        case .chat: return "Chat"
        case .menubar: return "Menu Bar"
        case .updates: return "Updates"
        case .diagnostics: return "Diagnostics"
        case .whatsnew: return "What's New"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .model: return "cpu"
        case .instructions: return "text.bubble"
        case .chat: return "bubble.left.and.bubble.right"
        case .menubar: return "menubar.rectangle"
        case .updates: return "arrow.down.circle"
        case .diagnostics: return "stethoscope"
        case .whatsnew: return "doc.text"
        case .about: return "info.circle"
        }
    }
}

/// Tab selection shared with the window opener, so "About…" can switch an open window.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .model
}

struct SettingsDeps {
    let settingsStore: SettingsStore
    let engine: ChatEngine
    let instructions: InstructionsStore
    let chats: ChatStore
    let voice: VoiceInput
    let hub: FeatureHub
    let launchAtLogin: LaunchAtLogin
}

struct SettingsView: View {
    let deps: SettingsDeps
    @ObservedObject var router: SettingsRouter
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var hub: FeatureHub

    init(deps: SettingsDeps, router: SettingsRouter) {
        self.deps = deps
        self.router = router
        settingsStore = deps.settingsStore
        hub = deps.hub
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $router.tab)
            Divider()
            Group {
                switch router.tab {
                case .instructions:
                    ScrollView { InstructionsEditor(store: deps.instructions, location: deps.engine.location, models: deps.engine.models.map(\.name)).padding(20) }
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) { page }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if router.tab != .about && router.tab != .whatsnew {
                Divider()
                SettingsFooter(store: settingsStore)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    @ViewBuilder private var page: some View {
        switch router.tab {
        case .model: ModelServerPane(engine: deps.engine, store: settingsStore, chats: deps.chats, openSetup: deps.hub.openSetup)
        case .chat: ChatPane(store: settingsStore, chats: deps.chats, voice: deps.voice, engine: deps.engine)
        case .menubar: MenuBarPane(store: settingsStore, login: deps.launchAtLogin)
        case .updates:
            if let pane = hub.updatesPane { pane } else {
                PrefGroup(title: "Updates") { PrefRow(label: "Update checks are starting…") { EmptyView() } }
            }
        case .diagnostics: DiagnosticsPane(engine: deps.engine, deps: deps)
        case .whatsnew: WhatsNewPane()
        case .about: AboutPane(hub: hub, openUpdates: { router.tab = .updates })
        case .instructions: EmptyView()
        }
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { t in
                Button { selection = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 17)).frame(height: 20)
                        Text(t.title).font(.system(size: 11)).lineLimit(1)
                    }
                    .frame(width: 88, height: 46)
                    .foregroundStyle(selection == t ? Color.accentColor : Color.secondary)
                    .background(selection == t ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(selection == t ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsFooter: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        HStack(spacing: 8) {
            if let m = store.lastMessage { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button("Export…") { store.exportSettings() }.help("Save all settings to a JSON file")
            Button("Import…") { store.importSettings() }.help("Load settings from a JSON file")
            Button("Reset…") {
                let a = NSAlert()
                a.messageText = "Reset all settings?"
                a.informativeText = "Chats, instructions and models are not touched."
                a.addButton(withTitle: "Reset")
                a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn { store.resetToDefaults() }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

// MARK: - Model & Server

private struct ModelServerPane: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var store: SettingsStore
    @ObservedObject var chats: ChatStore
    var openSetup: () -> Void
    @ViewState private var ownAgent = OwnAgentControl.installed
    @ViewState private var ownAgentMessage: String?

    private var s: ChatSettings { store.settings }
    private var loc: ModelsLocation { engine.location }

    private func chatCount(using model: String) -> Int {
        chats.summaries.filter { $0.model == model }.count
    }

    private var freeSpaceText: String {
        guard let b = loc.freeBytes else { return "Free space on drive: unknown" }
        return "Free space on drive: " + ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    var body: some View {
        PrefGroup(title: "Models folder",
                  footer: "ChatGauge never moves or downloads models on its own. When the drive isn't connected it waits and says so; connect the drive and it picks up again.") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(get: { s.modelsLocation }, set: { k in store.update { $0.modelsLocation = k } })) {
                    Text("This Mac").tag(ModelsLocationKind.local)
                    Text("External drive").tag(ModelsLocationKind.external)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                HStack {
                    Text(DiagnosticsReport.scrub(loc.path)).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([loc.url]) }
                        .disabled(loc.availability() != .ready)
                }
                HStack(spacing: 6) {
                    Circle().fill(Palette.color(availabilityLevel)).frame(width: 8, height: 8)
                    Text(availabilityText).font(.caption).foregroundStyle(.secondary)
                }
                Text(freeSpaceText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            Divider()
            PrefRow(label: "Ollama server", detail: serverDetail) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.color(engine.status.level)).frame(width: 8, height: 8)
                    Text(engine.status.title).font(.caption)
                    if engine.status == .serverDown { Button("Start") { engine.startServer() } }
                }
            }
            if let m = engine.serverActionMessage {
                Text(m).font(.caption).foregroundStyle(Palette.orange).padding(.bottom, 6)
            }
            if ownAgent || ownAgentMessage != nil {
                Divider()
                PrefRow(label: "ChatGauge's Ollama server", detail: ownAgentMessage ?? "\(OwnOllamaAgent.label), created by setup. Other servers are never touched.") {
                    if ownAgent {
                        Button("Remove…") {
                            ownAgentMessage = OwnAgentControl.confirmRemove()
                            ownAgent = OwnAgentControl.installed
                        }
                    }
                }
            }
            Divider()
            PrefRow(label: "Setup guide", detail: "Installs Ollama and the models on this Mac or an external drive. Steps already done are skipped.") {
                Button("Run Setup Again…") { openSetup() }
            }
        }

        PrefGroup(title: "Model") {
            PrefRow(label: "Chat model", detail: inUseDetail) {
                Picker("", selection: Binding(get: { s.model }, set: { engine.choose(model: $0) })) {
                    Text("Automatic (RAM tier)").tag(ModelChoice.automatic)
                    ForEach(engine.models) { m in
                        Text("\(m.name) — \(ModelCatalog.description(for: m))").tag(ModelChoice.named(m.name))
                    }
                    if let n = s.model.name, !engine.models.contains(where: { $0.name == n }) {
                        Text("\(n) (not installed)").tag(ModelChoice.named(n))
                    }
                }
                .labelsHidden().frame(width: 280)
            }
            Divider()
            PrefToggle(label: "Keep model loaded",
                       detail: "Answers start right away. Off: unloads after 5 minutes idle (a cold 7B load takes about 10 s).",
                       isOn: Binding(get: { s.keepsLoaded(tier: engine.tier) }, set: { v in store.update { $0.keepLoaded = v } }))
            Divider()
            PrefToggle(label: "Use a smaller model when memory is low",
                       detail: "Only one you already have; adds a note to the answer. Never downloads.",
                       isOn: Binding(get: { s.lowMemoryFallback }, set: { v in store.update { $0.lowMemoryFallback = v } }))
            Divider()
            PrefToggle(label: "Warn once when DaVinci Resolve is open",
                       detail: "Both need lots of memory; ChatGauge keeps working.",
                       isOn: Binding(get: { s.warnWhenResolveOpen }, set: { v in store.update { $0.warnWhenResolveOpen = v } }))
            Divider()
            PrefRow(label: "RAM tier", detail: "Detected \(Self.ramGB) GB. Takes effect after restarting ChatGauge.") {
                Picker("", selection: Binding(get: { s.tierOverride ?? "" }, set: { v in store.update { $0.tierOverride = v.isEmpty ? nil : v } })) {
                    Text("Automatic").tag("")
                    ForEach(RAMTier.allCases, id: \.rawValue) { t in Text(t.title).tag(t.rawValue) }
                }
                .labelsHidden().frame(width: 200)
            }
        }

        PrefGroup(title: "Installed models", footer: freeSpaceText) {
            if engine.models.isEmpty {
                Text("No models on this server yet.").foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(Array(engine.models.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Divider() }
                    PrefRow(label: m.name,
                            detail: ModelCatalog.description(for: m)) {
                        Button("Remove…") { confirmRemove(m) }
                            .disabled(engine.isRemoving || engine.isPulling || engine.streamingModel == m.name)
                    }
                }
            }
            if let msg = engine.removeMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }

        PrefGroup(title: "Optional uncensored models",
                  footer: "Downloads only when you click Install. Uses the Ollama server that's already running; ChatGauge never restarts it.") {
            ForEach(Array(ModelCatalog.uncensored.enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider() }
                let installed = engine.models.contains { $0.name == e.name }
                PrefRow(label: e.name, detail: e.blurb) {
                    HStack(spacing: 8) {
                        if engine.pullTarget == e.name, let prog = engine.pullProgress {
                            ProgressView(value: prog).frame(width: 80)
                            Button("Cancel") { engine.cancelPull() }
                        } else if installed {
                            Text("Installed").foregroundStyle(.secondary)
                        } else {
                            Button("Install…") { confirmPull(e.name, bytes: e.bytes) }
                                .disabled(engine.isPulling || engine.isRemoving || engine.status == .serverDown || loc.availability() != .ready)
                        }
                    }
                }
            }
            if let msg = engine.pullMessage, let t = engine.pullTarget, ModelCatalog.uncensored.contains(where: { $0.name == t }) {
                Text(msg).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }

        PrefGroup(title: "Image generation",
                  footer: ImageCatalog.suggestionLabel(memBytes: TierDetector.memBytes()) + " mflux is optional and is only installed after you confirm a dry run.") {
            PrefRow(label: "mflux", detail: "MLX engine for Klein 4B and Z-Image Turbo. Not bundled in the app.") {
                if engine.mfluxInstalled {
                    Text("Installed").foregroundStyle(.secondary)
                } else {
                    Button("Install…") { confirmMflux() }
                        .disabled(engine.imagePullTarget != nil)
                }
            }
        }

        PrefGroup(title: "Optional image models",
                  footer: "Downloads go to the mflux-models folder on the models drive, never into Ollama. Each Install shows the size first. Generated images save to ChatGauge Images.") {
            ForEach(Array(ImageCatalog.all.enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider() }
                let installed = engine.imageInstalled.contains(e.id)
                PrefRow(label: e.title, detail: e.blurb) {
                    HStack(spacing: 8) {
                        if engine.imagePullTarget == e.id, let prog = engine.imagePullProgress {
                            ProgressView(value: prog).frame(width: 80)
                            Button("Cancel") { engine.cancelImageInstall() }
                        } else if installed {
                            Button("Remove…") { confirmRemoveImage(e) }
                                .disabled(engine.imagePullTarget != nil || engine.isGeneratingImage)
                        } else {
                            Button("Install…") { confirmImageInstall(e) }
                                .disabled(engine.imagePullTarget != nil || loc.availability() != .ready)
                        }
                    }
                }
            }
            if let msg = engine.imagePullMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    static var ramGB: Int { Int((Double(TierDetector.memBytes()) / 1_073_741_824).rounded()) }

    private var availabilityLevel: EngineStatus.Level {
        loc.availability() == .ready ? .ok : .problem
    }

    private var availabilityText: String {
        switch loc.availability() {
        case .ready:
            let where_ = loc.volumeName.map { "Drive “\($0)” connected" } ?? "Folder found"
            return "\(where_) · \(engine.models.count) model\(engine.models.count == 1 ? "" : "s")"
        case .driveMissing(let v): return "“\(v)” isn't connected"
        case .folderMissing: return "This folder doesn't exist"
        case .notChosen: return "Choose the folder that holds your Ollama models"
        }
    }

    private var serverDetail: String {
        var parts: [String] = []
        if let a = engine.agents.first(where: { $0.runsOllama }) { parts.append("LaunchAgent \(a.label)") }
        if let v = engine.serverVersion { parts.append("Ollama \(v)") }
        parts.append(s.serverURL.replacingOccurrences(of: "http://", with: ""))
        return parts.joined(separator: " · ")
    }

    private var inUseDetail: String {
        let name = engine.preferredModel ?? "none installed"
        return "Default for new chats: \(name) · RAM tier (\(Self.ramGB) GB · \(engine.tier.rawValue))"
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Use Folder"
        p.message = "Choose the folder that holds your Ollama models (the one with blobs and manifests)."
        p.directoryURL = loc.url
        guard p.runModal() == .OK, let url = p.url else { return }
        store.update {
            $0.modelsPath = url.path
            $0.modelsLocation = url.path.hasPrefix("/Volumes/") ? .external : .local
        }
    }

    private func confirmPull(_ model: String, bytes: Int64) {
        let a = NSAlert()
        a.messageText = "Install \(model)?"
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let lines = ModelCatalog.pullPlan(model: model, serverURL: s.serverURL).joined(separator: "\n")
        a.informativeText = "This will run:\n\n\(lines)\n\nAbout \(size) into \(DiagnosticsReport.scrub(loc.path)). Nothing downloads until you click Install."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { engine.pull(model) }
    }

    private func confirmRemove(_ m: ModelInfo) {
        let count = chatCount(using: m.name)
        let plan = engine.removalPlan(for: m.name, chatCount: count)
        let a = NSAlert()
        a.messageText = "Remove \(m.name)?"
        var info = "This frees about \(plan.freeLabel).\n\nThis will run:\n\n" + plan.lines.joined(separator: "\n")
        if let w = plan.warning { info += "\n\n" + w }
        a.informativeText = info
        if plan.block != nil {
            a.addButton(withTitle: "OK")
            _ = a.runModal()
            return
        }
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { engine.removeModel(m.name, chatCount: count) }
    }

    private func confirmMflux() {
        let a = NSAlert()
        a.messageText = "Install mflux?"
        a.informativeText = "This will run:\n\n" + MfluxInstall.plan(brew: "/opt/homebrew/bin/brew", uv: ChatEngine.which("uv")).joined(separator: "\n") + "\n\nNothing is installed until you click Install. ChatGauge does not compile mflux into the app."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            engine.refreshImageModels()
            if engine.mfluxInstalled {
                engine.imagePullMessage = "mflux is already on this Mac."
            } else if ProcessInfo.processInfo.environment["CHATGAUGE_UI_SELFTEST"] != nil {
                engine.mfluxInstalled = true
                engine.imagePullMessage = "mflux marked installed (self-test stub; nothing was downloaded)."
            } else {
                engine.imagePullMessage = "Use Install in the setup guide to run the dry-run uv install, or install mflux yourself and reopen Settings."
            }
        }
    }

    private func confirmImageInstall(_ e: ImageModelEntry) {
        let a = NSAlert()
        a.messageText = "Install \(e.title)?"
        let lines = ImageCatalog.installPlan(e, into: loc.imageModelsFolder).joined(separator: "\n")
        a.informativeText = "This will run:\n\n\(lines)\n\nAbout \(e.sizeLabel). Nothing downloads until you click Install."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { engine.installImageModel(e.id) }
    }

    private func confirmRemoveImage(_ e: ImageModelEntry) {
        let plan = ImageRemoval.plan(e, folder: loc.imageModelsFolder)
        let a = NSAlert()
        a.messageText = "Remove \(e.title)?"
        var info = "This frees about \(plan.freeLabel).\n\nThis will run:\n\n" + plan.lines.joined(separator: "\n")
        if let w = plan.warning { info += "\n\n" + w }
        a.informativeText = info
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            engine.imagePullMessage = engine.removeImageModel(e.id)
        }
    }
}

// MARK: - Chat

private struct ChatPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var chats: ChatStore
    @ObservedObject var voice: VoiceInput
    @ObservedObject var engine: ChatEngine
    @ObservedObject var hotKeys = HotKeyCenter.shared

    private var s: ChatSettings { store.settings }

    enum Place: Hashable { case mac, models, other }

    private var nextToModels: String { engine.location.projectRoot.appendingPathComponent("ChatGauge Chats").path }

    private var place: Place {
        guard let p = s.chatsFolder, !p.isEmpty else { return .mac }
        return p == nextToModels ? .models : .other
    }

    var body: some View {
        PrefGroup(title: "Chat history",
                  footer: "One \(s.chatFormat == .markdown ? "Markdown" : "JSON") file per chat, with attached images saved beside it. Chats stay on disk and are never uploaded.") {
            PrefToggle(label: "Save chats", detail: "Off: chats disappear when you start a new one",
                       isOn: Binding(get: { s.saveChats }, set: { v in store.update { $0.saveChats = v } }))
            Divider()
            PrefToggle(label: "Name new chats with the local model",
                       detail: "After the first reply, the same model suggests a short title. Chats you renamed keep their name.",
                       isOn: Binding(get: { s.autoTitles }, set: { v in store.update { $0.autoTitles = v } }))
            Divider()
            PrefToggle(label: "Reopen the last chat at launch", detail: "Off: ChatGauge starts with a new chat",
                       isOn: Binding(get: { s.reopenLastChat }, set: { v in store.update { $0.reopenLastChat = v } }))
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Save chats in")
                Picker("", selection: Binding(get: { place }, set: { setPlace($0) })) {
                    Text("This Mac  ").tag(Place.mac)
                    Text("Next to the models  ").tag(Place.models)
                    Text("Another folder…").tag(Place.other)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text(chats.folderDisplay).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack {
                    Button("Choose…") { chooseFolder() }
                    Button("Show in Finder") { chats.revealFolder() }
                }
            }
            .padding(.vertical, 7)
            Divider()
            PrefRow(label: "File format", detail: "Existing chats keep their format until they're saved again") {
                Picker("", selection: Binding(get: { s.chatFormat }, set: { v in store.update { $0.chatFormat = v } })) {
                    ForEach(ChatFileFormat.allCases, id: \.self) { f in Text(f.title).tag(f) }
                }
                .labelsHidden().frame(width: 170)
            }
        }

        PrefGroup(title: "Popover") {
            PrefRow(label: "Global shortcut",
                    detail: hotKeys.registrationFailed ? "Another app is using this shortcut. Pick a different one." : "Opens the chat from any app") {
                HotKeyRecorder(hotKey: Binding(get: { s.hotKey }, set: { v in store.update { $0.hotKey = v } }))
            }
            Divider()
            PrefToggle(label: "Return sends, ⇧Return adds a new line",
                       detail: "Off: ⌘Return sends",
                       isOn: Binding(get: { s.sendWithReturn }, set: { v in store.update { $0.sendWithReturn = v } }))
        }

        PrefGroup(title: "Voice",
                  footer: "Hold the microphone button to talk. whisper.cpp transcribes on this Mac and fills the message box; nothing is sent until you press Send.") {
            PrefToggle(label: "Hold-to-talk", detail: voice.unavailableReason ?? "Uses whisper-cli and a model from the models folder",
                       isOn: Binding(get: { s.voiceEnabled }, set: { v in store.update { $0.voiceEnabled = v } }))
            Divider()
            PrefRow(label: "Speech model", detail: "In use: \(voice.modelName ?? "none installed")") {
                HStack {
                    Picker("", selection: Binding(get: { s.whisperModel ?? "" }, set: { v in store.update { $0.whisperModel = v.isEmpty ? nil : v } })) {
                        Text("Automatic (RAM tier)").tag("")
                        ForEach(WhisperModelPicker.installed(in: engine.location.whisperFolder), id: \.self) { n in Text(n).tag(n) }
                    }
                    .labelsHidden().frame(width: 190)
                    if voice.canDownloadModel { Button("Download…") { voice.confirmAndDownloadModel() } }
                }
            }
        }
    }

    private func setPlace(_ p: Place) {
        switch p {
        case .mac: store.update { $0.chatsFolder = nil }
        case .models: store.update { $0.chatsFolder = nextToModels }
        case .other: chooseFolder()
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Save Chats Here"
        guard p.runModal() == .OK, let url = p.url else { return }
        store.update { $0.chatsFolder = url.path }
    }
}

// MARK: - Menu Bar

private struct MenuBarPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var login: LaunchAtLogin
    private var s: ChatSettings { store.settings }

    var body: some View {
        PrefGroup(title: "Menu bar item") {
            PrefRow(label: "Show next to the icon") {
                Picker("", selection: Binding(get: { s.menuBarText }, set: { v in store.update { $0.menuBarText = v } })) {
                    ForEach(MenuBarText.allCases, id: \.self) { t in Text(t.title).tag(t) }
                }
                .labelsHidden().frame(width: 220)
            }
            Divider()
            PrefToggle(label: "Status dot", detail: "Green ready, orange loading or busy, red needs attention",
                       isOn: Binding(get: { s.showStatusDot }, set: { v in store.update { $0.showStatusDot = v } }))
            Divider()
            HStack(spacing: 14) {
                legend(.ok, "Ready")
                legend(.busy, "Loading / answering")
                legend(.problem, "Needs attention")
            }
            .padding(.vertical, 7)
        }
        PrefGroup(title: "Startup", footer: login.lastError) {
            PrefToggle(label: "Open ChatGauge at login", detail: "Adds ChatGauge to System Settings › General › Login Items",
                       isOn: Binding(get: { login.isEnabled }, set: { v in
                           login.set(v)
                           store.update { $0.launchAtLogin = login.isEnabled }
                       }))
        }
        .onAppear { login.refresh() }
    }

    private func legend(_ l: EngineStatus.Level, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.color(l)).frame(width: 8, height: 8)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    @ObservedObject var engine: ChatEngine
    let deps: SettingsDeps
    @ViewState private var copied = false
    static let smallModel = "qwen2.5vl:3b"

    var body: some View {
        PrefGroup(title: "Report",
                  footer: "Paste this into a bug report. It has no chats, prompts or account details, and your home folder shows as ~.") {
            Text(report.text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } accessory: {
            HStack {
                Button("Check Again") { Task { await engine.refresh() } }
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                    copied = true
                }
            }
        }

        PrefGroup(title: "Small model",
                  footer: "Downloads only when you click, into the models folder above, using Ollama. About 3.2 GB.") {
            PrefRow(label: Self.smallModel,
                    detail: engine.pullMessage ?? (hasSmall ? "Installed" : "A faster fallback when memory is low")) {
                HStack {
                    if let p = engine.pullProgress { ProgressView(value: p).frame(width: 120) }
                    if !hasSmall {
                        Button("Download…") { confirmPull() }
                            .disabled(engine.pullProgress != nil || engine.status == .serverDown || engine.location.availability() != .ready)
                    }
                }
            }
        }
    }

    private var hasSmall: Bool { engine.models.contains { $0.name == Self.smallModel } }

    private func confirmPull() {
        let a = NSAlert()
        a.messageText = "Download \(Self.smallModel)?"
        a.informativeText = "Ollama downloads about 3.2 GB into \(DiagnosticsReport.scrub(engine.location.path))."
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { engine.pull(Self.smallModel) }
    }

    private var report: DiagnosticsReport {
        let s = engine.settings
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [(String, String)] = [
            ("ChatGauge", "\(AppInfo.version) (\(AppInfo.build))"),
            ("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            ("Memory", "\(ModelServerPane_ramGB()) GB · tier \(engine.tier.rawValue)\(s.tierOverride != nil ? " (override)" : "")"),
            ("Memory pressure", "\(engine.pressure)"),
            ("Models folder", "\(engine.location.path) · \(availability)"),
            ("Server", "\(s.serverURL) · \(engine.status.title)"),
            ("Ollama", engine.serverVersion ?? "not answering"),
            ("LaunchAgents", engine.agents.isEmpty ? "none for Ollama" : engine.agents.map { "\($0.label)\($0.runsOllama ? "" : " (not ollama)")" }.joined(separator: ", ")),
            ("Models", engine.models.isEmpty ? "none" : engine.models.map(\.name).joined(separator: ", ")),
            ("Loaded now", engine.loaded.isEmpty ? "none" : engine.loaded.map(\.name).joined(separator: ", ")),
            ("Chat model", "\(s.model.name ?? "automatic") → \(engine.preferredModel ?? "none")"),
            ("Keep loaded", s.keepsLoaded(tier: engine.tier) ? "yes" : "no (5 min)"),
            ("DaVinci Resolve", engine.resolveOpen ? "open" : "not running"),
            ("Shortcut", s.hotKey.enabled ? "\(s.hotKey.display)\(HotKeyCenter.shared.registrationFailed ? " (taken by another app)" : "")" : "off"),
            ("Voice", deps.voice.unavailableReason ?? "ready · \(deps.voice.modelName ?? "-")"),
            ("whisper-cli", VoiceTools.whisperCLI ?? "not installed"),
            ("ffmpeg", VoiceTools.ffmpeg ?? "not installed"),
            ("Chats folder", deps.chats.folder.path),
        ]
        for extra in deps.hub.diagnostics { lines += extra() }
        return DiagnosticsReport(lines: lines)
    }

    private var availability: String {
        switch engine.location.availability() {
        case .ready: return "ready"
        case .driveMissing(let v): return "drive \(v) not connected"
        case .folderMissing: return "folder missing"
        case .notChosen: return "not chosen"
        }
    }
}

private func ModelServerPane_ramGB() -> Int { Int((Double(TierDetector.memBytes()) / 1_073_741_824).rounded()) }

// MARK: - What's New

struct ReleaseNote: Identifiable {
    let version: String
    let date: String
    let items: [String]
    var id: String { version }

    static let all: [ReleaseNote] = [
        ReleaseNote(version: "0.1.0 (build 17, unreleased)", date: "November 2026", items: [
            "Optional offline image generation with mflux: FLUX.2 Klein 4B and Z-Image Turbo, each installed only after a dry run.",
            "Generate image mode in the Chat Window, with a RAM-based model suggestion. Images save to a ChatGauge Images folder on the models drive.",
            "Each chat model has its own instructions in Settings.",
            "Import ClipGauge glossary is a one-time, read-only import that shows a dry run first.",
        ]),
        ReleaseNote(version: "0.1.0", date: "October 2026", items: [
            "Chat with a local Ollama model from the menu bar, with images by drag, drop or paste.",
            "Picks a model by RAM tier and shows a clear loading state while it warms up.",
            "Works with models on an external drive and says so when the drive isn't connected.",
            "Instructions presets, a glossary, and import from ClipGauge's instructions.",
            "Chats saved as Markdown or JSON files, with a history window and search.",
            "Hold-to-talk voice input with whisper.cpp, entirely on this Mac.",
            "Daily update checks for ChatGauge, Ollama, your models and the voice tools.",
        ]),
    ]
}

private struct WhatsNewPane: View {
    var body: some View {
        ForEach(ReleaseNote.all) { n in
            PrefGroup(title: "Version \(n.version) · \(n.date)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(n.items, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(i).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        Link("All releases on GitHub", destination: AppInfo.releasesURL).font(.caption)
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var hub: FeatureHub
    var openUpdates: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("ChatGauge").font(.system(size: 22, weight: .semibold))
            Text("Version \(AppInfo.version)").font(.callout).foregroundStyle(.secondary)
            Text("Chat with a local AI model from your menu bar. Runs on your Mac with Ollama.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)

        MakerCard()

        PrefGroup(title: "Updates") {
            if let row = hub.aboutUpdatesRow { row } else {
                PrefRow(label: "Updates") { Button("Check Now") { openUpdates() } }
            }
        }

        PrefGroup(title: "More Gauge apps") {
            PrefRow(label: "GrokGauge", detail: "SuperGrok and Grok Bot usage as rings in your menu bar") {
                Link("stevencombs.github.io/GrokGauge", destination: AppInfo.grokGaugeURL)
            }
            Divider()
            PrefRow(label: "ClipGauge", detail: "Renames and sorts clips with local AI") {
                Link("stevencombs.github.io/ClipGauge", destination: AppInfo.clipGaugeURL)
            }
        }

        PrefGroup(title: "Links") {
            PrefRow(label: "Source code & README") { Link("github.com/stevencombs/ChatGauge", destination: AppInfo.repoURL) }
            Divider()
            PrefRow(label: "Report a bug", detail: "Paste the report from the Diagnostics tab") {
                Link("New issue", destination: AppInfo.newIssueURL)
            }
        }
    }
}

/// The shared Gauge maker card.
struct MakerCard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            if let logo = AppInfo.makerLogo {
                Image(nsImage: logo)
                    .resizable().interpolation(.high).aspectRatio(1, contentMode: .fit)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.16 : 0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 8, x: 0, y: 4)
                    .accessibilityLabel("retroCombs logo")
            }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made by Steven Combs (retroCombs)").font(.headline)
                    Text("Videos, projects and updates on YouTube.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    youTube(AppInfo.youTubeMain.handle, AppInfo.youTubeMain.url)
                    youTube(AppInfo.youTubeTech.handle, AppInfo.youTubeTech.url)
                }
                Button { NSWorkspace.shared.open(AppInfo.tipURL) } label: {
                    Label("Support ChatGauge · Tip via PayPal", systemImage: "heart.fill").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(TipButtonStyle())
                .help(AppInfo.tipURL.absoluteString)
                Link(destination: AppInfo.contactURL) {
                    Label("Contact: \(AppInfo.contactEmail)", systemImage: "envelope").font(.system(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    private func youTube(_ handle: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label(handle, systemImage: "play.rectangle.fill").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(YouTubeButtonStyle())
        .help(url.absoluteString)
        .accessibilityLabel("Open the \(handle) YouTube channel")
    }
}

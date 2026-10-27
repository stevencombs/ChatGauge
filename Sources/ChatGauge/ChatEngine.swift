import AppKit
import ChatGaugeCore
import Combine

/// Talks to the local Ollama: server state, installed models, loading, and streaming replies.
@MainActor
final class ChatEngine: ObservableObject {
    /// When an image was last dropped on a chat view (set at once, before the image finishes loading).
    var lastDropAt: Date?
    @Published private(set) var status: EngineStatus = .checking
    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var loaded: [LoadedModel] = []
    @Published private(set) var serverVersion: String?
    @Published private(set) var loadingSince: Date?
    @Published private(set) var isStreaming = false
    /// True while the current reply is waiting for its first token (the model may still be loading).
    @Published private(set) var awaitingFirstToken = false
    @Published var conversation = Conversation()
    @Published var draft = ""
    @Published var attachments: [Attachment] = []
    /// One-off notes for the popover (Resolve open, memory low). Dismissable.
    @Published var banner: String?
    @Published private(set) var serverActionMessage: String?
    @Published private(set) var lastReplySpeed: Double?

    let settingsStore: SettingsStore
    let tier: RAMTier
    private(set) var rules: TierRules
    private(set) var agents: [OllamaAgent] = []

    /// The system prompt for new requests (set by the instructions store).
    var systemPrompt: () -> String? = { nil }
    /// The active instructions preset's name (recorded on each chat).
    var instructionsName: () -> String? = { nil }
    /// Called whenever a reply finishes (the chat store saves).
    var onConversationUpdated: ((Conversation) -> Void)?

    private var ledger = LoadLedger()
    private var fallback = MemoryFallback()
    private var resolve = ResolveWatch()
    private(set) var pressure: MemoryPressure = .normal
    private var pressureSource: DispatchSourceMemoryPressure?
    private var streamer: ChatStreamer?
    private var timer: Timer?
    private var refreshing = false
    private var warming: String?
    private var cancellables = Set<AnyCancellable>()

    var settings: ChatSettings { settingsStore.settings }
    var location: ModelsLocation { ModelsLocation.from(settings) }
    var resolveOpen: Bool { resolve.running }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let loc = ModelsLocation.from(settingsStore.settings)
        rules = (try? Data(contentsOf: loc.ramTiersFile)).map(TierRules.parse) ?? .standard
        tier = TierDetector.detect(rules: rules, override: settingsStore.settings.tierOverride)
    }

    private var client: OllamaClient? { OllamaClient(baseURL: settings.serverURL) }

    // MARK: Lifecycle

    func start() {
        agents = OllamaAgent.discover()
        settingsStore.adoptServerFolderIfFirstLaunch(agents: agents)
        startPressureMonitor()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] n in
                guard let self else { return }
                if n.name == NSWorkspace.didMountNotification || n.name == NSWorkspace.didUnmountNotification {
                    Task { await self.refresh() }
                } else {
                    self.checkResolve()
                }
            }.store(in: &cancellables)
        }
        settingsStore.$settings.map(\.serverURL).removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { await self?.refresh() } }.store(in: &cancellables)
        settingsStore.$settings.map { [$0.modelsPath ?? "", $0.modelsLocation.rawValue, $0.model.name ?? ""] }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { await self?.refresh() } }.store(in: &cancellables)
        checkResolve()
        schedule(interval: 60)
        Task { await refresh() }
    }

    /// Faster checks while the popover is open.
    func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refresh() } }
        }
    }

    // MARK: Server and models

    /// The model in effect for the next message (before any memory fallback).
    var preferredModel: String? {
        ModelSelection.preferred(choice: settings.model, tier: tier, rules: rules, installed: models)
    }

    var isLoaded: (String) -> Bool { { [loaded] m in loaded.contains { $0.name == m } } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let avail = location.availability()
        switch avail {
        case .driveMissing(let v):
            models = []
            loaded = []
            setStatus(.driveMissing(volume: v))
            return
        case .notChosen:
            setStatus(.notChosen)
            return
        case .folderMissing:
            setStatus(.folderMissing(path: location.path))
            return
        case .ready:
            break
        }

        guard let client else {
            setStatus(.failed("The server address must be on this Mac (127.0.0.1)."))
            return
        }
        do {
            serverVersion = try await client.version()
        } catch {
            serverVersion = nil
            models = []
            loaded = []
            if case .startingServer = status { return }
            setStatus(.serverDown)
            return
        }
        do {
            async let t = client.tags()
            async let p = client.ps()
            models = try await t
            loaded = (try? await p) ?? []
        } catch {
            setStatus(.failed("Ollama answered, but listing models failed."))
            return
        }
        recomputeStatus()
    }

    private func setStatus(_ s: EngineStatus) {
        if status != s { status = s }
    }

    /// Status from the models, what's loaded, and what's in flight.
    private func recomputeStatus() {
        if isStreaming, let m = conversation.messages.last?.model { return setStatus(.generating(model: m)) }
        guard let m = preferredModel else { return setStatus(.noModels) }
        if let w = warming { return setStatus(.loading(model: w)) }
        setStatus(isLoaded(m) ? .ready(model: m) : .idle(model: m))
    }

    /// Ask macOS to start the Ollama service (only from a click). Never `kickstart -k`, never edits LaunchAgents.
    func startServer() {
        agents = OllamaAgent.discover()
        let plan = ServerPlan.decide(answering: false, availability: location.availability(), agents: agents,
                                     loadedLabels: Set(agents.map(\.label).filter(Self.isLoadedInLaunchd)),
                                     modelsPath: location.path)
        guard let args = ServerPlan.launchctlArguments(plan, uid: getuid()) else {
            switch plan {
            case .waitForDrive(let v): serverActionMessage = "Connect “\(v)” first."
            default: serverActionMessage = "No Ollama service is set up on this Mac. Open the Ollama app, or run `ollama serve` in Terminal."
            }
            return
        }
        serverActionMessage = nil
        setStatus(.startingServer)
        let ok = Self.launchctl(args)
        if !ok { serverActionMessage = "macOS didn't start the Ollama service. Open the Ollama app instead." }
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if (try? await client?.version()) != nil { break }
            }
            status = .checking
            await refresh()
        }
    }

    nonisolated static func isLoadedInLaunchd(_ label: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @discardableResult
    nonisolated static func launchctl(_ args: [String]) -> Bool {
        precondition(!args.contains("-k"), "ChatGauge never kills the Ollama server")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func choose(model: ModelChoice) {
        settingsStore.update { $0.model = model }
        recomputeStatus()
    }

    var keepAliveValue: Int { settings.keepsLoaded(tier: tier) ? -1 : 300 }

    /// Loads the model so the first reply is quick (on popover open). Shows "Loading model…" while it runs.
    func warmUp() {
        guard warming == nil, !isStreaming, case .idle(let m) = status, let client else { return }
        // Don't push a big model into memory that's already tight.
        if pressure >= .warning { return }
        warming = m
        loadingSince = Date()
        setStatus(.loading(model: m))
        let keep = keepAliveValue
        Task {
            do {
                try await client.keepAlive(model: m, keep)
                ledger.recordLoad(m, wasAlreadyLoaded: false)
            } catch {
                banner = "Couldn't load \(m): \((error as? OllamaError)?.description ?? error.localizedDescription)"
            }
            warming = nil
            loadingSince = nil
            loaded = (try? await client.ps()) ?? loaded
            recomputeStatus()
        }
    }

    // MARK: Chat

    var canSend: Bool {
        !isStreaming && status.canChat
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        guard canSend, let client, let preferred = preferredModel else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments.map(\.data)

        // Memory: maybe a smaller installed model, with a note. Never downloads one.
        let chain = ModelSelection.fallbackChain(for: preferred, installed: models)
        var sizes: [String: Int64] = [:]
        for m in models { sizes[m.name] = m.size }
        for l in loaded { sizes[l.name] = l.size }
        let decision = fallback.decide(preferred: preferred, chain: chain, pressure: pressure,
                                       available: MemoryStats.availableBytes(), sizes: sizes,
                                       loaded: Set(loaded.map(\.name)), enabled: settings.lowMemoryFallback)
        let model = decision.model
        if !images.isEmpty, let info = models.first(where: { $0.name == model }), !info.supportsVision {
            banner = "\(model) can't read images. Pick a vision model (such as qwen2.5vl) in the model menu."
            return
        }

        if conversation.isEmpty {
            conversation.title = Conversation.makeTitle(from: text, hasImage: !images.isEmpty)
            conversation.model = model
            conversation.instructions = instructionsName()
        }
        conversation.messages.append(ChatMessage(role: .user, text: text, images: images))
        let reply = ChatMessage(role: .assistant, text: "", model: model, note: decision.note)
        conversation.messages.append(reply)
        conversation.updatedAt = Date()
        draft = ""
        attachments = []

        let wasLoaded = isLoaded(model)
        let wire = conversation.wire(system: systemPrompt())
        isStreaming = true
        awaitingFirstToken = true
        lastReplySpeed = nil
        if !wasLoaded { loadingSince = Date() }
        setStatus(.generating(model: model))
        let replyID = reply.id

        streamer = ChatStreamer(
            request: client.chatRequest(model: model, messages: wire, keepAlive: keepAliveValue),
            onChunk: { [weak self] chunk in
                MainActor.assumeIsolated { self?.handle(chunk, replyID: replyID) }
            },
            onFinish: { [weak self] error, cancelled in
                MainActor.assumeIsolated {
                    self?.finish(replyID: replyID, model: model, wasLoaded: wasLoaded, error: error, cancelled: cancelled)
                }
            })
    }

    private func handle(_ chunk: ChatChunk, replyID: UUID) {
        guard let i = conversation.messages.lastIndex(where: { $0.id == replyID }) else { return }
        if let e = chunk.error {
            conversation.messages[i].error = OllamaError.friendly(e)
            return
        }
        if !chunk.content.isEmpty {
            if awaitingFirstToken {
                awaitingFirstToken = false
                loadingSince = nil
            }
            conversation.messages[i].text += chunk.content
        }
        if chunk.done, let s = chunk.tokensPerSecond { lastReplySpeed = s }
    }

    private func finish(replyID: UUID, model: String, wasLoaded: Bool, error: String?, cancelled: Bool) {
        streamer = nil
        isStreaming = false
        awaitingFirstToken = false
        loadingSince = nil
        if let i = conversation.messages.lastIndex(where: { $0.id == replyID }) {
            if cancelled { conversation.messages[i].error = conversation.messages[i].text.isEmpty ? "Stopped." : nil }
            if cancelled, !conversation.messages[i].text.isEmpty { conversation.messages[i].note = [conversation.messages[i].note, "Stopped."].compactMap { $0 }.joined(separator: " ") }
            if let error { conversation.messages[i].error = error }
            conversation.messages[i].text = conversation.messages[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !wasLoaded && error == nil { ledger.recordLoad(model, wasAlreadyLoaded: false) }
        conversation.updatedAt = Date()
        onConversationUpdated?(conversation)
        maybeAutoTitle(model: model, ok: error == nil && !cancelled)
        Task {
            loaded = (try? await client?.ps()) ?? loaded
            recomputeStatus()
        }
    }

    /// Called when a model title arrives for a chat that's no longer the current one (the store saves it).
    var onModelTitleForOtherChat: ((UUID, String) -> Void)?
    /// True while a title request is out (the self-test waits on it).
    @Published private(set) var titling = false

    /// After a new chat's first reply, ask the same model (it just answered, so it's installed and loaded) for a
    /// short title. One small non-streaming request; never pulls, never loads another model. Any failure keeps
    /// the first-line title. A chat renamed by hand (`titleSource == .user`) is never touched.
    private func maybeAutoTitle(model: String, ok: Bool) {
        guard ok, settings.autoTitles, conversation.titleSource == .firstLine,
              conversation.messages.filter({ $0.role == .user }).count == 1,
              models.contains(where: { $0.name == model }) || loaded.contains(where: { $0.name == model }),
              let msgs = AutoTitle.messages(for: conversation), let client else { return }
        let id = conversation.id
        let keep = keepAliveValue
        titling = true
        Task { [weak self] in
            let raw = try? await client.chatOnce(model: model, messages: msgs, keepAlive: keep)
            self?.titling = false
            guard let self, let t = raw.flatMap(AutoTitle.clean) else { return }
            if self.conversation.id == id {
                guard self.conversation.titleSource == .firstLine else { return }
                self.conversation.title = t
                self.conversation.titleSource = .model
                self.onConversationUpdated?(self.conversation)
            } else {
                self.onModelTitleForOtherChat?(id, t)
            }
        }
    }

    func stop() { streamer?.cancel() }

    func newChat() {
        if isStreaming { stop() }
        if !conversation.isEmpty { onConversationUpdated?(conversation) }
        conversation = Conversation()
        draft = ""
        attachments = []
        banner = nil
    }

    func open(_ c: Conversation) {
        if isStreaming { stop() }
        conversation = c
        draft = ""
        attachments = []
    }

    func addAttachments(_ a: [Attachment]) {
        attachments.append(contentsOf: a.prefix(max(0, 6 - attachments.count)))
    }

    // MARK: Memory and Resolve

    private func startPressureMonitor() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            MainActor.assumeIsolated {
                guard let self, let ev = src?.data else { return }
                let old = self.pressure
                if ev.contains(.critical) { self.pressure = .critical }
                else if ev.contains(.warning) { self.pressure = .warning }
                else { self.pressure = .normal }
                if self.pressure > old, self.pressure >= .warning, self.isStreaming == false {
                    self.banner = "Memory is low. ChatGauge will use a smaller installed model for the next reply if it has one."
                }
            }
        }
        src.resume()
        pressureSource = src
    }

    private func checkResolve() {
        let ids = NSWorkspace.shared.runningApplications.map(\.bundleIdentifier)
        if resolve.update(runningBundleIDs: ids, enabled: settings.warnWhenResolveOpen) {
            banner = ResolveWatch.note
        }
        objectWillChange.send()
    }

    // MARK: Quit

    /// Unloads only the models ChatGauge loaded itself and that are still loaded. Others' models are left alone.
    func unloadOwnModels() async {
        stop()
        guard let client else { return }
        let now = ((try? await client.ps(timeout: 2)) ?? loaded).map(\.name)
        for m in ledger.toUnload(loadedNow: now) {
            try? await client.keepAlive(model: m, 0, timeout: 3)
            ledger.recordUnload(m)
        }
    }

    // MARK: Pull (only from the Diagnostics button)

    @Published private(set) var pullProgress: Double?
    @Published private(set) var pullMessage: String?
    private var pullTask: Task<Void, Never>?

    func pull(_ model: String) {
        guard pullTask == nil, let client else { return }
        pullMessage = "Starting download of \(model)…"
        pullProgress = 0
        pullTask = Task {
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: client.pullRequest(model: model))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, nil) }
                for try await line in bytes.lines {
                    guard let p = PullProgress.parse(Data(line.utf8)) else { continue }
                    if let e = p.error { pullMessage = e; break }
                    pullMessage = p.status.capitalized
                    if let f = p.fraction { pullProgress = f }
                    if p.status == "success" { pullMessage = "\(model) is installed." }
                }
            } catch {
                pullMessage = "Download failed: \((error as? OllamaError)?.description ?? error.localizedDescription)"
            }
            pullProgress = nil
            pullTask = nil
            await refresh()
        }
    }
}

import AppKit
import ChatGaugeCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, NSDraggingDestination {
    let settingsStore = SettingsStore()
    lazy var engine = ChatEngine(settingsStore: settingsStore)
    let actions = AppActions()
    let hub = FeatureHub()
    let instructions = InstructionsStore()
    lazy var chats = ChatStore(settingsStore: settingsStore)
    lazy var voice = VoiceInput(engine: engine) { [instructions] in instructions.file.whisperPrompt() }
    let launchAtLogin = LaunchAtLogin()
    let settingsRouter = SettingsRouter()
    lazy var updates = UpdateCenter(engine: engine, settingsStore: settingsStore)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Self-test / same-module helpers.
    var popoverIsShown: Bool { popover.isShown }
    var popoverViewForTest: NSView? { popover.contentViewController?.view }
    private var outsideClickMonitor: Any?
    private var pasteMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var quitting = false

    /// Windows opened from the gear menu (filled in by later features).
    var settingsWindow: HostedWindow?
    var chatWindow: HostedWindow?
    var instructionsWindow: HostedWindow?
    var setupWindow: HostedWindow?
    var setupModel: SetupModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self, settingsAction: #selector(openSettingsFromMenu(_:)),
                         chatWindowAction: #selector(openChatWindowFromMenu(_:)))
        MainMenu.addChatMenu(target: self, previous: #selector(previousChatFromMenu(_:)), next: #selector(nextChatFromMenu(_:)),
                             find: #selector(findChatFromMenu(_:)), trash: #selector(trashChatFromMenu(_:)))
        wireActions()
        configureFeatures()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if UISelfTest.outputFolder == nil { statusItem.autosaveName = "ChatGaugeStatusItem" }
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.setAccessibilityLabel("ChatGauge")
            // Drop images on the menu bar icon (as in ClipGauge): the status item's window forwards drags to its delegate.
            button.window?.registerForDraggedTypes([.fileURL, .png, .tiff])
            button.window?.delegate = self
        }
        updateStatusItem()

        popover.behavior = PopoverPolicy(pinned: settingsStore.settings.pinPopover).semitransient ? .semitransient : .applicationDefined
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(engine: engine, settingsStore: settingsStore, actions: actions, hub: hub))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        engine.$status.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &cancellables)
        settingsStore.$settings.removeDuplicates { $0.menuBarText == $1.menuBarText && $0.showStatusDot == $1.showStatusDot }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &cancellables)
        settingsStore.$settings.map(\.pinPopover).removeDuplicates()
            .sink { [weak self] pinned in DispatchQueue.main.async { self?.applyPin(pinned) } }
            .store(in: &cancellables)
        settingsStore.$settings.map(\.hotKey).removeDuplicates()
            .sink { [weak self] key in DispatchQueue.main.async { self?.registerHotKey(key) } }
            .store(in: &cancellables)
        HotKeyCenter.shared.action = { [weak self] in self?.togglePopover(nil) }

        installPasteMonitor()
        if settingsStore.settings.reopenLastChat && UISelfTest.outputFolder == nil { chats.reopenLast() }
        engine.start()
        engine.refreshImageModels()
        if UISelfTest.outputFolder == nil && setupShouldAutoShow() { showSetup() }
        if let out = UISelfTest.outputFolder {
            UISelfTest.run(out: out, open: { [weak self] in self?.showPopover() },
                           view: { [weak self] in self?.popover.contentViewController?.view }, engine: engine,
                           extra: { [weak self] out in
                               let a = await self?.selfTestAttachAndDrop(out: out) ?? ""
                               let c = await self?.selfTestChats(out: out) ?? ""
                               let setup = await self?.selfTestSetup(out: out) ?? ""
                               let b15 = await self?.selfTestBuild15(out: out) ?? ""
                               let b17 = await self?.selfTestBuild17(out: out) ?? ""
                               return a + c + setup + b15 + b17
                           })
        }
    }

    /// Hook for later features (instructions, chats, voice, settings, updates).
    func configureFeatures() {
        configureInstructions()
        configureChats()
        hub.voiceButton = AnyView(VoiceButton(voice: voice))
        configureSettings()
        configureUpdates()
    }

    private func configureUpdates() {
        let center = updates
        center.openUpdatesTab = { [weak self] in self?.showSettings(tab: "updates") }
        hub.updatesPane = AnyView(UpdatesPane(center: center, store: settingsStore) { [weak self] in self?.settingsRouter.tab = .whatsnew })
        hub.aboutUpdatesRow = AnyView(AboutUpdatesRow(center: center))
        hub.updatesRow = AnyView(UpdatesPopoverRow(center: center) { [weak self] in self?.showSettings(tab: "updates") })
        hub.diagnostics.append { [weak center] in center?.diagnostics ?? [] }
        center.$items.map { $0.contains(where: \.needsUpdate) }.removeDuplicates()
            .sink { [weak self] v in self?.hub.updateAvailable = v }
            .store(in: &cancellables)
        center.start()
    }

    private func configureSettings() {
        let router = settingsRouter
        let window = HostedWindow(title: "ChatGauge Settings", size: NSSize(width: 760, height: 640), autosave: "ChatGaugeSettings", resizable: true) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            let deps = SettingsDeps(settingsStore: self.settingsStore, engine: self.engine, instructions: self.instructions,
                                    chats: self.chats, voice: self.voice, hub: self.hub, launchAtLogin: self.launchAtLogin)
            return AnyView(SettingsView(deps: deps, router: router))
        }
        window.onClose = { [weak self] in
            self?.settingsStore.saveNow()
        }
        settingsWindow = window
        settingsWindowOpener = { tab in
            if let tab, let t = SettingsTab(rawValue: tab) { router.tab = t }
            window.show()
        }
    }

    private func configureChats() {
        let store = chats
        store.engine = engine
        engine.onModelTitleForOtherChat = { id, title in store.applyModelTitle(id, title) }
        hub.chatSwitcher = AnyView(ChatSwitcherMenu(store: store, engine: engine,
                                                    search: { [weak self] in self?.findChat() },
                                                    showAll: { [weak self] in self?.showChatWindow() }))
        engine.onConversationUpdated = { [weak self] c in
            guard let self, let saved = store.save(c) else { return }
            // Remember the saved image names so the next save doesn't rewrite them.
            guard self.engine.conversation.id == saved.id else { return }
            for m in saved.messages where !m.imageFiles.isEmpty {
                if let i = self.engine.conversation.messages.firstIndex(where: { $0.id == m.id }) {
                    self.engine.conversation.messages[i].imageFiles = m.imageFiles
                }
            }
        }
        let window = HostedWindow(title: "ChatGauge", size: NSSize(width: 980, height: 680), autosave: "ChatGaugeChatWindow", resizable: true) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(ChatWindowView(engine: self.engine, store: store, actions: self.actions, hub: self.hub))
        }
        chatWindow = window
        chatWindowOpener = { [weak self] in
            window.show()
            let t = self?.engine.conversation.title ?? ""
            window.nsWindow?.title = t.isEmpty ? "ChatGauge" : "ChatGauge — \(t)"
        }
        engine.$conversation.map(\.title).removeDuplicates()
            .sink { title in
                DispatchQueue.main.async { window.nsWindow?.title = title.isEmpty ? "ChatGauge" : "ChatGauge — \(title)" }
            }
            .store(in: &cancellables)
        willQuit = { [weak self] in
            guard let self else { return }
            if self.engine.isStreaming { self.engine.stop() }
            if !self.engine.conversation.isEmpty { store.save(self.engine.conversation) }
        }
    }

    private func configureInstructions() {
        let store = instructions
        engine.systemPrompt = { model in store.file.systemPrompt(for: model) }
        engine.instructionsName = { [weak engine] in store.file.enabled ? (engine?.conversation.model ?? "Default") : nil }
        hub.instructionsMenu = AnyView(PresetMenu(store: store) { [weak self] in self?.showInstructions() })
        let window = HostedWindow(title: "ChatGauge Instructions", size: NSSize(width: 640, height: 680), autosave: "ChatGaugeInstructions") { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(ScrollView {
                InstructionsEditor(store: store, location: self.engine.location, models: self.engine.models.map(\.name)).padding(20)
            }.frame(minWidth: 600, minHeight: 600))
        }
        instructionsWindow = window
        instructionsOpener = { window.show() }
    }

    private func wireActions() {
        actions.closePopover = { [weak self] in self?.popover.performClose(nil) }
        actions.attachImages = { [weak self] in self?.attachImages() }
        actions.quit = { NSApp.terminate(nil) }
        actions.openSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        actions.installModel = { [weak self] name in
            guard let self else { return }
            let e = self.engine
            let bytes = ModelCatalog.entry(name)?.bytes ?? 0
            let a = NSAlert()
            a.messageText = "Install \(name)?"
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let lines = ModelCatalog.pullPlan(model: name, serverURL: e.settings.serverURL).joined(separator: "\n")
            a.informativeText = "This will run:\n\n\(lines)\n\nAbout \(size). Nothing downloads until you click Install."
            a.addButton(withTitle: "Install")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { e.pull(name) }
        }
        actions.openChatWindow = { [weak self] in self?.showChatWindow() }
        actions.openInstructions = { [weak self] in self?.showInstructions() }
        actions.showAbout = { [weak self] in self?.showSettings(tab: "about") }
        actions.checkForUpdates = { [weak self] in self?.showSettings(tab: "updates") }
        actions.openSetup = { [weak self] in self?.showSetup() }
        hub.openSetup = { [weak self] in self?.showSetup() }
    }

    // MARK: Windows (replaced by the real ones as features land)

    func showSettings(tab: String?) {
        popover.performClose(nil)
        settingsWindowOpener?(tab)
    }

    func showChatWindow() {
        popover.performClose(nil)
        chatWindowOpener?()
    }

    // MARK: Setup guide

    /// Shown at first launch only on a Mac with nothing set up yet; an existing Ollama setup (or a settings file) means no.
    func setupShouldAutoShow() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let s = settingsStore.settings
        let snap = SetupSnapshot(settingsFileExisted: !settingsStore.firstLaunch, setupCompletedAt: s.setupCompletedAt,
                                 agents: OllamaAgent.discover(home: home),
                                 modelsOnDisk: ModelManifests.installed(in: engine.location.url).count,
                                 ollamaInstalled: SetupEnv.find("ollama") != nil)
        return SetupGate.shouldAutoShow(snap)
    }

    func showSetup() {
        popover.performClose(nil)
        if setupWindow == nil {
            let model = SetupModel(store: settingsStore, engine: engine)
            setupModel = model
            let window = HostedWindow(title: "Set Up ChatGauge", size: NSSize(width: 840, height: 620), autosave: "ChatGaugeSetup") { [weak self, weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(SetupWizardView(model: model, close: { self?.setupWindow?.close() }))
            }
            window.onClose = { [weak self] in
                self?.setupModel?.stopAll()
                self?.settingsStore.saveNow()
                self?.setupWindow = nil
                self?.setupModel = nil
                Task { await self?.engine.refresh() }
            }
            setupWindow = window
        }
        setupWindow?.show()
    }

    func showInstructions() {
        popover.performClose(nil)
        instructionsOpener?()
    }

    // MARK: Chat shortcuts (⌥⌘↑ / ⌥⌘↓, ⌘F, ⌘⌫)

    @objc func previousChatFromMenu(_ sender: Any?) { chats.step(-1) }
    @objc func nextChatFromMenu(_ sender: Any?) { chats.step(1) }
    @objc func findChatFromMenu(_ sender: Any?) { findChat() }
    @objc func trashChatFromMenu(_ sender: Any?) { promptTrashCurrentChat() }

    /// ⌘F / "Search…": the chat window with its search field focused.
    func findChat() {
        showChatWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.chats.searchFocusToken += 1 }
    }

    /// ⌘⌫: asks, then moves the open chat to the Trash (a sheet on the chat window, else a dialog).
    func promptTrashCurrentChat() {
        guard let s = chats.current else { NSSound.beep(); return }
        let w = chatWindow?.nsWindow
        chats.confirmTrash(s, window: (w?.isVisible == true && !popover.isShown) ? w : nil)
    }

    /// Chat shortcuts for the popover and the chat window. Returns true when handled.
    private func handleChatShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let inPopover = popover.isShown && event.window === popover.contentViewController?.view.window
        let inChatWindow = event.window === chatWindow?.nsWindow
        guard inPopover || inChatWindow else { return false }
        switch (event.keyCode, mods) {
        case (126, [.command, .option]): chats.step(-1); return true
        case (125, [.command, .option]): chats.step(1); return true
        case (3, [.command]):
            if inChatWindow { chats.searchFocusToken += 1 } else { findChat() }
            return true
        case (51, [.command]):
            let editor = event.window?.firstResponder as? NSTextView
            guard TrashShortcut.handles(editingText: editor != nil, fieldIsEmpty: editor?.string.isEmpty ?? true) else { return false }
            promptTrashCurrentChat()
            return true
        default: return false
        }
    }

    var settingsWindowOpener: ((String?) -> Void)?
    var chatWindowOpener: (() -> Void)?
    var instructionsOpener: (() -> Void)?

    @objc func openSettingsFromMenu(_ sender: Any?) { showSettings(tab: nil) }
    @objc func openChatWindowFromMenu(_ sender: Any?) { showChatWindow() }

    // MARK: Status item

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let s = engine.status
        let showDot = settingsStore.settings.showStatusDot && (s.level == .problem || s.level == .busy)
        button.image = showDot
            ? ChatMarkImage.withDot(color: Palette.nsColor(s.level), appearance: button.effectiveAppearance)
            : ChatMarkImage.template()
        switch settingsStore.settings.menuBarText {
        case .none: button.title = ""
        case .modelName: button.title = s.model.map { " " + $0 } ?? ""
        case .status: button.title = " " + s.title
        }
        button.toolTip = "ChatGauge: \(s.title)"
    }

    // MARK: Popover

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// activate: false when a drag opens it (Finder keeps the drag; the popover only needs to be on screen).
    func showPopover(activate: Bool = true) {
        guard let button = statusItem.button else { return }
        if activate { AppActivation.activateNow() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate { popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil) }
        if popoverPolicy.closesOnOutsideClick { startOutsideClickMonitor() }
        engine.schedule(interval: 10)
        Task {
            await engine.refresh()
            engine.warmUp()
        }
    }

    var popoverPolicy: PopoverPolicy { PopoverPolicy(pinned: settingsStore.settings.pinPopover) }

    /// Pinned: application-defined (stays open across any clicks elsewhere). Unpinned: semi-transient + drag-aware
    /// outside-click monitor (a plain click elsewhere closes it; pressing and dragging a file doesn't).
    private func applyPin(_ pinned: Bool) {
        let policy = PopoverPolicy(pinned: pinned)
        popover.behavior = policy.semitransient ? .semitransient : .applicationDefined
        if policy.closesOnOutsideClick {
            if popover.isShown { startOutsideClickMonitor() }
        } else {
            stopOutsideClickMonitor()
        }
    }

    // MARK: Attach and drop

    /// The paperclip. A picker from the popover would take focus from it, so (as in ClipGauge)
    /// the chat moves to the chat window, which stays put, and the picker opens there as a sheet.
    func attachImages() {
        let fromPopover = popover.isShown
        if fromPopover && popoverPolicy.attachInChatWindow { showChatWindow() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to attach"
        let add: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] r in
            guard r == .OK, let self, let panel else { return }
            self.engine.addAttachments(DroppedFiles.images(panel.urls).compactMap(Attachment.make(fromFile:)))
        }
        AppActivation.activateNow()
        if let w = chatWindow?.nsWindow, w.isVisible, !(fromPopover && !popoverPolicy.attachInChatWindow) {
            w.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: w, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }

    /// Images dropped on the menu bar icon: into the popover if it's open (a drag over the icon opens it), else the chat window.
    func receiveDropped(_ found: [Attachment]) {
        guard !found.isEmpty else { return }
        engine.addAttachments(found)
        if popover.isShown { return }   // the popover is open (the drag opened it, or it was already): it's there
        showChatWindow()
    }

    private func droppedAttachments(_ info: NSDraggingInfo) -> [Attachment] {
        let pb = info.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return DroppedFiles.images(urls).compactMap(Attachment.make(fromFile:)) }
        let imgs = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        return imgs.compactMap { Attachment.make(from: $0, name: "Dropped image") }
    }

    private func dragHasImage(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return !DroppedFiles.images(urls).isEmpty
        }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragHasImage(sender) else { return [] }
        statusItem.button?.highlight(true)
        beginIconDrag()
        return .copy
    }

    // MARK: Drag opens the popover

    private var dragOpenedPopover = false
    private var dragStart = Date.distantPast
    private var dragAttachmentsBefore = 0
    private var dragWatch: Timer?

    /// An image drag entered the menu bar icon: open the popover (if closed) so it can be dropped on the chat, and
    /// keep it open for the whole drag. When the mouse button comes up: close it again only if it was opened by this
    /// drag and nothing was dropped (on the icon or the chat).
    func beginIconDrag() {
        guard dragWatch == nil else { return }
        dragStart = Date()
        dragAttachmentsBefore = engine.attachments.count
        dragOpenedPopover = !popover.isShown
        if dragOpenedPopover { showPopover(activate: false) }
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.dragWatch?.invalidate(); self.dragWatch = nil
                // The chat view's drop loads the image asynchronously; give it a moment before deciding.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.endIconDrag() }
            }
        }
    }

    private func endIconDrag() {
        if DragOpenedPopover.shouldClose(openedByDrag: dragOpenedPopover, dropAt: engine.lastDropAt, dragStart: dragStart,
                                         attachmentsBefore: dragAttachmentsBefore, attachmentsNow: engine.attachments.count),
           popover.isShown {
            popover.performClose(nil)
        }
        dragOpenedPopover = false
    }
    func draggingExited(_ sender: NSDraggingInfo?) { statusItem.button?.highlight(false) }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let found = droppedAttachments(sender)
        guard !found.isEmpty else { return false }
        engine.lastDropAt = Date()
        DispatchQueue.main.async { self.receiveDropped(found) }
        return true
    }

    /// Self-test for the attach / drop / pin paths (no real drag or click: those need a person).
    func selfTestAttachAndDrop(out: URL) async -> String {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func yn(_ b: Bool) -> String { b ? "PASS" : "FAIL" }
        var log = "== attach/drop/pin\n"
        let png = out.appendingPathComponent("drop-test.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try? rep?.representation(using: .png, properties: [:])?.write(to: png)
        engine.attachments.removeAll()

        // 1. Attach from the popover: the chat moves to the chat window and the picker is a sheet there.
        showPopover(); await wait(1)
        attachImages(); await wait(1.5)
        let w = chatWindow?.nsWindow
        log += "   \(yn(!popover.isShown)) attach from popover closes popover (shown=\(popover.isShown))\n"
        log += "   \(yn(w?.isVisible == true)) chat window visible\n"
        log += "   \(yn(w?.attachedSheet is NSOpenPanel)) picker is a sheet on the chat window\n"
        log += "   \(yn(w?.hidesOnDeactivate == false)) chat window hidesOnDeactivate=false\n"
        if let w, let sheet = w.attachedSheet { w.endSheet(sheet, returnCode: .cancel) }
        await wait(0.5)

        // 2. Drop on the menu bar icon (same path performDragOperation takes).
        chatWindow?.nsWindow?.orderOut(nil)
        let found = DroppedFiles.images([png, out.appendingPathComponent("report.txt")]).compactMap(Attachment.make(fromFile:))
        receiveDropped(found); await wait(1)
        log += "   \(yn(found.count == 1 && engine.attachments.count == 1)) icon drop attaches 1 image (got \(engine.attachments.count))\n"
        log += "   \(yn(chatWindow?.nsWindow?.isVisible == true)) icon drop opens chat window\n"
        log += "   \(yn(statusItem.button?.window?.delegate === self)) status icon window forwards drags to AppDelegate\n"
        if let v = chatWindow?.nsWindow?.contentView { log += UISelfTest.snapshot("5-chatwindow-drop", view: v, engine: engine, out: out) }

        // 3. Pin: application-defined popover, no outside-click monitor; remembered in settings.
        settingsStore.update { $0.pinPopover = true }; await wait(0.5)
        showPopover(); await wait(1)
        log += "   \(yn(popover.behavior == .applicationDefined)) pinned popover is application-defined\n"
        log += "   \(yn(outsideClickMonitor == nil)) pinned popover has no outside-click monitor\n"
        if let v = popover.contentViewController?.view { log += UISelfTest.snapshot("6-pinned", view: v, engine: engine, out: out) }
        receiveDropped(found); await wait(0.5)
        log += "   \(yn(popover.isShown && engine.attachments.count == 2)) icon drop with pinned popover adds to popover\n"
        settingsStore.update { $0.pinPopover = false }; await wait(0.5)
        log += "   \(yn(popover.behavior == .semitransient && outsideClickMonitor != nil)) unpin restores semi-transient + monitor\n"
        popover.performClose(nil); await wait(0.5)
        engine.attachments.removeAll()

        // 4. Switching to another app (what happens when you click Finder to pick up a file).
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        func switchToFinder() async {
            // macOS 14+ cooperative activation: hand activation to Finder, as a click in Finder would.
            if let finder { NSApp.yieldActivation(to: finder); finder.activate() }
            await wait(1.5)
        }
        popover.behavior = .transient
        showPopover(); await wait(1)
        await switchToFinder()
        let transientShown = popover.isShown
        let switched = finder?.isActive ?? false
        func yn2(_ b: Bool) -> String { switched ? yn(b) : "INFO (Finder didn't take activation in this test session)" }
        log += "   \(yn2(!transientShown)) OLD .transient: switching to Finder closes the popover (shown=\(transientShown), finder active=\(finder?.isActive ?? false)) <- the bug\n"
        popover.performClose(nil); applyPin(false); await wait(0.5)
        showPopover(); await wait(1)
        await switchToFinder()
        log += "   \(yn2(popover.isShown)) NEW .semitransient: switching to Finder keeps it open (finder active=\(finder?.isActive ?? false))\n"

        // 5. Outside clicks in another app (fed through the same handler the global monitor uses).
        outsideMouse(.down, x: 100, y: 100); outsideMouse(.dragged, x: 160, y: 120); outsideMouse(.up, x: 600, y: 20)
        await wait(0.5)
        log += "   \(yn(popover.isShown)) press-and-drag in another app keeps it open\n"
        outsideMouse(.down, x: 300, y: 300); outsideMouse(.up, x: 300, y: 300)
        await wait(0.8)
        log += "   \(yn(!popover.isShown)) plain click in another app closes it\n"

        // 6. A file drag enters the menu bar icon (the same call draggingEntered makes), popover closed.
        beginIconDrag(); await wait(0.3)
        log += "   \(yn(popover.isShown)) drag entering the icon opens the popover\n"
        await wait(1.5)
        log += "   \(yn(!popover.isShown)) drag ended with no drop: popover closes again\n"
        beginIconDrag(); await wait(0.1)
        // Drop on the popover's chat area (what ImageDropModifier does).
        engine.lastDropAt = Date(); engine.addAttachments(found)
        if let v = popover.contentViewController?.view { log += UISelfTest.snapshot("7-drag-opened", view: v, engine: engine, out: out) }
        await wait(1.5)
        log += "   \(yn(popover.isShown && engine.attachments.count == 1)) drop on the chat area: popover stays open with the image\n"
        chatWindow?.nsWindow?.orderOut(nil)
        beginIconDrag(); await wait(0.1)
        receiveDropped(found); await wait(1.5)
        log += "   \(yn(popover.isShown && engine.attachments.count == 2 && chatWindow?.nsWindow?.isVisible != true)) drop on the icon: goes into the open popover\n"

        // 7. Esc closes it.
        showPopover(); await wait(0.8)
        if let pw = popover.contentViewController?.view.window,
           let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: pw.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53) {
            NSApp.sendEvent(esc)
        }
        await wait(0.8)
        log += "   \(yn(!popover.isShown)) Esc closes the popover\n"
        togglePopover(nil); await wait(0.8)
        let opened = popover.isShown
        togglePopover(nil); await wait(0.8)
        log += "   \(yn(opened && !popover.isShown)) icon click / hotkey (togglePopover) opens and closes it\n"
        return log
    }

    /// Self-test for chat organizing: auto titles, groups, pinning, switching (keys and the popover switcher),
    /// duplicate, export, ⌘F and the ⌘⌫ prompt (answered Cancel: nothing goes to the Trash), reopen-last.
    func selfTestChats(out: URL) async -> String {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func yn(_ b: Bool) -> String { b ? "PASS" : "FAIL" }
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags, in w: NSWindow?) {
            guard let w, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                  context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                  isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(e, atStart: false)
        }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        var log = "== chats: organize / switch\n"
        popover.performClose(nil); chatWindow?.nsWindow?.orderOut(nil); engine.attachments.removeAll()
        await wait(0.5)

        // Auto title for the first chat (the mock answers "\"Status Check.\"" to the non-streaming request).
        for _ in 0..<20 where engine.titling { await wait(0.25) }
        chats.refresh()
        let first = engine.conversation
        log += "   \(yn(first.title == "Status Check" && first.titleSource == .model)) auto title from the local model (title=\(first.title.debugDescription), source=\(first.titleSource.rawValue))\n"
        let firstFile = chats.summaries.first { $0.id == first.id }.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        log += "   \(yn(firstFile.contains("title: \"Status Check\"") && firstFile.contains("titled: model"))) saved file has the model title\n"

        // Seed a history across the groups.
        let lib = chats.library, now = Date(), cal = Calendar.current
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let png = rep?.representation(using: .png, properties: [:])
        @discardableResult
        func seed(_ title: String, days: Int, minutes: Double = 0, pinned: Bool = false, image: Data? = nil) -> UUID {
            let d = (cal.date(byAdding: .day, value: -days, to: now) ?? now).addingTimeInterval(-minutes * 60)
            var c = Conversation(title: title, createdAt: d, updatedAt: d, model: "qwen2.5vl:7b",
                                 messages: [ChatMessage(role: .user, text: "Seed \(title)", images: image.map { [$0] } ?? [], createdAt: d),
                                            ChatMessage(role: .assistant, text: "Reply for \(title)", createdAt: d, model: "qwen2.5vl:7b")])
            c.pinned = pinned
            _ = try? lib.save(c, format: .markdown)
            return c.id
        }
        seed("Trip ideas", days: 30, pinned: true)
        seed("Recipe swap", days: 0, minutes: 5)
        let yID = seed("Yesterday notes", days: 1)
        seed("Weekly plan", days: 3)
        let oldID = seed("Old project", days: 20, image: png)
        chats.refresh()
        let secs = chats.sections
        log += "   \(yn(secs.map(\.group) == ChatGroup.allCases && secs.map(\.chats.count) == [1, 2, 1, 1, 1])) groups: \(secs.map { "\($0.group.rawValue)=\($0.chats.count)" }.joined(separator: ", "))\n"
        let yText = chats.summaries.first { $0.id == yID }.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        log += "   \(yn(!yText.contains("pinned:") && !yText.contains("titled:"))) plain chat header has no pinned/titled lines (old-file shape)\n"

        // Chat window: sidebar sections, then ⌥⌘↓ / ⌥⌘↑ through the sidebar order.
        showChatWindow(); await wait(1)
        let w = chatWindow?.nsWindow
        w?.makeKeyAndOrderFront(nil)
        let order = chats.ordered
        log += "   order: \(order.map(\.title).joined(separator: " > "))\n"
        chats.open(order[1]); await wait(0.4)
        key(125, down, [.command, .option], in: w); await wait(0.6)
        log += "   \(yn(engine.conversation.id == order[2].id)) ⌥⌘↓ in the chat window opens the next chat (\(engine.conversation.title))\n"
        key(126, up, [.command, .option], in: w); await wait(0.4)
        key(126, up, [.command, .option], in: w); await wait(0.6)
        log += "   \(yn(engine.conversation.id == order[0].id)) ⌥⌘↑ twice goes back up to the pinned chat (\(engine.conversation.title))\n"
        key(126, up, [.command, .option], in: w); await wait(0.4)
        log += "   \(yn(engine.conversation.id == order[0].id)) ⌥⌘↑ at the top stays put\n"

        // Pin / unpin.
        if let weekly = chats.summaries.first(where: { $0.title == "Weekly plan" }) { chats.setPinned(weekly, true) }
        if let trip = chats.summaries.first(where: { $0.title == "Trip ideas" }) { chats.setPinned(trip, false) }
        await wait(0.5)
        let s2 = chats.sections
        let pinnedNames = s2.first { $0.group == .pinned }?.chats.map(\.title) ?? []
        let olderNames = s2.first { $0.group == .older }?.chats.map(\.title) ?? []
        log += "   \(yn(pinnedNames == ["Weekly plan"] && olderNames.contains("Trip ideas"))) pin Weekly plan, unpin Trip ideas (pinned=\(pinnedNames), older=\(olderNames))\n"
        log += "   \(yn(engine.conversation.title == "Trip ideas" && !engine.conversation.pinned)) unpinning the open chat updates it too\n"
        let wText = chats.summaries.first { $0.title == "Weekly plan" }.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        log += "   \(yn(wText.contains("\npinned: true\n"))) pinned is stored as `pinned: true` in the header\n"
        if let v = w?.contentView { log += UISelfTest.snapshot("8-sidebar-groups", view: v, engine: engine, out: out) }

        // Rename keeps a hand-made title.
        chats.rename(engine.conversation.id, to: "Trips 2027"); await wait(0.3)
        let rText = chats.current.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        log += "   \(yn(engine.conversation.titleSource == .user && rText.contains("titled: user"))) rename marks the title as the user's (auto titles leave it alone)\n"
        let renamedID = engine.conversation.id
        chats.applyModelTitle(renamedID, "Should Not Apply")
        log += "   \(yn(chats.summaries.first { $0.id == renamedID }?.title == "Trips 2027")) a late model title doesn't replace a rename\n"

        // Duplicate (with its image) and export.
        if let old = chats.summaries.first(where: { $0.id == oldID }) {
            let copy = chats.duplicate(old)
            let copyImgs = copy?.messages.flatMap(\.imageFiles) ?? []
            log += "   \(yn(copy?.title == "Old project copy" && copyImgs.count == 1 && copyImgs[0].contains(copy!.id.uuidString.lowercased()) == true && engine.conversation.id == copy?.id)) duplicate: new chat with its own image copy, opened (\(copyImgs))\n"
            let dest = out.appendingPathComponent("export/Old project.md")
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ok = chats.exportMarkdown(old, to: dest, copyImages: true)
            let md = (try? String(contentsOf: dest, encoding: .utf8)) ?? ""
            let imgs = (try? FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("export/Old project images").path)) ?? []
            log += "   \(yn(ok && !md.contains("chatgauge") && !md.contains("<!--") && md.hasPrefix("# Old project") && md.contains("](Old%20project%20images/") && imgs.count == 1)) export as clean Markdown with copied images (\(imgs.count) image)\n"
            let dest2 = out.appendingPathComponent("export/Old project no images.md")
            _ = chats.exportMarkdown(old, to: dest2, copyImages: false)
            let md2 = (try? String(contentsOf: dest2, encoding: .utf8)) ?? ""
            log += "   \(yn(md2.contains("](file://") && !FileManager.default.fileExists(atPath: out.appendingPathComponent("export/Old project no images images").path))) export without copying links to the saved images\n"
        }

        // Popover switcher: pinned first, ~10 recent; picking one switches the popover's chat.
        showPopover(); await wait(1)
        let items = chats.switcher
        log += "   \(yn(hub.chatSwitcher != nil && items.first?.title == "Weekly plan" && items.count == chats.summaries.count && items.count <= 10)) switcher lists \(items.count): \(items.map(\.title).joined(separator: ", "))\n"
        if let target = items.first(where: { $0.title == "Recipe swap" }) {
            chats.open(target); await wait(0.6)
            // The popover renders the engine's conversation (see 9-popover-switcher.png); check the model behind it.
            let shown = engine.conversation.messages.first?.text == "Seed Recipe swap"
            log += "   \(yn(engine.conversation.id == target.id && shown && popover.isShown)) switcher pick shows that chat in the popover\n"
        }
        if let v = popover.contentViewController?.view { log += UISelfTest.snapshot("9-popover-switcher", view: v, engine: engine, out: out) }
        let before = engine.conversation.id
        key(125, down, [.command, .option], in: popover.contentViewController?.view.window); await wait(0.6)
        log += "   \(yn(engine.conversation.id != before)) ⌥⌘↓ in the popover moves to the next chat (\(engine.conversation.title))\n"
        // ⌘F in the popover: chat window with the search field focused.
        key(3, "f", [.command], in: popover.contentViewController?.view.window); await wait(1.2)
        let fr = chatWindow?.nsWindow?.firstResponder
        let field = (fr as? NSTextView)?.delegate as? NSTextField
        log += "   \(yn(!popover.isShown && chatWindow?.nsWindow?.isVisible == true && field?.placeholderString == "Search chats")) ⌘F / Search…: chat window with search focused (first responder: \(fr.map { String(describing: type(of: $0)) } ?? "none"), placeholder=\(field?.placeholderString ?? "-"))\n"

        // ⌘⌫ asks first (answered Cancel). In a field with text it stays "delete to start of line".
        if let cw = chatWindow?.nsWindow {
            chats.query = "Recipe"; await wait(0.4)
            (cw.firstResponder as? NSTextView)?.string = "Recipe"
            key(51, "\u{8}", [.command], in: cw); await wait(0.8)
            log += "   \(yn(cw.attachedSheet == nil)) ⌘⌫ while typing in a field with text: no trash prompt\n"
            chats.query = ""
            cw.makeFirstResponder(nil); await wait(0.3)
            let keep = engine.conversation.id
            key(51, "\u{8}", [.command], in: cw); await wait(0.8)
            let sheet = cw.attachedSheet
            log += "   \(yn(sheet != nil)) ⌘⌫ asks before moving the open chat to the Trash\n"
            if let v = sheet?.contentView { log += UISelfTest.snapshot("10-trash-prompt", view: v, engine: engine, out: out) }
            if let sheet { cw.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            await wait(0.5)
            log += "   \(yn(chats.summaries.contains { $0.id == keep } && engine.conversation.id == keep)) Cancel keeps the chat\n"
        }

        // Reopen the last chat at launch (the same call launch makes).
        engine.newChat(); await wait(0.3)
        let last = ChatGrouping.lastChat(chats.summaries)
        let reopened = chats.reopenLast()
        log += "   \(yn(reopened && engine.conversation.id == last?.id)) reopen last chat picks the most recent (\(engine.conversation.title))\n"
        log += "   \(yn(!ChatSettings().reopenLastChat && ChatSettings().autoTitles)) defaults: reopen last off, auto titles on\n"
        chatWindow?.nsWindow?.orderOut(nil)
        return log
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
        engine.schedule(interval: 60)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        clickTracker = OutsideClickTracker()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] e in
            let kind: OutsideClickTracker.Event
            switch e.type {
            case .leftMouseDown: kind = .down
            case .leftMouseDragged: kind = .dragged
            case .leftMouseUp: kind = .up
            default: kind = .rightDown
            }
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.outsideMouse(kind, x: p.x, y: p.y) }
        }
    }

    private var clickTracker = OutsideClickTracker()

    /// A mouse event in another app while the popover is open (also called by the self-test).
    func outsideMouse(_ kind: OutsideClickTracker.Event, x: Double, y: Double) {
        guard popover.isShown, popoverPolicy.closesOnOutsideClick, dragWatch == nil else { return }
        if clickTracker.handle(kind, x: x, y: y) { popover.performClose(nil) }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    /// ⌘V with an image on the pasteboard attaches it (text pastes as usual).
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc closes the popover (it no longer closes by itself when you switch apps).
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                let closed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.popover.isShown, event.window === self.popover.contentViewController?.view.window else { return false }
                    self.popover.performClose(nil)
                    return true
                }
                if closed { return nil }
            }
            if MainActor.assumeIsolated({ self?.handleChatShortcut(event) ?? false }) { return nil }
            let isPaste = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "v"
            guard isPaste else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      self.popover.isShown || (self.chatWindow?.nsWindow?.isKeyWindow ?? false),
                      Attachment.pasteboardHasImage() else { return false }
                let found = Attachment.fromPasteboard()
                guard !found.isEmpty else { return false }
                self.engine.addAttachments(found)
                return true
            }
            return handled ? nil : event
        }
    }

    private func registerHotKey(_ key: HotKey) {
        HotKeyCenter.shared.unregister()
        guard key.enabled, key.isValid else { return }
        _ = HotKeyCenter.shared.register(key)
    }

    // MARK: Quit

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        settingsStore.saveNow()
        willQuit?()
        Task {
            // Unload only models ChatGauge itself loaded; never anyone else's. Bounded so quit stays quick.
            let work = Task { await self.engine.unloadOwnModels() }
            let deadline = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); work.cancel() }
            _ = await work.value
            deadline.cancel()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Later features save here before quit.
    var willQuit: (() -> Void)?

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

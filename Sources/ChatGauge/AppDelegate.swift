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
    private var outsideClickMonitor: Any?
    private var pasteMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var quitting = false

    /// Windows opened from the gear menu (filled in by later features).
    var settingsWindow: HostedWindow?
    var chatWindow: HostedWindow?
    var instructionsWindow: HostedWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self, settingsAction: #selector(openSettingsFromMenu(_:)),
                         chatWindowAction: #selector(openChatWindowFromMenu(_:)))
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

        popover.behavior = PopoverPolicy(pinned: settingsStore.settings.pinPopover).transient ? .transient : .applicationDefined
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
        engine.start()
        if let out = UISelfTest.outputFolder {
            UISelfTest.run(out: out, open: { [weak self] in self?.showPopover() },
                           view: { [weak self] in self?.popover.contentViewController?.view }, engine: engine,
                           extra: { [weak self] out in await self?.selfTestAttachAndDrop(out: out) ?? "" })
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
        engine.systemPrompt = { store.file.systemPrompt() }
        engine.instructionsName = { store.file.enabled ? store.file.active?.name : nil }
        hub.instructionsMenu = AnyView(PresetMenu(store: store) { [weak self] in self?.showInstructions() })
        let window = HostedWindow(title: "ChatGauge Instructions", size: NSSize(width: 640, height: 680), autosave: "ChatGaugeInstructions") { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(ScrollView {
                InstructionsEditor(store: store, location: self.engine.location).padding(20)
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
        actions.openChatWindow = { [weak self] in self?.showChatWindow() }
        actions.openInstructions = { [weak self] in self?.showInstructions() }
        actions.showAbout = { [weak self] in self?.showSettings(tab: "about") }
        actions.checkForUpdates = { [weak self] in self?.showSettings(tab: "updates") }
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

    func showInstructions() {
        popover.performClose(nil)
        instructionsOpener?()
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

    func showPopover() {
        guard let button = statusItem.button else { return }
        AppActivation.activateNow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        if popoverPolicy.closesOnOutsideClick { startOutsideClickMonitor() }
        engine.schedule(interval: 10)
        Task {
            await engine.refresh()
            engine.warmUp()
        }
    }

    var popoverPolicy: PopoverPolicy { PopoverPolicy(pinned: settingsStore.settings.pinPopover) }

    /// Pinned: application-defined (stays open across clicks in Finder). Unpinned: transient, like ClipGauge.
    private func applyPin(_ pinned: Bool) {
        let policy = PopoverPolicy(pinned: pinned)
        popover.behavior = policy.transient ? .transient : .applicationDefined
        if policy.closesOnOutsideClick {
            if popover.isShown { startOutsideClickMonitor() }
        } else {
            stopOutsideClickMonitor()
        }
    }

    // MARK: Attach and drop

    /// The paperclip. From the transient popover the picker would steal focus and close it, so (as in ClipGauge)
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

    /// Images dropped on the menu bar icon: into the pinned popover if it's open, else into the chat window.
    func receiveDropped(_ found: [Attachment]) {
        guard !found.isEmpty else { return }
        engine.addAttachments(found)
        if popover.isShown && !popoverPolicy.closesOnOutsideClick { return }
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
        return .copy
    }
    func draggingExited(_ sender: NSDraggingInfo?) { statusItem.button?.highlight(false) }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let found = droppedAttachments(sender)
        guard !found.isEmpty else { return false }
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

        // 1. Attach from the (transient) popover: the chat moves to the chat window and the picker is a sheet there.
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
        log += "   \(yn(popover.behavior == .transient && outsideClickMonitor != nil)) unpin restores transient + monitor\n"
        return log
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
        engine.schedule(interval: 60)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    /// ⌘V with an image on the pasteboard attaches it (text pastes as usual).
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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

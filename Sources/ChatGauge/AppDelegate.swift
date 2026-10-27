import AppKit
import ChatGaugeCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let settingsStore = SettingsStore()
    lazy var engine = ChatEngine(settingsStore: settingsStore)
    let actions = AppActions()
    let hub = FeatureHub()

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
        statusItem.autosaveName = "ChatGaugeStatusItem"
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.setAccessibilityLabel("ChatGauge")
        }
        updateStatusItem()

        popover.behavior = .transient
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
        settingsStore.$settings.map(\.hotKey).removeDuplicates()
            .sink { [weak self] key in DispatchQueue.main.async { self?.registerHotKey(key) } }
            .store(in: &cancellables)
        HotKeyCenter.shared.action = { [weak self] in self?.togglePopover(nil) }

        installPasteMonitor()
        engine.start()
    }

    /// Hook for later features (instructions, chats, voice, settings, updates).
    func configureFeatures() {}

    private func wireActions() {
        actions.closePopover = { [weak self] in self?.popover.performClose(nil) }
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
        startOutsideClickMonitor()
        engine.schedule(interval: 10)
        Task {
            await engine.refresh()
            engine.warmUp()
        }
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
            MainActor.assumeIsolated {
                guard let self,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v",
                      self.popover.isShown || (self.chatWindow?.nsWindow?.isKeyWindow ?? false),
                      Attachment.pasteboardHasImage() else { return event }
                let found = Attachment.fromPasteboard()
                guard !found.isEmpty else { return event }
                self.engine.addAttachments(found)
                return nil
            }
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

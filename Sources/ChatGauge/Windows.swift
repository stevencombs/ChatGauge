import AppKit
import SwiftUI

/// A reusable window that hosts a SwiftUI view, created on first show and torn down on close.
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let size: NSSize
    private let autosave: String
    private let resizable: Bool
    private let makeView: () -> AnyView
    var onClose: (() -> Void)?

    init(title: String, size: NSSize, autosave: String, resizable: Bool = false, makeView: @escaping () -> AnyView) {
        self.title = title
        self.size = size
        self.autosave = autosave
        self.resizable = resizable
        self.makeView = makeView
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeView())
            let w = NSWindow(contentViewController: host)
            w.title = title
            w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            // A normal window: it stays on screen when you click Finder (never hides on deactivate), so you can drag
            // files onto it from behind.
            w.hidesOnDeactivate = false
            w.setContentSize(size)
            if resizable { w.contentMinSize = NSSize(width: 520, height: 420) }
            w.delegate = self
            w.center()
            w.setFrameAutosaveName(autosave)
            window = w
        }
        AppActivation.activateNow()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        onClose?()
    }
}

/// Synchronous activation for a menu bar app (the cooperative request often lands late for LSUIElement apps).
@MainActor
enum AppActivation {
    static func activateNow() {
        if NSApp.isActive { return }
        NSApp.activate()
        if !NSApp.isActive { (NSApp as ImmediateActivating).activate(ignoringOtherApps: true) }
    }
}

@MainActor
private protocol ImmediateActivating {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: ImmediateActivating {}

/// Opens the PayPal tip page from the app menu.
@MainActor
final class SupportTarget: NSObject {
    static let shared = SupportTarget()
    @objc func openSupport(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.tipURL) }
}

/// A menu bar app has no visible menu bar, but a main menu still provides ⌘, ⌘Q, ⌘W and copy/paste.
enum MainMenu {
    @MainActor
    static func install(target: AnyObject, settingsAction: Selector, chatWindowAction: Selector) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: settingsAction, keyEquivalent: ",")
        settings.target = target
        app.addItem(settings)
        let chat = NSMenuItem(title: "Open Chat Window…", action: chatWindowAction, keyEquivalent: "A")
        chat.keyEquivalentModifierMask = [.command, .shift]
        chat.target = target
        app.addItem(chat)
        let support = NSMenuItem(title: "Support ChatGauge…", action: #selector(SupportTarget.openSupport(_:)), keyEquivalent: "")
        support.target = SupportTarget.shared
        app.addItem(support)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit ChatGauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

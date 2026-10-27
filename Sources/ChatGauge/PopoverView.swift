import AppKit
import ChatGaugeCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var actions: AppActions
    @ObservedObject var hub: FeatureHub

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let row = hub.updatesRow { row.padding(.horizontal, 12).padding(.top, 8) }
            chatCard
            footer
        }
        .frame(width: 400, height: 600)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ChatMarkView(size: 18)
            Text("ChatGauge").font(.headline)
            Spacer()
            Text("LOCAL · \((engine.status.model ?? engine.preferredModel ?? "no model").uppercased())")
                .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
            if let switcher = hub.chatSwitcher { switcher }
            PinButton(settingsStore: settingsStore)
            GearMenu(actions: actions, hub: hub)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var chatCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ModelChip(engine: engine)
                StatusLine(engine: engine)
                Spacer()
                Button { engine.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New chat (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
                Button { actions.openChatWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help("Open in the chat window")
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
                if let menu = hub.instructionsMenu { menu } else {
                    Text("Instructions: \(hub.instructionsSummary)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("· \(settingsStore.settings.hotKey.enabled ? settingsStore.settings.hotKey.display : "no shortcut")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Chat Window") { actions.openChatWindow() }.controlSize(.small)
                Button("Instructions") { actions.openInstructions() }.controlSize(.small)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("v\(AppInfo.version) · local").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Support ChatGauge…") { NSWorkspace.shared.open(AppInfo.tipURL) }
                    .buttonStyle(.borderless).font(.caption)
                Button("Quit ChatGauge") { actions.quit() }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// Pin: keeps the popover open while you click Finder (to drag in an image). Remembered in Settings.
struct PinButton: View {
    @ObservedObject var settingsStore: SettingsStore
    var body: some View {
        let pinned = settingsStore.settings.pinPopover
        Button { settingsStore.update { $0.pinPopover.toggle() } } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .rotationEffect(.degrees(pinned ? 0 : 45))
                .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(pinned ? "Pinned: stays open when you click other apps. Click to unpin."
                     : "Pin to keep ChatGauge open while you click other apps (for dragging in images)")
        .accessibilityLabel(pinned ? "Unpin popover" : "Pin popover")
    }
}

struct GearMenu: View {
    @ObservedObject var actions: AppActions
    @ObservedObject var hub: FeatureHub
    var body: some View {
        Menu {
            Button("Open Chat Window…") { actions.openChatWindow() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Instructions…") { actions.openInstructions() }
            Button("Settings…") { actions.openSettings(nil) }.keyboardShortcut(",", modifiers: .command)
            Divider()
            Button(hub.updateAvailable ? "Check for Updates… •" : "Check for Updates…") { actions.checkForUpdates() }
            Button("About ChatGauge") { actions.showAbout() }
            Divider()
            Button("Quit ChatGauge") { actions.quit() }.keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings and more")
    }
}

/// Things later features plug into the popover (updates row, voice button, instructions summary).
@MainActor
final class FeatureHub: ObservableObject {
    @Published var updatesRow: AnyView?
    @Published var updateAvailable = false
    @Published var voiceButton: AnyView?
    @Published var instructionsSummary = "Default"
    @Published var instructionsMenu: AnyView?
    /// The popover header's chat switcher (from the chats feature).
    @Published var chatSwitcher: AnyView?
    /// Settings → Updates content and the About tab's update row (from the updates feature).
    @Published var updatesPane: AnyView?
    @Published var aboutUpdatesRow: AnyView?
    /// Diagnostics lines added by features (updates, voice).
    var diagnostics: [() -> [(String, String)]] = []
    /// Opens the setup guide (wired by the app delegate).
    var openSetup: () -> Void = {}
}

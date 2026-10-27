import AppKit
import Carbon
import ChatGaugeCore
import SwiftUI

/// A titled, rounded group of rows (the Gauge settings look).
struct PrefGroup<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    var accessory: Accessory
    var content: Content

    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.footer = footer
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || !(accessory is EmptyView) {
                HStack {
                    if let title {
                        Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer()
                    accessory
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            if let footer {
                Text(.init(footer)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

extension PrefGroup where Accessory == EmptyView {
    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.accessory = EmptyView()
        self.content = content()
    }
}

struct PrefRow<Trailing: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 7)
    }
}

/// A toggle row: label and detail on the left, a switch on the right.
struct PrefToggle: View {
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        PrefRow(label: label, detail: detail) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().accessibilityLabel(label)
        }
    }
}

/// PayPal-blue capsule.
struct TipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color(red: 0.0, green: 0.19, blue: 0.53).opacity(configuration.isPressed ? 0.75 : 1)))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .contentShape(Capsule())
    }
}

/// Always-red YouTube capsule (system prominent buttons turn gray in inactive windows).
struct YouTubeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color(red: 0.85, green: 0.11, blue: 0.10).opacity(configuration.isPressed ? 0.75 : 1)))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .contentShape(Capsule())
    }
}

/// Click, then press the new shortcut. Esc cancels; Delete turns the shortcut off.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey
    @ViewState private var recording = false
    @ViewState private var monitor: Any?
    @ViewState private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut…" : (hotKey.enabled ? hotKey.display : "Off"))
                    .font(.system(size: 13, design: .rounded)).frame(minWidth: 100)
            }
            .help("Click, then press a shortcut with ⌃, ⌥ or ⌘. Esc cancels, Delete turns it off.")
            if let hint { Text(hint).font(.caption).foregroundStyle(Palette.orange) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated {
                if code == UInt32(kVK_Escape) { stop(); return }
                if code == UInt32(kVK_Delete) || code == UInt32(kVK_ForwardDelete) {
                    hotKey.enabled = false
                    stop()
                    return
                }
                var mods: UInt32 = 0
                if flags.contains(.control) { mods |= HotKey.controlKey }
                if flags.contains(.option) { mods |= HotKey.optionKey }
                if flags.contains(.shift) { mods |= HotKey.shiftKey }
                if flags.contains(.command) { mods |= HotKey.cmdKey }
                let k = HotKey(enabled: true, keyCode: code, carbonModifiers: mods)
                if k.isValid {
                    hotKey = k
                    stop()
                } else {
                    hint = "Add ⌃, ⌥ or ⌘"
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

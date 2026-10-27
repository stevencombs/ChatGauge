import AppKit
import ChatGaugeCore

/// Developer self-test (scripts/ui-selftest.sh): runs only when CHATGAUGE_UI_SELFTEST names an output folder.
/// Opens the real popover, sends one prompt to the server in settings (a mock in the script), and records what the
/// live view shows (accessibility text + a PNG) while the reply is pending and after it finishes. Then quits.
@MainActor
enum UISelfTest {
    static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["CHATGAUGE_UI_SELFTEST"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(out: URL, open: @escaping () -> Void, view: @escaping () -> NSView?, engine: ChatEngine,
                    extra: (@MainActor (URL) async -> String)? = nil) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            var log = ""
            let snap: @MainActor (String) -> Void = { name in
                log += snapshot(name, view: view(), engine: engine, out: out)
            }
            await wait(1.5)
            open()
            await wait(3)
            snap("1-open")
            engine.draft = "Are you working"
            engine.send()
            await wait(0.6)
            snap("2-pending")
            await wait(4)
            snap("3-after")
            await wait(2)
            snap("4-later")
            if let extra { log += await extra(out) }
            try? log.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    static func snapshot(_ name: String, view: NSView?, engine: ChatEngine, out: URL) -> String {
        let texts = view.map { collect($0) } ?? []
        var log = "== \(name): status=\(engine.status.title) streaming=\(engine.isStreaming) awaiting=\(engine.awaitingFirstToken)\n"
        for m in engine.conversation.messages { log += "   model \(m.role): \(m.text.prefix(60).debugDescription)\n" }
        log += "   view: \(texts.joined(separator: " | "))\n"
        if let v = view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
        }
        return log
    }

    /// Visible text in the live accessibility tree, in order.
    static func collect(_ root: Any) -> [String] {
        var out: [String] = []
        func walk(_ e: Any, depth: Int) {
            guard depth < 40, let o = e as? NSObject else { return }
            if let el = o as? NSAccessibilityProtocol {
                let role = el.accessibilityRole()?.rawValue ?? ""
                for s in [el.accessibilityLabel(), el.accessibilityValue() as? String, el.accessibilityTitle()] {
                    if let s, !s.isEmpty { out.append("\(role.replacingOccurrences(of: "AX", with: "")):\(s)") }
                }
                if role == "AXProgressIndicator" || role == "AXBusyIndicator" { out.append("[\(role)]") }
                for c in (el.accessibilityChildren() ?? []) { walk(c, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return out
    }
}

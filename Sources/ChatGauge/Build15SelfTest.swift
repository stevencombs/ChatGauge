import AppKit
import ChatGaugeCore
import SwiftUI

extension AppDelegate {
    /// Build 15: model menu, Settings install/remove section, onboarding uncensored, Remove confirm dry-run.
    func selfTestBuild15(out: URL) async -> String {
        var log = "== build15 models\n"
        func check(_ ok: Bool, _ msg: String) { log += "   \(ok ? "PASS" : "FAIL") \(msg)\n" }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func until(_ secs: Double, _ pred: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(secs)
            while Date() < deadline {
                if pred() { return true }
                await wait(0.15)
            }
            return pred()
        }
        let dir = out.appendingPathComponent("build15", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shot(_ name: String, view: NSView?) {
            log += UISelfTest.snapshot(name, view: view, engine: engine, out: dir)
        }

        let rows = ModelCatalog.menuRows(installed: engine.models)
        check(rows.contains { $0.name == "qwen2.5vl:7b" && $0.isInstalled }, "menu lists installed 7b")
        check(rows.contains { !$0.isInstalled && $0.name.contains("abliterated") }, "menu lists uncensored Install… entries")
        check(ModelCatalog.description(for: ModelInfo(name: "custom-vl:1b", capabilities: ["vision"])) == "vision", "unknown vision → vision")

        engine.chooseForChat(.named("qwen2.5vl:7b"))
        check(engine.conversation.model == "qwen2.5vl:7b", "per-chat model set")
        check(engine.preferredModel == "qwen2.5vl:7b", "preferred follows chat model")
        engine.chooseForChat(.automatic)
        check(engine.conversation.model == nil, "automatic clears per-chat model")

        if !popoverIsShown { showPopover() }
        await wait(0.4)
        if let v = popoverViewForTest { shot("15-model-menu", view: v) }

        showSettings(tab: "model")
        await wait(0.6)
        if let v = settingsWindow?.nsWindow?.contentView { shot("15-settings-models", view: v) }

        let plan = engine.removalPlan(for: "qwen2.5vl:7b", chatCount: 1)
        check(plan.lines.contains { $0.contains("/api/delete") }, "remove plan lists DELETE /api/delete")
        check(plan.warning?.contains("1 saved chat") == true, "remove plan warns about chats")
        let host = NSHostingView(rootView: RemoveConfirmPreview(plan: plan))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 280)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Remove model"
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.orderFront(nil)
        await wait(0.4)
        shot("15-remove-confirm", view: host)
        win.orderOut(nil)
        win.contentView = nil

        showSetup()
        await wait(0.5)
        if let m = setupModel {
            m.runChecks()
            _ = await until(10) { m.checkedOnce && !m.checking }
            m.go(.models)
            await wait(0.4)
            if let v = setupWindow?.nsWindow?.contentView { shot("15-onboarding-models", view: v) }
            m.proposeUncensored(ModelCatalog.uncensored[0].name)
            check(m.pending?.lines.contains { $0.contains("/api/pull") && $0.contains("abliterated") } == true,
                  "uncensored Install shows dry-run pull")
            m.pending = nil
            m.chatPicks.remove(ModelCatalog.uncensored[0].name)
        }
        setupWindow?.close()
        await wait(0.2)
        settingsWindow?.close()
        return log
    }
}

/// Mirrors the Remove confirm dialog text for a screenshot (self-test only; never deletes).
private struct RemoveConfirmPreview: View {
    let plan: ModelRemoval.Plan
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(plan.model)?").font(.title2.weight(.semibold))
            Text("This frees about \(plan.freeLabel).").foregroundStyle(.secondary)
            Text("This will run:").font(.headline)
            ForEach(plan.lines, id: \.self) { line in
                Text(line).font(.system(.body, design: .monospaced))
            }
            if let w = plan.warning {
                Text(w).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Text("Cancel").padding(.horizontal, 12).padding(.vertical, 6)
                Text("Remove").padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

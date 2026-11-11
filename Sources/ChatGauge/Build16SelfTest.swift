import AppKit
import ChatGaugeCore
import SwiftUI

extension AppDelegate {
    /// Build 17: image models (uncensored option hidden), generate-image mode, mflux dry run, OT-79 / OT-100.
    func selfTestBuild17(out: URL) async -> String {
        var log = "== build17 image gen\n"
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
        let dir = out.appendingPathComponent("build17", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shot(_ name: String, view: NSView?) {
            log += UISelfTest.snapshot(name, view: view, engine: engine, out: dir)
        }

        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        engine.imageModelsFolderOverride = scratch.appendingPathComponent("mflux-models", isDirectory: true)
        engine.imagesFolderOverride = scratch.appendingPathComponent("ChatGauge Images", isDirectory: true)
        engine.imageDownloader = StubImageDownloader()
        engine.imageExecutor = StubImageExecutor()
        engine.mfluxPathOverride = "/tmp/fake-mflux-generate-flux2"
        engine.uncensoredLoadable = false
        engine.mfluxInstalled = true
        engine.refreshImageModels()

        check(!ImageCatalog.showUncensoredOption, "uncensored image option flag is off")
        check(!ImageCatalog.all.contains(where: { $0.uncensored }), "visible catalog hides the uncensored image option")
        let install = ImageCatalog.installPlan(ImageCatalog.klein4b, into: engine.imageModelsFolder)
        check(install.contains { $0.contains("flux2-klein-4b-mflux-q4") }, "Klein 4B dry run names the q4 repo")
        check(!install.contains { $0.lowercased().contains("uncensored") }, "Klein 4B dry run does not mention an uncensored option")
        let mflux = MfluxInstall.plan(brew: "/opt/homebrew/bin/brew", uv: nil)
        check(mflux.contains { $0.contains("install uv") }, "mflux dry run installs uv when missing")
        check(mflux.contains { $0.contains("tool install mflux") }, "mflux dry run is uv tool install mflux")

        engine.installImageModel(ImageCatalog.klein4b.id)
        check(await until(5) { engine.imageInstalled.contains(ImageCatalog.klein4b.id) }, "stub install records Klein 4B")
        engine.installImageModel(ImageCatalog.zImageTurbo.id)
        _ = await until(5) { engine.imageInstalled.contains(ImageCatalog.zImageTurbo.id) }
        engine.installImageModel(ImageCatalog.kleinUncensoredEncoder.id)
        check(!engine.imageInstalled.contains(ImageCatalog.kleinUncensoredEncoder.id), "hidden uncensored option cannot be installed from the app")

        let before = engine.imageInstalled
        let msg = engine.removeImageModel(ImageCatalog.zImageTurbo.id)
        check(msg?.contains("Freed") == true, "remove reports space freed")
        check(!engine.imageInstalled.contains(ImageCatalog.zImageTurbo.id), "Z-Image Turbo removed")
        check(before.contains(ImageCatalog.zImageTurbo.id), "was installed before remove")

        engine.composerMode = .image
        engine.imageModelID = ImageCatalog.klein4b.id
        engine.draft = "a red bicycle on a cobbled street"
        engine.generateImage()
        check(await until(5) { engine.conversation.messages.contains { $0.role == .assistant && !$0.images.isEmpty } }, "stub generate attaches an image")
        check(engine.imageMessage?.contains("Saved") == true, "generate reports a saved file")
        let genCmd = (engine.imageExecutor as? StubImageExecutor)?.lastCommand?.display ?? ""
        check(!genCmd.contains("ollama"), "generate does not call Ollama")

        var f = InstructionsFile.standard
        f.setStanding("Be brief for the 7b model.", for: "qwen2.5vl:7b")
        check(f.systemPrompt(for: "qwen2.5vl:7b")?.contains("Be brief for the 7b model.") == true, "OT-79 per-model prompt")
        check(f.systemPrompt(for: "qwen2.5vl:3b")?.hasPrefix("You are a helpful assistant") == true, "OT-79 default prompt")
        let plan = ClipGaugeImport.plan(existing: ["MEGA65"], imported: ["MEGA65", "retroCombs"], alreadyImported: false, sourcePath: "/tmp/custom-instructions.json")
        check(plan.canApply && plan.termsToAdd == ["retroCombs"], "OT-100 dry run lists new terms")
        check(plan.lines.contains { $0.contains("not changed") }, "OT-100 dry run is read-only")
        let blocked = ClipGaugeImport.plan(existing: [], imported: ["x"], alreadyImported: true, sourcePath: "/tmp/x")
        check(!blocked.canApply, "OT-100 import is one-time")

        showSettings(tab: "model")
        await wait(0.6)
        if let v = settingsWindow?.nsWindow?.contentView { shot("17-settings-image-models", view: v) }

        let host = NSHostingView(rootView: ImageInstallPreview(entry: ImageCatalog.klein4b, folder: engine.imageModelsFolder))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Install image model"
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.orderFront(nil)
        await wait(0.4)
        shot("17-image-install-dry-run", view: host)
        win.orderOut(nil)
        win.contentView = nil

        let rem = ImageRemoval.plan(ImageCatalog.klein4b, folder: engine.imageModelsFolder)
        let remHost = NSHostingView(rootView: ImageRemovePreview(plan: rem))
        remHost.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        let remWin = NSWindow(contentRect: remHost.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        remWin.title = "Remove image model"
        remWin.isReleasedWhenClosed = false
        remWin.contentView = remHost
        remWin.orderFront(nil)
        await wait(0.4)
        shot("17-image-remove-confirm", view: remHost)
        remWin.orderOut(nil)
        remWin.contentView = nil

        showSettings(tab: "instructions")
        await wait(0.5)
        if let v = settingsWindow?.nsWindow?.contentView { shot("17-settings-instructions", view: v) }

        showChatWindow()
        await wait(0.6)
        if let v = chatWindow?.nsWindow?.contentView { shot("17-generate-image-mode", view: v) }

        showSetup()
        await wait(0.5)
        if let m = setupModel {
            m.runChecks()
            _ = await until(10) { m.checkedOnce && !m.checking }
            m.go(.tools)
            await wait(0.4)
            if let v = setupWindow?.nsWindow?.contentView { shot("17-onboarding-mflux", view: v) }
            m.proposeMflux()
            check(m.pending?.lines.contains { $0.contains("tool install mflux") } == true, "onboarding mflux is click + dry run")
            m.pending = nil
            m.go(.models)
            await wait(0.4)
            if let v = setupWindow?.nsWindow?.contentView { shot("17-onboarding-image-models", view: v) }
            m.proposeImageModel(ImageCatalog.klein4b.id)
            check(m.pending?.lines.contains { $0.contains("flux2-klein-4b-mflux-q4") } == true, "onboarding image install is a dry run")
            m.pending = nil
        }
        setupWindow?.close()
        await wait(0.2)
        settingsWindow?.close()
        engine.composerMode = .chat
        engine.imageModelsFolderOverride = nil
        engine.imagesFolderOverride = nil
        engine.mfluxPathOverride = nil
        return log
    }
}

private struct ImageInstallPreview: View {
    let entry: ImageModelEntry
    let folder: URL
    var body: some View {
        let lines = ImageCatalog.installPlan(entry, into: folder)
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(entry.title)?").font(.title2.weight(.semibold))
            Text("About \(entry.sizeLabel). Nothing downloads until you click Install.").foregroundStyle(.secondary)
            Text("This will run:").font(.headline)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(.body, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Text("Cancel").padding(.horizontal, 12).padding(.vertical, 6)
                Text("Install").padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ImageRemovePreview: View {
    let plan: ImageRemoval.Plan
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(plan.title)?").font(.title2.weight(.semibold))
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

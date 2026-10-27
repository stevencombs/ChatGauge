import AppKit
import ChatGaugeCore

/// The setup guide's part of scripts/ui-selftest.sh: fake brew/ollama from CHATGAUGE_SETUP_BIN, the mock server,
/// a throwaway home. Every step is clicked through its dry run; nothing real is installed, pulled or loaded.
extension AppDelegate {
    func selfTestSetup(out: URL) async -> String {
        var log = "\n== setup guide\n"
        func check(_ ok: Bool, _ name: String) { log += "\(ok ? "PASS" : "FAIL") setup: \(name)\n" }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func until(_ limit: Double, _ cond: () -> Bool) async -> Bool {
            var t = 0.0
            while !cond() && t < limit { await wait(0.1); t += 0.1 }
            return cond()
        }
        let dir = out.appendingPathComponent("onboarding", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shot(_ name: String) {
            guard let v = setupWindow?.nsWindow?.contentView else { log += "INFO no window for \(name)\n"; return }
            v.layoutSubtreeIfNeeded()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        func runPending(_ m: SetupModel) {
            let p = m.pending
            m.pending = nil
            p?.run()
        }

        check(!setupShouldAutoShow(), "existing settings → guide doesn't open by itself")
        check(setupWindow == nil, "guide not opened at launch")
        showSetup()
        await wait(1.2)
        guard let m = setupModel else { check(false, "guide opens"); return log }
        check(setupWindow?.isVisible == true, "Run Setup opens the guide")
        shot("onboarding-1-welcome")

        // 2. Check
        m.goNext()
        check(m.step == .check, "Get Started → Check")
        _ = await until(20) { m.checkedOnce && !m.checking }
        check(m.brew.path != nil && m.brew.version == "4.6.9", "fake Homebrew found with version (\(m.brew.version ?? "-"))")
        check(m.tools[.ollama]?.path == nil, "Ollama not installed yet")
        if case .running(let v, _, _) = m.existing { check(v == "0.40.11", "existing server detected (Ollama \(v ?? "-"))") }
        else { check(false, "existing server detected") }
        check(!m.volumes.isEmpty && m.volumes.contains { $0.path == "/" }, "volumes listed (\(m.volumes.count))")
        await wait(0.3)
        shot("onboarding-2-check")

        // 3. Location: a new folder, created only after the dry run is confirmed.
        m.goNext()
        let folder = m.home.appendingPathComponent("models-new").path
        m.setFolder(folder)
        m.proposeUseFolder()
        check(m.pending?.lines.first == "mkdir -p \(SetupPlan.quote(folder))", "create folder shows its dry run")
        check(!FileManager.default.fileExists(atPath: folder), "nothing created before Run")
        await wait(0.3)
        shot("onboarding-3-location")
        runPending(m)
        check(m.folderExists && m.progress.locationReady, "folder created and ready")

        // 4. Tools via fake brew, each with its own dry run + click.
        m.go(.tools)
        m.whisperPick = m.recommendation.whisper.name
        for t in SetupTool.allCases {
            m.proposeInstall(t)
            check(m.pending?.lines.first?.hasSuffix("install \(t.formula)") == true, "\(t.formula): dry run first")
            runPending(m)
            _ = await until(15) { m.installing == nil && !m.checking && m.tools[t]?.path != nil }
        }
        check(SetupTool.allCases.allSatisfy { m.tools[$0]?.path != nil }, "fake brew installs ollama, whisper-cpp, ffmpeg")
        check(m.tools[.ollama]?.version == "0.40.11", "Ollama version read (\(m.tools[.ollama]?.version ?? "-"))")
        check(m.log.contains("Pouring ffmpeg") && m.log.contains("✓ ffmpeg installed"), "live brew output shown")
        await wait(0.4)
        shot("onboarding-4-tools")

        // 5. Models: temporary server on 11435 with OLLAMA_MODELS = the folder; pause, resume; whisper + checksum.
        m.go(.models)
        let pick = m.recommendation.defaultChat
        m.chatPicks = [pick]
        m.proposeDownloads()
        let plan = m.pending?.lines ?? []
        check(plan.first?.contains("OLLAMA_HOST=127.0.0.1:11435 OLLAMA_MODELS=") == true, "download plan starts a temporary server on the folder")
        check(plan.contains { $0.contains("/api/pull") } && plan.contains { $0.contains("ggml-\(m.whisperPick ?? "")") }, "plan lists the pull and the whisper file")
        await wait(0.3)
        shot("onboarding-5-models-plan")
        runPending(m)
        _ = await until(10) { (m.pulls[pick]?.fraction ?? 0) > 0.1 }
        check(m.tempServerRunning, "temporary download server running")
        m.pauseDownloads()
        _ = await until(5) { if case .paused = m.pulls[pick] { return !m.downloading } else { return false } }
        if case .paused = m.pulls[pick] { check(true, "pause") } else { check(false, "pause (\(String(describing: m.pulls[pick])))") }
        await wait(0.3)
        shot("onboarding-5-models-paused")
        m.resumeDownloads()
        _ = await until(40) { (!m.downloading && !m.paused && m.pullsSettled) }
        check(m.installedChat.contains(pick), "\(pick) pulled into the chosen folder")
        let w = m.whisperPick ?? ""
        check(m.installedWhisper.contains(w), "whisper \(w) downloaded")
        if case .done(let s) = m.whisperJob { check(s.contains("verified"), "whisper SHA-256 verified") } else { check(false, "whisper SHA-256 verified (\(m.whisperJob))") }
        check(!m.tempServerRunning, "temporary server stopped")
        await wait(0.3)
        shot("onboarding-5-models")

        // 6. Server: show (never run) the own-agent plan, then use the existing one.
        m.go(.server)
        m.proposeOwnAgent()
        check(m.pending == nil, "own server not offered while another server runs")
        let realServer = m.existing
        m.selfTestSetServer(.none)   // pretend no server, only to show the plan
        m.proposeOwnAgent()
        check(m.pending?.lines.contains { $0.contains("launchctl bootstrap gui/") } == true, "own server: dry run lists launchctl bootstrap")
        await wait(0.3)
        shot("onboarding-6-server-plan")
        runPending(m)
        check(!FileManager.default.fileExists(atPath: OwnOllamaAgent.plistPath(home: m.home)), "self-test never writes a LaunchAgent")
        m.selfTestSetServer(realServer)
        m.useExisting()
        await wait(0.3)
        shot("onboarding-6-server")

        // 7. Test
        m.go(.test)
        m.sayOK()
        _ = await until(15) { !m.testJob.isRunning }
        check(m.testJob == .done("OK"), "Say OK → OK")
        await wait(0.3)
        shot("onboarding-7-test")

        // 8. Done
        m.go(.done)
        m.finish()
        let s = settingsStore.settings
        check(s.setupCompletedAt != nil, "setupCompletedAt saved")
        check(s.modelsPath == folder, "models folder saved")
        check(s.whisperModel == w, "whisper model saved")
        await wait(0.4)
        shot("onboarding-8-done")
        setupWindow?.close()
        await wait(0.3)
        check(setupWindow == nil && !setupShouldAutoShow(), "closed; won't auto-show again")
        return log
    }
}

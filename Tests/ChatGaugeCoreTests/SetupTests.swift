import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct SetupRecommendationTests {
    @Test func under32() {
        let r8 = SetupRecommendation.forRAM(gb: 8)
        #expect(r8.band == .under32)
        #expect(r8.defaultChat == "qwen2.5vl:3b")
        #expect(r8.chat.map(\.name) == ["qwen2.5vl:3b", "qwen2.5vl:7b"])
        #expect(r8.whisper.name == "base.en")
        let r24 = SetupRecommendation.forRAM(gb: 24)
        #expect(r24.defaultChat == "qwen2.5vl:7b")
        #expect(r24.chat.map(\.name).contains("qwen2.5vl:3b"))
        #expect(r24.whisper.name == "base.en")
        #expect(SetupRecommendation.forRAM(gb: 31.9).band == .under32)
    }

    @Test func from32to47() {
        for gb in [32.0, 36, 47.9] {
            let r = SetupRecommendation.forRAM(gb: gb)
            #expect(r.band == .from32to47)
            #expect(r.defaultChat == "qwen2.5vl:7b")
            #expect(r.optionalChat.isEmpty)
            #expect(r.whisper.name == "large-v3-turbo")
        }
    }

    @Test func atLeast48() {
        let r = SetupRecommendation.forRAM(bytes: 64 * 1_073_741_824)
        #expect(r.band == .atLeast48)
        #expect(r.defaultChat == "qwen2.5vl:7b")
        #expect(r.optionalChat == ["qwen2.5vl:32b"])
        #expect(r.chat.map(\.name) == ["qwen2.5vl:7b", "qwen2.5vl:32b"])
        #expect(r.whisper.name == "large-v3-turbo")
        #expect(SetupRecommendation.forRAM(gb: 48).band == .atLeast48)
    }

    @Test func sizes() {
        let need = SetupRecommendation.neededBytes(chat: ["qwen2.5vl:7b"], whisper: "large-v3-turbo")
        #expect(need == (6_000_000_000 + 1_625_000_000) * 11 / 10)
        #expect(SetupRecommendation.neededBytes(chat: [], whisper: nil) == 0)
        #expect(SetupRecommendation.neededBytes(chat: ["nope"], whisper: "nope") == 0)
    }
}

@Suite struct VolumeCheckTests {
    let apfs = VolumeInfo(path: "/", name: "Macintosh HD", format: "APFS", availableBytes: 200_000_000_000, isInternal: true)
    let exfat = VolumeInfo(path: "/Volumes/Lexar", name: "Lexar", format: "ExFAT", availableBytes: 900_000_000_000, isInternal: false)

    @Test func goodInternal() {
        let i = VolumeCheck.evaluate(apfs, needBytes: 10_000_000_000, writable: true)
        #expect(i.isEmpty)
        #expect(VolumeCheck.canUse(i))
    }

    @Test func exfatWarnsButAllows() {
        let i = VolumeCheck.evaluate(exfat, needBytes: 10_000_000_000, writable: true)
        #expect(i == [.fatFormat("ExFAT")])
        #expect(VolumeCheck.canUse(i))
        #expect(i[0].message.contains("._"))
        #expect(i[0].message.contains("OLLAMA_MODELS"))
        #expect(VolumeCheck.isFATFamily("MS-DOS (FAT32)"))
        #expect(!VolumeCheck.isFATFamily("APFS"))
        #expect(!VolumeCheck.isFATFamily("Mac OS Extended (Journaled)"))
    }

    @Test func blocking() {
        var small = apfs
        small.availableBytes = 5_000_000_000
        #expect(VolumeCheck.evaluate(small, needBytes: 7_000_000_000, writable: true) == [.notEnoughSpace(need: 7_000_000_000, have: 5_000_000_000)])
        #expect(!VolumeCheck.canUse(VolumeCheck.evaluate(small, needBytes: 7_000_000_000, writable: true)))
        #expect(!VolumeCheck.canUse(VolumeCheck.evaluate(apfs, needBytes: 1, writable: false)))
        var ro = exfat
        ro.isReadOnly = true
        #expect(VolumeCheck.evaluate(ro, needBytes: 1, writable: nil).first == .readOnly)
        #expect(!VolumeCheck.canUse(VolumeCheck.evaluate(apfs, needBytes: 1, writable: true, isFile: true)))
    }

    @Test func unknownSpaceIsAWarning() {
        var z = exfat
        z.availableBytes = 0
        let i = VolumeCheck.evaluate(z, needBytes: 1, writable: true)
        #expect(i.contains(.unknownSpace))
        #expect(VolumeCheck.canUse(i))
    }

    @Test func suggestedFoldersAndLookup() {
        let home = URL(fileURLWithPath: "/Users/u")
        #expect(VolumeCheck.suggestedFolder(on: apfs, home: home) == "/Users/u/.ollama/models")
        #expect(VolumeCheck.suggestedFolder(on: exfat, home: home) == "/Volumes/Lexar/ChatGauge/models")
        let vols = [apfs, exfat]
        #expect(VolumeCheck.volume(for: "/Volumes/Lexar/x/models", in: vols)?.name == "Lexar")
        #expect(VolumeCheck.volume(for: "/Users/u/.ollama/models", in: vols)?.name == "Macintosh HD")
        #expect(VolumeCheck.volume(for: "/Volumes/LexarTwo/m", in: vols)?.name == "Macintosh HD")
    }
}

@Suite struct SetupFlowTests {
    @Test func skipsSatisfiedSteps() {
        let p = SetupProgress(locationReady: true, toolsReady: true, modelsReady: false, serverReady: true)
        #expect(SetupFlow.next(after: .welcome, p) == .check)
        #expect(SetupFlow.next(after: .check, p) == .models)
        #expect(SetupFlow.next(after: .models, p) == .test)
        #expect(SetupFlow.previous(before: .test, p) == .models)
        #expect(SetupFlow.previous(before: .models, p) == .check)
    }

    @Test func allDoneGoesStraightToTest() {
        let p = SetupProgress(locationReady: true, toolsReady: true, modelsReady: true, serverReady: true)
        #expect(SetupFlow.next(after: .check, p) == .test)
        #expect(SetupFlow.next(after: .test, p) == .done)
        #expect(SetupFlow.next(after: .done, p) == .done)
    }

    @Test func nothingDoneShowsEverything() {
        let p = SetupProgress()
        var s = SetupStep.welcome, seen: [SetupStep] = [s]
        while s != .done { s = SetupFlow.next(after: s, p); seen.append(s) }
        #expect(seen == SetupStep.allCases)
        #expect(!SetupStep.welcome.skippable && !SetupStep.test.skippable && SetupStep.models.skippable)
    }
}

@Suite struct ExistingServerTests {
    let lexar = OllamaAgent(label: OllamaAgent.sharedLabel, plistPath: "/Users/u/Library/LaunchAgents/com.retrocombs.ollama-lexar.plist",
                            modelsPath: "/Volumes/Lexar/ClipGauge/models", runsOllama: true)
    let home = URL(fileURLWithPath: "/Users/u")

    @Test func runningSharedAgent() {
        let e = ServerDetection.describe(answering: true, version: "0.12.6", agents: [lexar], loadedLabels: [lexar.label], processModels: nil)
        #expect(e == .running(version: "0.12.6", modelsPath: "/Volumes/Lexar/ClipGauge/models", managedBy: OllamaAgent.sharedLabel))
        #expect(!e.offersOwnAgent)
        #expect(e.serves("/Volumes/Lexar/ClipGauge/models/", home: home) == true)
        #expect(e.serves("/Users/u/.ollama/models", home: home) == false)
    }

    @Test func agentWithDriveUnplugged() {
        let e = ServerDetection.describe(answering: false, version: nil, agents: [lexar], loadedLabels: [lexar.label], processModels: nil)
        #expect(e == .agentNotRunning(label: OllamaAgent.sharedLabel, modelsPath: "/Volumes/Lexar/ClipGauge/models"))
        #expect(!e.offersOwnAgent)
        #expect(e.isPresent)
    }

    @Test func plainServerAndNothing() {
        let app = ServerDetection.describe(answering: true, version: "0.12.6", agents: [], loadedLabels: [], processModels: nil)
        #expect(app == .running(version: "0.12.6", modelsPath: nil, managedBy: nil))
        #expect(app.serves("/Users/u/.ollama/models", home: home) == true)
        #expect(app.serves("/Volumes/X/models", home: home) == nil)
        let fromPs = ServerDetection.describe(answering: true, version: nil, agents: [], loadedLabels: [], processModels: "/Volumes/X/models")
        #expect(fromPs.serves("/Volumes/X/models", home: home) == true)
        let none = ServerDetection.describe(answering: false, version: nil, agents: [], loadedLabels: [], processModels: nil)
        #expect(none == .none)
        #expect(none.offersOwnAgent)
    }

    @Test func modelsFromPs() {
        #expect(ServerDetection.modelsFromProcess("/opt/homebrew/bin/ollama serve HOME=/Users/u OLLAMA_MODELS=/Volumes/My Drive/models PATH=/usr/bin") == "/Volumes/My Drive/models")
        #expect(ServerDetection.modelsFromProcess("/opt/homebrew/bin/ollama serve OLLAMA_MODELS=/x/m") == "/x/m")
        #expect(ServerDetection.modelsFromProcess("/opt/homebrew/bin/ollama serve HOME=/Users/u") == nil)
    }
}

@Suite struct SetupGateTests {
    let lexar = OllamaAgent(label: OllamaAgent.sharedLabel, plistPath: "/p", modelsPath: "/Volumes/Lexar/ClipGauge/models", runsOllama: true)

    /// Steven's MacBook Pro: settings from earlier builds, the shared Lexar agent and qwen2.5vl:7b installed.
    @Test func existingProSetupDoesNotAutoShow() {
        let pro = SetupSnapshot(settingsFileExisted: true, setupCompletedAt: nil, agents: [lexar], modelsOnDisk: 1, ollamaInstalled: true)
        #expect(SetupGate.existingSetupLooksComplete(pro))
        #expect(!SetupGate.shouldAutoShow(pro))
        // Even with the drive unplugged (no models visible) or the settings file gone, the agent says it's set up.
        var unplugged = pro
        unplugged.modelsOnDisk = 0
        #expect(!SetupGate.shouldAutoShow(unplugged))
        var noSettings = unplugged
        noSettings.settingsFileExisted = false
        #expect(!SetupGate.shouldAutoShow(noSettings))
    }

    @Test func freshMacAutoShows() {
        let fresh = SetupSnapshot(settingsFileExisted: false, setupCompletedAt: nil, agents: [], modelsOnDisk: 0, ollamaInstalled: false)
        #expect(SetupGate.shouldAutoShow(fresh))
        var ollamaNoModels = fresh
        ollamaNoModels.ollamaInstalled = true
        #expect(SetupGate.shouldAutoShow(ollamaNoModels))
        var ollamaWithModels = ollamaNoModels
        ollamaWithModels.modelsOnDisk = 2
        #expect(!SetupGate.shouldAutoShow(ollamaWithModels))
        var done = fresh
        done.setupCompletedAt = Date()
        #expect(!SetupGate.shouldAutoShow(done))
    }

    @Test func setupCompletedRoundTrips() throws {
        var s = ChatSettings()
        #expect(s.setupCompletedAt == nil)
        s.setupCompletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let back = try SettingsFile.decode(SettingsFile.encode(s))
        #expect(back.setupCompletedAt == s.setupCompletedAt)
        // Old files without the key still load.
        let old = try SettingsFile.decode(Data(#"{"app":"ChatGauge","schema":1,"settings":{"model":"automatic"}}"#.utf8))
        #expect(old.setupCompletedAt == nil)
    }
}

@Suite struct SetupPlanTests {
    @Test func toolVersions() {
        #expect(ToolVersionParser.brew("Homebrew 4.6.3\n") == "4.6.3")
        #expect(ToolVersionParser.ollama("ollama version is 0.12.6") == "0.12.6")
        #expect(ToolVersionParser.ollama("Warning: could not connect to a running Ollama instance\nWarning: client version is 0.12.6") == "0.12.6")
        #expect(ToolVersionParser.ffmpeg("ffmpeg version 7.1.1 Copyright (c) 2000-2025") == "7.1.1")
        #expect(ToolVersionParser.brewList("ffmpeg 7.1_3 7.1.1_1\nollama 0.12.6\nwhisper-cpp 1.7.6\n")
                == ["ffmpeg": "7.1.1_1", "ollama": "0.12.6", "whisper-cpp": "1.7.6"])
        #expect(SetupTool.whisper.formula == "whisper-cpp")
        #expect(SetupTool.whisper.executable == "whisper-cli")
    }

    @Test func dryRunLines() {
        #expect(SetupPlan.brewInstall(brew: "/opt/homebrew/bin/brew", tool: .ollama) == ["/opt/homebrew/bin/brew install ollama"])
        #expect(SetupPlan.createFolder("/Volumes/My Drive/m") == ["mkdir -p '/Volumes/My Drive/m'"])
        let temp = SetupPlan.pull(models: ["qwen2.5vl:7b"], ollama: "/opt/homebrew/bin/ollama", folder: "/Volumes/X/models", viaExisting: nil)
        #expect(temp.count == 2)
        #expect(temp[0].hasPrefix("OLLAMA_HOST=127.0.0.1:11435 OLLAMA_MODELS=/Volumes/X/models /opt/homebrew/bin/ollama serve"))
        #expect(temp[1] == #"POST http://127.0.0.1:11435/api/pull {"model":"qwen2.5vl:7b"}"#)
        let existing = SetupPlan.pull(models: ["a", "b"], ollama: "o", folder: "f", viaExisting: "http://127.0.0.1:11434")
        #expect(existing == [#"POST http://127.0.0.1:11434/api/pull {"model":"a"}"#, #"POST http://127.0.0.1:11434/api/pull {"model":"b"}"#])
        #expect(SetupPlan.agentInstall(plistPath: "/p.plist", uid: 501) == ["write /p.plist", "launchctl bootstrap gui/501 /p.plist"])
        #expect(SetupPlan.agentRemove(plistPath: "/p.plist", uid: 501) == ["launchctl bootout gui/501/com.chatgauge.ollama", "rm /p.plist"])
        #expect(SetupPlan.quote("it's") == #"'it'\''s'"#)
    }

    @Test func ownAgentPlist() throws {
        let ext = try OwnOllamaAgent.plistData(ollama: "/opt/homebrew/bin/ollama", modelsPath: "/Volumes/T7 Shield/ChatGauge/models", logPath: "/l.log")
        let a = try #require(OllamaAgent.parse(plist: ext, path: "/p"))
        #expect(a.label == "com.chatgauge.ollama")
        #expect(a.runsOllama)
        #expect(a.modelsPath == "/Volumes/T7 Shield/ChatGauge/models")
        let o = try #require(try PropertyListSerialization.propertyList(from: ext, format: nil) as? [String: Any])
        let args = try #require(o["ProgramArguments"] as? [String])
        #expect(args[2] == "while [ ! -d '/Volumes/T7 Shield/ChatGauge/models' ]; do sleep 10; done; exec /opt/homebrew/bin/ollama serve")
        #expect((o["EnvironmentVariables"] as? [String: String])?["OLLAMA_HOST"] == "127.0.0.1:11434")
        #expect(OwnOllamaAgent.script(ollama: "/o", modelsPath: "/Users/u/.ollama/models") == "exec /o serve")
        #expect(OwnOllamaAgent.mayRemove(label: "com.chatgauge.ollama"))
        #expect(!OwnOllamaAgent.mayRemove(label: OllamaAgent.sharedLabel))
        #expect(OwnOllamaAgent.plistPath(home: URL(fileURLWithPath: "/Users/u")) == "/Users/u/Library/LaunchAgents/com.chatgauge.ollama.plist")
    }

    @Test func checksum() throws {
        let h = String(repeating: "aB", count: 32)
        #expect(WhisperChecksum.sha256(fromLinkedEtag: "\"\(h)\"") == h.lowercased())
        #expect(WhisperChecksum.sha256(fromLinkedEtag: "W/\"\(h)\"") == h.lowercased())
        #expect(WhisperChecksum.sha256(fromLinkedEtag: "\"abc123\"") == nil)
        #expect(WhisperChecksum.sha256(fromLinkedEtag: nil) == nil)
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("cg-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(try WhisperChecksum.sha256(of: f) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func manifestsOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cg-man-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manifests/registry.ollama.ai/library/qwen2.5vl"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("manifests/registry.ollama.ai/library/qwen2.5vl/7b"))
        try Data().write(to: root.appendingPathComponent("manifests/registry.ollama.ai/library/qwen2.5vl/._7b"))
        try fm.createDirectory(at: root.appendingPathComponent("manifests-v2/ollama.com/library/llama3.2"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("manifests-v2/ollama.com/library/llama3.2/3b"))
        #expect(ModelManifests.installed(in: root) == ["llama3.2:3b", "qwen2.5vl:7b"])
        #expect(ModelManifests.installed(in: root.appendingPathComponent("none")).isEmpty)
    }
}

import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct SettingsTests {
    @Test func defaults() {
        let s = ChatSettings()
        #expect(s.modelsLocation == .local && s.modelsPath == nil)
        #expect(s.model == .automatic)
        #expect(s.hotKey == .standard && s.hotKey.display == "⌃⌥C")
        #expect(s.updateMode == .notify && s.checkForUpdates)
        #expect(s.chatFormat == .markdown)
        #expect(s.keepsLoaded(tier: .pro) && !s.keepsLoaded(tier: .air))
    }

    @Test func roundTripAndEnvelope() throws {
        var s = ChatSettings()
        s.modelsLocation = .external
        s.modelsPath = "/Volumes/Drive/LLM/models"
        s.model = .named("qwen2.5vl:32b")
        s.updateMode = .autoWhenIdle
        s.modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try SettingsFile.encode(s)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"app\" : \"ChatGauge\""))
        #expect(try SettingsFile.decode(data) == s)
    }

    @Test func tolerantDecode() throws {
        let json = #"{"app":"ChatGauge","schema":1,"settings":{"chatFormat":"json","bogus":3}}"#
        let s = try SettingsFile.decode(Data(json.utf8))
        #expect(s.chatFormat == .json && s.hotKey == .standard)
    }

    @Test func rejectsOtherApps() {
        let json = #"{"app":"GrokGauge","schema":1,"settings":{}}"#
        #expect(throws: SettingsFileError.notChatGauge("GrokGauge")) { try SettingsFile.decode(Data(json.utf8)) }
        let newer = #"{"app":"ChatGauge","schema":99,"settings":{}}"#
        #expect(throws: SettingsFileError.newerSchema(99)) { try SettingsFile.decode(Data(newer.utf8)) }
    }

    @Test func loadSaveKeepsBadFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        var s = ChatSettings()
        s.saveChats = false
        try SettingsFile.save(s, to: url)
        #expect(SettingsFile.load(from: url).sameContent(as: s))
        try Data("not json".utf8).write(to: url)
        #expect(SettingsFile.load(from: url).sameContent(as: ChatSettings()))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.bad.json").path))
    }

    @Test func modelChoiceCoding() throws {
        let d = try JSONEncoder().encode(ModelChoice.named("gemma3:12b"))
        #expect(try JSONDecoder().decode(ModelChoice.self, from: d) == .named("gemma3:12b"))
        #expect(try JSONDecoder().decode(ModelChoice.self, from: Data(#"{"mode":"named"}"#.utf8)) == .automatic)
    }
}

@Suite struct TierTests {
    let gb: UInt64 = 1_073_741_824
    @Test func thresholds() {
        let r = TierRules.standard
        #expect(r.tier(memBytes: 16 * gb) == .air)
        #expect(r.tier(memBytes: 24 * gb) == .air)
        #expect(r.tier(memBytes: 36 * gb) == .air)   // between 32 and 48 uses the Air rules
        #expect(r.tier(memBytes: 48 * gb) == .pro)
        #expect(r.tier(memBytes: 64 * gb) == .pro)
        #expect(TierDetector.detect(override: "PRO", memBytes: 8 * gb) == .pro)
    }

    @Test func parsesRamTiersJSON() {
        let json = """
        {"tiers":{"air":{"prefer":"qwen2.5vl:7b","whisper_model":"base.en","whisper_alternates":["small.en"]},
                  "pro":{"prefer":"qwen2.5vl:32b","whisper_model":"large-v3-turbo"}},
         "detection":{"air_if_gb_lt":30,"pro_if_gb_gte":40}}
        """
        let r = TierRules.parse(Data(json.utf8))
        #expect(r.proAtLeastGB == 40 && r.airBelowGB == 30)
        #expect(r.preferred[.pro] == "qwen2.5vl:32b")
        #expect(r.whisper[.air] == ["base.en", "small.en"])
        #expect(r.tier(memBytes: 40 * gb) == .pro)
    }
}

@Suite struct LocationTests {
    @Test func externalDriveStates() {
        var s = ChatSettings()
        s.modelsLocation = .external
        s.modelsPath = "/Volumes/Lexar/Local-LLM/models"
        let loc = ModelsLocation.from(s)
        #expect(loc.volumeRoot == "/Volumes/Lexar" && loc.volumeName == "Lexar")
        #expect(loc.availability { _ in false } == .driveMissing(volume: "Lexar"))
        #expect(loc.availability { $0 == "/Volumes/Lexar" } == .folderMissing)
        #expect(loc.availability { _ in true } == .ready)
        #expect(loc.whisperFolder.path == "/Volumes/Lexar/Local-LLM/models/whisper")
        #expect(loc.clipGaugeInstructions.path == "/Volumes/Lexar/Local-LLM/config/custom-instructions.json")
    }

    @Test func localDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        let loc = ModelsLocation.from(ChatSettings(), home: home)
        #expect(loc.path == "/Users/test/.ollama/models" && loc.volumeRoot == nil)
        #expect(loc.availability { _ in false } == .ready)
        var s = ChatSettings()
        s.modelsLocation = .external
        #expect(ModelsLocation.from(s).availability() == .notChosen)
    }
}

@Suite struct ServerTests {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>Label</key><string>com.retrocombs.ollama-lexar</string>
    <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
    <string>while [ ! -d /Volumes/Lexar/Local-LLM/models/manifests-v2 ]; do sleep 15; done; exec /opt/homebrew/bin/ollama serve</string></array>
    <key>EnvironmentVariables</key><dict><key>OLLAMA_MODELS</key><string>/Volumes/Lexar/Local-LLM/models</string></dict>
    </dict></plist>
    """

    @Test func parsesAgent() throws {
        let a = try #require(OllamaAgent.parse(plist: Data(plist.utf8), path: "/x.plist"))
        #expect(a.label == OllamaAgent.sharedLabel && a.runsOllama)
        #expect(a.modelsPath == "/Volumes/Lexar/Local-LLM/models")
    }

    @Test func parsesInlineEnv() throws {
        let p = """
        <plist version="1.0"><dict><key>Label</key><string>x.ollama</string>
        <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
        <string>OLLAMA_MODELS="/Volumes/D/m" exec ollama serve</string></array></dict></plist>
        """
        #expect(OllamaAgent.parse(plist: Data(p.utf8), path: "")?.modelsPath == "/Volumes/D/m")
    }

    @Test func plans() throws {
        let a = try #require(OllamaAgent.parse(plist: Data(plist.utf8), path: "/LA/x.plist"))
        let path = "/Volumes/Lexar/Local-LLM/models"
        #expect(ServerPlan.decide(answering: true, availability: .ready, agents: [a], loadedLabels: [], modelsPath: path) == .useRunning)
        #expect(ServerPlan.decide(answering: false, availability: .driveMissing(volume: "Lexar"), agents: [a], loadedLabels: [], modelsPath: path) == .waitForDrive(volume: "Lexar"))
        let k = ServerPlan.decide(answering: false, availability: .ready, agents: [a], loadedLabels: [a.label], modelsPath: path)
        #expect(k == .kickstart(label: a.label))
        #expect(ServerPlan.decide(answering: false, availability: .ready, agents: [a], loadedLabels: [], modelsPath: path) == .bootstrap(label: a.label, plist: "/LA/x.plist"))
        #expect(ServerPlan.decide(answering: false, availability: .ready, agents: [], loadedLabels: [], modelsPath: path) == .offerOwnAgent)
    }

    @Test func neverKillsTheServer() {
        for action in [ServerAction.kickstart(label: "a"), .bootstrap(label: "a", plist: "/p"), .useRunning, .offerOwnAgent] {
            let args = ServerPlan.launchctlArguments(action, uid: 501) ?? []
            #expect(!args.contains("-k"))
        }
        #expect(ServerPlan.launchctlArguments(.kickstart(label: "a"), uid: 501) == ["kickstart", "gui/501/a"])
    }
}

@Suite struct OllamaParseTests {
    @Test func tags() throws {
        let json = """
        {"models":[
          {"name":"qwen2.5vl:7b","size":6000000000,"digest":"abc","details":{"family":"qwen25vl","parameter_size":"8.3B"},"capabilities":["completion","vision"]},
          {"name":"qwen2.5vl:7b","size":6000000000},
          {"name":"llamacpp:\(String(repeating: "a", count: 64))","size":1},
          {"name":"nomic-embed-text:latest","size":1},
          {"name":"bge:latest","capabilities":["embedding"]},
          {"name":"qwen2.5vl:32b","size":21000000000,"capabilities":["completion","vision"]},
          {"name":"gemma3:12b","size":8000000000,"details":{"parameter_size":"12.2B"}}
        ]}
        """
        let t = try #require(OllamaParse.tags(Data(json.utf8)))
        #expect(t.map(\.name) == ["gemma3:12b", "qwen2.5vl:32b", "qwen2.5vl:7b"])
        #expect(t[2].supportsVision && t[2].billions == 7 && t[2].base == "qwen2.5vl")
        #expect(t[0].billions == 12)
    }

    @Test func psAndVersion() {
        let ps = #"{"models":[{"name":"qwen2.5vl:7b","size":6500000000,"size_vram":6500000000}]}"#
        #expect(OllamaParse.ps(Data(ps.utf8)) == [LoadedModel(name: "qwen2.5vl:7b", size: 6_500_000_000, sizeVRAM: 6_500_000_000)])
        #expect(OllamaParse.version(Data(#"{"version":"0.40.11"}"#.utf8)) == "0.40.11")
    }

    @Test func chatBodyHasBase64Images() throws {
        let img = Data([0xFF, 0xD8, 0xFF, 0x00])
        let body = ChatRequest.body(model: "qwen2.5vl:7b", messages: [
            WireMessage(role: "system", content: "Be brief."),
            WireMessage(role: "user", content: "What is this?", images: [img]),
        ], keepAlive: -1)
        let o = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(o["model"] as? String == "qwen2.5vl:7b" && o["stream"] as? Bool == true)
        #expect((o["keep_alive"] as? NSNumber)?.intValue == -1)
        let msgs = try #require(o["messages"] as? [[String: Any]])
        #expect(msgs.count == 2 && msgs[0]["images"] == nil)
        #expect((msgs[1]["images"] as? [String]) == [img.base64EncodedString()])
    }

    @Test func ndjsonAcrossChunks() {
        var b = NDJSONBuffer()
        let a = b.append(Data(#"{"message":{"role":"assistant","content":"Hel"},"done":false}"#.utf8) + Data("\n{\"message\":{\"content\":\"lo".utf8))
        #expect(a.map(\.content) == ["Hel"])
        let c = b.append(Data("\"},\"done\":false}\n".utf8))
        #expect(c.map(\.content) == ["lo"])
        let d = b.append(Data(#"{"done":true,"done_reason":"stop","eval_count":20,"eval_duration":1000000000}"#.utf8))
        #expect(d.isEmpty)
        let e = b.finish()
        #expect(e.count == 1 && e[0].done && e[0].tokensPerSecond == 20)
    }

    @Test func errorLine() {
        var b = NDJSONBuffer()
        let a = b.append(Data("{\"error\":\"model 'x' not found, try pulling it first\"}\n".utf8))
        #expect(a.first?.error != nil)
        #expect(OllamaError.server(a.first!.error!).description.contains("isn't installed"))
    }

    @Test func loopbackOnly() {
        #expect(OllamaClient(baseURL: "http://127.0.0.1:11434") != nil)
        #expect(OllamaClient(baseURL: "http://localhost:11434") != nil)
        #expect(OllamaClient(baseURL: "http://192.168.1.5:11434") == nil)
        #expect(OllamaClient(baseURL: "https://example.com") == nil)
    }
}

@Suite struct MemoryTests {
    let installed = [
        ModelInfo(name: "qwen2.5vl:32b", size: 21_000_000_000),
        ModelInfo(name: "qwen2.5vl:7b", size: 6_000_000_000),
        ModelInfo(name: "gemma3:27b", size: 17_000_000_000),
        ModelInfo(name: "gemma3:12b", size: 8_000_000_000),
    ]

    @Test func preferredModel() {
        #expect(ModelSelection.preferred(choice: .automatic, tier: .pro, installed: installed) == "qwen2.5vl:7b")
        #expect(ModelSelection.preferred(choice: .named("gemma3:27b"), tier: .pro, installed: installed) == "gemma3:27b")
        #expect(ModelSelection.preferred(choice: .named("missing:1b"), tier: .air, installed: installed) == "qwen2.5vl:7b")
        #expect(ModelSelection.preferred(choice: .automatic, tier: .air, installed: [ModelInfo(name: "qwen2.5vl:3b")]) == "qwen2.5vl:3b")
        #expect(ModelSelection.preferred(choice: .automatic, tier: .air, installed: []) == nil)
    }

    @Test func chains() {
        #expect(ModelSelection.fallbackChain(for: "qwen2.5vl:32b", installed: installed) == ["qwen2.5vl:7b"])
        #expect(ModelSelection.fallbackChain(for: "qwen2.5vl:7b", installed: installed) == [])
        #expect(ModelSelection.fallbackChain(for: "gemma3:27b", installed: installed) == ["gemma3:12b", "qwen2.5vl:7b"])
        let with3b = installed + [ModelInfo(name: "qwen2.5vl:3b", size: 3_000_000_000)]
        #expect(ModelSelection.fallbackChain(for: "qwen2.5vl:32b", installed: with3b) == ["qwen2.5vl:7b", "qwen2.5vl:3b"])
    }

    @Test func switchesDownAndBackWithCooldown() {
        var f = MemoryFallback(cooldown: 180)
        let t0 = Date(timeIntervalSince1970: 1000)
        let sizes = ["qwen2.5vl:32b": Int64(21_000_000_000), "qwen2.5vl:7b": Int64(6_000_000_000)]
        let chain = ["qwen2.5vl:7b"]
        var d = f.decide(preferred: "qwen2.5vl:32b", chain: chain, pressure: .normal, available: 40_000_000_000,
                         sizes: sizes, loaded: [], enabled: true, now: t0)
        #expect(d.model == "qwen2.5vl:32b" && d.note == nil)
        d = f.decide(preferred: "qwen2.5vl:32b", chain: chain, pressure: .warning, available: 40_000_000_000,
                     sizes: sizes, loaded: ["qwen2.5vl:32b"], enabled: true, now: t0)
        #expect(d.model == "qwen2.5vl:7b" && d.note?.contains("instead of qwen2.5vl:32b") == true)
        // Memory is back, but the cooldown hasn't passed: stay on 7b.
        d = f.decide(preferred: "qwen2.5vl:32b", chain: chain, pressure: .normal, available: 40_000_000_000,
                     sizes: sizes, loaded: [], enabled: true, now: t0.addingTimeInterval(60))
        #expect(d.model == "qwen2.5vl:7b")
        d = f.decide(preferred: "qwen2.5vl:32b", chain: chain, pressure: .normal, available: 40_000_000_000,
                     sizes: sizes, loaded: [], enabled: true, now: t0.addingTimeInterval(200))
        #expect(d.model == "qwen2.5vl:32b" && d.note == nil && f.active == nil)
    }

    @Test func lowFreeRAMAlsoTriggers() {
        var f = MemoryFallback()
        let d = f.decide(preferred: "qwen2.5vl:32b", chain: ["qwen2.5vl:7b"], pressure: .normal, available: 10_000_000_000,
                         sizes: ["qwen2.5vl:32b": 21_000_000_000, "qwen2.5vl:7b": 6_000_000_000], loaded: [], enabled: true)
        #expect(d.model == "qwen2.5vl:7b")
    }

    @Test func nothingSmallerSaysSlow() {
        var f = MemoryFallback()
        let d = f.decide(preferred: "qwen2.5vl:7b", chain: [], pressure: .critical, available: 1, sizes: [:], loaded: [], enabled: true)
        #expect(d.model == "qwen2.5vl:7b" && d.slow && d.note?.contains("slow") == true)
        var off = MemoryFallback()
        let od = off.decide(preferred: "a", chain: ["b"], pressure: .critical, available: 0, sizes: [:], loaded: [], enabled: false)
        #expect(od.model == "a")
    }

    @Test func ledgerOnlyUnloadsOwnModels() {
        var l = LoadLedger()
        l.recordLoad("qwen2.5vl:7b", wasAlreadyLoaded: false)
        l.recordLoad("qwen2.5vl:32b", wasAlreadyLoaded: true)   // someone else loaded it
        #expect(l.toUnload(loadedNow: ["qwen2.5vl:32b", "qwen2.5vl:7b", "other:1b"]) == ["qwen2.5vl:7b"])
        l.recordUnload("qwen2.5vl:7b")
        #expect(l.toUnload(loadedNow: ["qwen2.5vl:7b"]).isEmpty)
    }

    @Test func resolveWarnsOncePerSession() {
        var r = ResolveWatch()
        do { let w = r.update(runningBundleIDs: ["com.apple.finder"], enabled: true); #expect(!w) }
        do { let w = r.update(runningBundleIDs: ["com.blackmagic-design.DaVinciResolve"], enabled: true); #expect(w) }
        do { let w = r.update(runningBundleIDs: ["com.blackmagic-design.DaVinciResolve"], enabled: true); #expect(!w) }
        do { let w = r.update(runningBundleIDs: [], enabled: true); #expect(!w) }
        do { let w = r.update(runningBundleIDs: ["com.blackmagic-design.DaVinciResolveLite"], enabled: true); #expect(w) }
        var off = ResolveWatch()
        do { let w = off.update(runningBundleIDs: ["com.blackmagic-design.DaVinciResolve"], enabled: false); #expect(!w) }
    }
}

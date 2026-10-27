import AVFoundation
import AppKit
import ChatGaugeCore
import SwiftUI

/// Where setup looks for tools. The self-test points it at a folder of fake `brew`/`ollama` scripts
/// (only when CHATGAUGE_UI_SELFTEST is set), so it never installs or downloads anything real.
enum SetupEnv {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var isTest: Bool { env["CHATGAUGE_UI_SELFTEST"] != nil }
    static var testBin: String? { isTest ? env["CHATGAUGE_SETUP_BIN"] : nil }
    static var testWhisperBase: String? { isTest ? env["CHATGAUGE_SETUP_WHISPER_BASE"] : nil }

    static var dirs: [String] { testBin.map { [$0] } ?? ["/opt/homebrew/bin", "/usr/local/bin"] }

    static func find(_ exe: String) -> String? {
        var c = dirs.map { ($0 as NSString).appendingPathComponent(exe) }
        if exe == "ollama" && testBin == nil { c.append("/Applications/Ollama.app/Contents/Resources/ollama") }
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var path: String { (dirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":") }

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = path
        e["HOMEBREW_NO_ENV_HINTS"] = "1"
        for (k, v) in extra { e[k] = v }
        return e
    }

    static func whisperURL(_ name: String) -> URL {
        if let b = testWhisperBase, let u = URL(string: "\(b)/ggml-\(name).bin") { return u }
        return WhisperModelPicker.downloadURL(name)
    }
}

/// A child process whose output is streamed line by line (brew install, the temporary `ollama serve`).
final class LiveProcess: @unchecked Sendable {
    let process = Process()

    func run(_ path: String, _ args: [String], env: [String: String], output: @escaping @Sendable (String) -> Void) async -> Int32 {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let h = pipe.fileHandleForReading
        h.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil } else { output(String(decoding: d, as: UTF8.self)) }
        }
        return await withCheckedContinuation { c in
            process.terminationHandler = { p in
                h.readabilityHandler = nil
                let rest = h.readDataToEndOfFile()
                if !rest.isEmpty { output(String(decoding: rest, as: UTF8.self)) }
                c.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch {
                output("Couldn't start \(path): \(error.localizedDescription)\n")
                process.terminationHandler = nil
                c.resume(returning: -1)
            }
        }
    }

    func start(_ path: String, _ args: [String], env: [String: String], log: URL?) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = env
        if let log, let fh = try? FileHandle(forWritingTo: log) {
            process.standardOutput = fh
            process.standardError = fh
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }
}

struct ToolInfo: Equatable, Sendable {
    var path: String?
    var version: String?
}

enum JobState: Equatable {
    case idle
    case running(Double?, String)
    case paused(Double?)
    case done(String)
    case failed(String)

    var isRunning: Bool { if case .running = self { return true } else { return false } }
    var fraction: Double? {
        switch self {
        case .running(let f, _), .paused(let f): return f
        case .done: return 1
        default: return nil
        }
    }
}

/// A system-changing step, shown before it runs ("This will run: …"). Nothing runs until Run is clicked.
struct PendingPlan: Identifiable {
    let id = UUID()
    var title: String
    var lines: [String]
    var note: String?
    var runTitle: String
    var run: @MainActor () -> Void
}

@MainActor
final class SetupModel: ObservableObject {
    let store: SettingsStore
    let engine: ChatEngine
    let home = FileManager.default.homeDirectoryForCurrentUser

    @Published var step: SetupStep = .welcome
    @Published var pending: PendingPlan?

    // Check
    @Published private(set) var checking = false
    @Published private(set) var checkedOnce = false
    let memBytes: UInt64 = TierDetector.memBytes()
    var recommendation: SetupRecommendation { SetupRecommendation.forRAM(bytes: memBytes) }
    let macOS = ProcessInfo.processInfo.operatingSystemVersionString
    let appleSilicon: Bool = {
        var v: Int32 = 0
        var n = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) == 0 && v == 1
    }()
    @Published private(set) var brew = ToolInfo()
    @Published private(set) var tools: [SetupTool: ToolInfo] = [:]
    @Published private(set) var existing: ExistingServer = .none
    @Published private(set) var volumes: [VolumeInfo] = []

    // Location
    @Published var folder: String
    @Published private(set) var locationConfirmed = false

    // Models
    @Published var chatPicks: Set<String> = []
    @Published var whisperPick: String?
    @Published private(set) var installedChat: [String] = []
    @Published private(set) var installedWhisper: [String] = []
    @Published private(set) var pulls: [String: JobState] = [:]
    @Published private(set) var whisperJob: JobState = .idle
    @Published private(set) var downloading = false
    @Published private(set) var paused = false
    @Published private(set) var downloadMessage: String?
    private var pullTask: Task<Void, Never>?
    private var whisperTask: URLSessionDownloadTask?
    private var whisperResume: Data?
    private var whisperObservation: NSKeyValueObservation?
    private var tempServer: LiveProcess?
    private var stopRequested = false

    // Tools
    @Published private(set) var log = ""
    @Published private(set) var installing: SetupTool?
    private var brewProcess: LiveProcess?

    // Server
    @Published private(set) var usingExisting = false
    @Published private(set) var serverMessage: String?
    @Published private(set) var ownAgentInstalled = false

    // Test
    @Published private(set) var testJob: JobState = .idle
    @Published private(set) var micJob: JobState = .idle
    private var recorder: AVAudioRecorder?

    @Published private(set) var finished = false

    init(store: SettingsStore, engine: ChatEngine) {
        self.store = store
        self.engine = engine
        folder = engine.location.path.isEmpty ? ModelsLocation.defaultLocal() : engine.location.path
        let r = SetupRecommendation.forRAM(bytes: TierDetector.memBytes())
        chatPicks = [r.defaultChat]
        whisperPick = store.settings.voiceEnabled ? r.whisper.name : nil
        ownAgentInstalled = FileManager.default.fileExists(atPath: OwnOllamaAgent.plistPath())
    }

    // MARK: Progress / skipping

    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    var whisperFolder: URL { folderURL.appendingPathComponent("whisper", isDirectory: true) }

    var volume: VolumeInfo? { VolumeCheck.volume(for: folder, in: volumes) }
    var neededBytes: Int64 {
        let missing = chatPicks.filter { !installedChat.contains($0) }
        let w = whisperPick.flatMap { installedWhisper.contains($0) ? nil : $0 }
        return SetupRecommendation.neededBytes(chat: Array(missing), whisper: w)
    }
    var folderIssues: [VolumeIssue] {
        guard let v = volume else { return [] }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder, isDirectory: &isDir)
        return VolumeCheck.evaluate(v, needBytes: neededBytes, writable: Self.writable(folder), isFile: exists && !isDir.boolValue)
    }
    var folderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue
    }

    var voiceWanted: Bool { whisperPick != nil }

    var progress: SetupProgress {
        SetupProgress(
            locationReady: folderExists && (locationConfirmed || !installedChat.isEmpty) && VolumeCheck.canUse(folderIssues),
            toolsReady: tools[.ollama]?.path != nil && (!voiceWanted || (tools[.whisper]?.path != nil && tools[.ffmpeg]?.path != nil)),
            modelsReady: !installedChat.isEmpty && (!voiceWanted || !installedWhisper.isEmpty),
            serverReady: { if case .running = existing { return existing.serves(folder, home: home) != false } else { return false } }())
    }

    func satisfied(_ s: SetupStep) -> Bool {
        switch s {
        case .welcome: return step.rawValue > 0
        case .check: return checkedOnce
        case .test: if case .done = testJob { return true } else { return false }
        case .done: return finished
        default: return SetupFlow.isSatisfied(s, progress)
        }
    }

    func goNext() {
        pending = nil
        if step == .done { return }
        step = SetupFlow.next(after: step, progress)
        if step == .check && !checkedOnce { runChecks() }
    }
    func goBack() { pending = nil; step = SetupFlow.previous(before: step, progress) }
    func go(_ s: SetupStep) { pending = nil; step = s }

    // MARK: Check

    func runChecks() {
        guard !checking else { return }
        checking = true
        let url = store.settings.serverURL
        let home = self.home
        Task {
            let r = await Task.detached(priority: .userInitiated) { Self.gather(home: home) }.value
            let client = OllamaClient(baseURL: url)
            let v = try? await client?.version(timeout: 2)
            var processModels: String?
            if v != nil, let port = URL(string: url)?.port {
                processModels = await Task.detached { Self.modelsOfListener(port: port) }.value
            }
            brew = r.brew
            tools = r.tools
            volumes = r.volumes
            existing = ServerDetection.describe(answering: v != nil, version: v, agents: r.agents, loadedLabels: r.loaded,
                                                processModels: processModels)
            ownAgentInstalled = FileManager.default.fileExists(atPath: OwnOllamaAgent.plistPath())
            rescanModels()
            checking = false
            checkedOnce = true
        }
    }

    func rescanModels() {
        installedChat = ModelManifests.installed(in: folderURL)
        installedWhisper = WhisperModelPicker.installed(in: whisperFolder)
    }

    struct Gathered: Sendable {
        var brew: ToolInfo
        var tools: [SetupTool: ToolInfo]
        var volumes: [VolumeInfo]
        var agents: [OllamaAgent]
        var loaded: Set<String>
    }

    nonisolated static func gather(home: URL) -> Gathered {
        let brewPath = SetupEnv.find("brew")
        var brew = ToolInfo(path: brewPath)
        var listed: [String: String] = [:]
        if let b = brewPath {
            brew.version = ToolVersionParser.brew(VoiceInput.run(b, ["--version"], timeout: 10).stdout)
            listed = ToolVersionParser.brewList(VoiceInput.run(b, ["list", "--versions"] + SetupTool.allCases.map(\.formula), timeout: 20).stdout)
        }
        var tools: [SetupTool: ToolInfo] = [:]
        for t in SetupTool.allCases {
            let p = SetupEnv.find(t.executable)
            var v = listed[t.formula]
            if v == nil, let p {
                switch t {
                case .ollama: v = ToolVersionParser.ollama({ let r = VoiceInput.run(p, ["--version"], timeout: 5); return r.stdout + r.stderr }())
                case .ffmpeg: v = ToolVersionParser.ffmpeg(VoiceInput.run(p, ["-version"], timeout: 5).stdout)
                case .whisper: v = nil
                }
            }
            tools[t] = ToolInfo(path: p, version: v)
        }
        let agents = OllamaAgent.discover(home: home)
        let loaded = Set(agents.map(\.label).filter(ChatEngine.isLoadedInLaunchd))
        return Gathered(brew: brew, tools: tools, volumes: volumes(home: home), agents: agents, loaded: loaded)
    }

    nonisolated static func volumes(home: URL) -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
                                      .volumeIsLocalKey]
        var out: [VolumeInfo] = []
        for u in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let path = u.path
            if path.hasPrefix("/System/") || path.hasPrefix("/private/") { continue }
            let root = path == "/"
            guard let v = try? (root ? home : u).resourceValues(forKeys: Set(keys)) else { continue }
            let important = v.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
            let avail = important ?? v.volumeAvailableCapacity.map(Int64.init)
            out.append(VolumeInfo(path: path, name: v.volumeName ?? (path as NSString).lastPathComponent,
                                  format: v.volumeLocalizedFormatDescription ?? "", availableBytes: avail,
                                  totalBytes: v.volumeTotalCapacity.map(Int64.init),
                                  isInternal: root || (v.volumeIsInternal ?? false),
                                  isReadOnly: root ? false : (v.volumeIsReadOnly ?? false),
                                  isNetwork: !(v.volumeIsLocal ?? true)))
        }
        return out.sorted { a, b in a.path == "/" || (b.path != "/" && a.name < b.name) }
    }

    /// OLLAMA_MODELS of whatever listens on the port (read-only: lsof + ps).
    nonisolated static func modelsOfListener(port: Int) -> String? {
        let l = VoiceInput.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 5)
        guard let pid = l.stdout.split(separator: "\n").first.map(String.init), Int(pid) != nil else { return nil }
        return ServerDetection.modelsFromProcess(VoiceInput.run("/bin/ps", ["-E", "-ww", "-o", "command=", "-p", pid], timeout: 5).stdout)
    }

    nonisolated static func writable(_ path: String) -> Bool {
        var p = (path as NSString).standardizingPath
        let fm = FileManager.default
        while !fm.fileExists(atPath: p) && p != "/" { p = (p as NSString).deletingLastPathComponent }
        return fm.isWritableFile(atPath: p)
    }

    // MARK: Location

    func choose(volume v: VolumeInfo) { setFolder(VolumeCheck.suggestedFolder(on: v, home: home)) }

    func setFolder(_ path: String) {
        folder = (path as NSString).standardizingPath
        locationConfirmed = false
        rescanModels()
    }

    func chooseFolderPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use Folder"
        p.message = "Choose a folder for the models (an Ollama models folder, or an empty one)."
        AppActivation.activateNow()
        if p.runModal() == .OK, let u = p.url { setFolder(u.path) }
    }

    func proposeUseFolder() {
        if folderExists {
            locationConfirmed = true
            serverMessage = nil
            return
        }
        let path = folder
        pending = PendingPlan(title: "Create the models folder", lines: SetupPlan.createFolder(path), note: nil, runTitle: "Create Folder") { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                self.locationConfirmed = true
            } catch {
                self.serverMessage = "Couldn't create the folder: \(error.localizedDescription)"
            }
            self.rescanModels()
        }
    }

    // MARK: Tools

    func proposeInstall(_ t: SetupTool) {
        guard let b = brew.path else { return }
        pending = PendingPlan(title: "Install \(t.title) with Homebrew", lines: SetupPlan.brewInstall(brew: b, tool: t),
                              note: "Homebrew downloads it from its own servers. This can take a few minutes.", runTitle: "Install") { [weak self] in
            self?.install(t, brew: b)
        }
    }

    private func install(_ t: SetupTool, brew b: String) {
        installing = t
        log += "$ \(SetupPlan.brewInstall(brew: b, tool: t)[0])\n"
        let p = LiveProcess()
        brewProcess = p
        Task {
            let status = await p.run(b, ["install", t.formula], env: SetupEnv.environment()) { s in
                Task { @MainActor [weak self] in self?.appendLog(s) }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            appendLog(status == 0 ? "✓ \(t.title) installed.\n\n" : "✗ brew exited with status \(status).\n\n")
            installing = nil
            brewProcess = nil
            runChecks()
        }
    }

    private func appendLog(_ s: String) {
        log += s
        if log.count > 60_000 { log = String(log.suffix(50_000)) }
    }

    func stopInstall() { brewProcess?.process.terminate() }

    // MARK: Models

    var viaExistingURL: String? {
        if case .running = existing, existing.serves(folder, home: home) == true { return store.settings.serverURL }
        return nil
    }

    var missingChat: [String] { chatPicks.sorted().filter { !installedChat.contains($0) } }
    var missingWhisper: String? { whisperPick.flatMap { installedWhisper.contains($0) ? nil : $0 } }

    func proposeDownloads() {
        let chat = missingChat
        let w = missingWhisper
        guard !chat.isEmpty || w != nil else { return }
        guard viaExistingURL != nil || tools[.ollama]?.path != nil else {
            downloadMessage = "Install Ollama first (step 4)."
            return
        }
        var lines = chat.isEmpty ? [] : SetupPlan.pull(models: chat, ollama: tools[.ollama]?.path ?? "ollama", folder: folder, viaExisting: viaExistingURL)
        if let w { lines += SetupPlan.whisperDownload(w, folder: whisperFolder.path, url: SetupEnv.whisperURL(w)) }
        let total = ByteCountFormatter.string(fromByteCount: neededBytes, countStyle: .file)
        pending = PendingPlan(title: "Download the models (about \(total))", lines: lines,
                              note: "Downloads go to \(folder). You can pause and resume; a paused download picks up where it stopped.",
                              runTitle: "Download") { [weak self] in
            self?.startDownloads()
        }
    }

    func startDownloads() {
        guard pullTask == nil else { return }
        stopRequested = false
        paused = false
        downloading = true
        downloadMessage = nil
        pullTask = Task { [weak self] in
            await self?.runDownloads()
            self?.pullTask = nil
        }
    }

    private func runDownloads() async {
        let chat = missingChat
        if !chat.isEmpty {
            var base = viaExistingURL
            if base == nil { base = await startTempServer() }
            guard let base else { downloading = false; return }
            for m in chat {
                if stopRequested { break }
                await pull(m, base: base)
            }
        }
        if !stopRequested, let w = missingWhisper { await downloadWhisper(w) }
        if !paused { stopTempServer() }
        downloading = false
        rescanModels()
        if !paused && !stopRequested && missingChat.isEmpty && missingWhisper == nil { downloadMessage = nil }
    }

    /// ChatGauge's own `ollama serve` on port 11435 with OLLAMA_MODELS = the chosen folder, only while downloading.
    private func startTempServer() async -> String? {
        let base = "http://127.0.0.1:\(SetupPlan.downloadPort)"
        if let t = tempServer, t.process.isRunning { return base }
        guard let ollama = tools[.ollama]?.path else { downloadMessage = "Ollama isn't installed."; return nil }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("chatgauge-setup-ollama.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let p = LiveProcess()
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try p.start(ollama, ["serve"], env: SetupEnv.environment(["OLLAMA_HOST": "127.0.0.1:\(SetupPlan.downloadPort)", "OLLAMA_MODELS": folder]),
                        log: logURL)
        } catch {
            downloadMessage = "Couldn't start Ollama: \(error.localizedDescription)"
            return nil
        }
        tempServer = p
        downloadMessage = "Starting a download server…"
        let client = OllamaClient(baseURL: base)
        for _ in 0..<40 {
            if (try? await client?.version(timeout: 1)) != nil { downloadMessage = nil; return base }
            if !p.process.isRunning { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        downloadMessage = "The download server didn't start. See \(logURL.path)."
        stopTempServer()
        return nil
    }

    func stopTempServer() {
        if let t = tempServer, t.process.isRunning { t.process.terminate() }
        tempServer = nil
    }

    var tempServerRunning: Bool { tempServer?.process.isRunning ?? false }

    private func pull(_ model: String, base: String) async {
        guard let client = OllamaClient(baseURL: base) else { return }
        pulls[model] = .running(nil, "Starting…")
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: client.pullRequest(model: model))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, nil) }
            var last: Double?
            for try await line in bytes.lines {
                guard let p = PullProgress.parse(Data(line.utf8)) else { continue }
                if let e = p.error { pulls[model] = .failed(e); return }
                if let f = p.fraction { last = f }
                pulls[model] = .running(last, p.status.capitalized)
                if p.status == "success" { pulls[model] = .done("Installed"); return }
            }
            pulls[model] = .failed("The download stopped early.")
        } catch {
            if paused { pulls[model] = .paused(pulls[model]?.fraction) }
            else if stopRequested { pulls[model] = .idle }
            else { pulls[model] = .failed((error as? OllamaError)?.description ?? error.localizedDescription) }
        }
    }

    private func downloadWhisper(_ name: String) async {
        let url = SetupEnv.whisperURL(name)
        let dest = WhisperModelPicker.fileURL(name, in: whisperFolder)
        let folder = whisperFolder
        whisperJob = .running(0, "Checking the published hash…")
        let expected = await Self.linkedSHA256(url)
        whisperJob = .running(whisperJob.fraction ?? 0, "Downloading")
        let staging = folder.appendingPathComponent(".ggml-\(name).download")
        let result: (ok: Bool, error: String?) = await withCheckedContinuation { c in
            let handler: @Sendable (URL?, URLResponse?, Error?) -> Void = { tmp, resp, err in
                if let err { c.resume(returning: (false, err.localizedDescription)); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 { c.resume(returning: (false, "HTTP \(http.statusCode)")); return }
                guard let tmp else { c.resume(returning: (false, "no file")); return }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.moveItem(at: tmp, to: staging)
                    c.resume(returning: (true, nil))
                } catch { c.resume(returning: (false, error.localizedDescription)) }
            }
            let task = whisperResume.map { URLSession.shared.downloadTask(withResumeData: $0, completionHandler: handler) }
                ?? URLSession.shared.downloadTask(with: url, completionHandler: handler)
            whisperResume = nil
            whisperObservation = task.progress.observe(\.fractionCompleted) { p, _ in
                let f = p.fractionCompleted
                Task { @MainActor [weak self] in if self?.whisperJob.isRunning == true { self?.whisperJob = .running(f, "Downloading") } }
            }
            whisperTask = task
            task.resume()
        }
        whisperTask = nil
        whisperObservation = nil
        guard result.ok else {
            if paused { whisperJob = .paused(whisperJob.fraction) }
            else if stopRequested { whisperJob = .idle }
            else { whisperJob = .failed("Download failed: \(result.error ?? "")") }
            return
        }
        whisperJob = .running(1, "Checking SHA-256…")
        let check: String? = await Task.detached { try? WhisperChecksum.sha256(of: staging) }.value
        if let expected {
            guard check == expected else {
                try? FileManager.default.removeItem(at: staging)
                whisperJob = .failed("The file didn't match Hugging Face's SHA-256, so it was deleted.")
                return
            }
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: staging, to: dest)
            whisperJob = .done(expected == nil ? "Installed (no published hash to check)" : "Installed · SHA-256 verified")
        } catch {
            whisperJob = .failed(error.localizedDescription)
        }
    }

    /// Hugging Face puts the LFS file's SHA-256 in X-Linked-Etag on the redirect, so ask without following it.
    nonisolated static func linkedSHA256(_ url: URL) async -> String? {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        }
        let s = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.httpMethod = "HEAD"
        guard let (_, resp) = try? await s.data(for: r), let h = resp as? HTTPURLResponse else { return nil }
        return WhisperChecksum.sha256(fromLinkedEtag: h.value(forHTTPHeaderField: "X-Linked-Etag"))
    }

    func pauseDownloads() {
        guard downloading else { return }
        paused = true
        stopRequested = true
        pullTask?.cancel()
        if let t = whisperTask {
            t.cancel(byProducingResumeData: { d in Task { @MainActor [weak self] in self?.whisperResume = d } })
        }
    }

    func resumeDownloads() {
        guard paused else { return }
        let prior = pullTask
        Task {
            await prior?.value
            paused = false
            for (k, v) in pulls { if case .paused(let f) = v { pulls[k] = .running(f, "Resuming…") } }
            if case .paused(let f) = whisperJob { whisperJob = .running(f, "Resuming…") }
            startDownloads()
        }
    }

    var pullsSettled: Bool { !pulls.values.contains { $0.isRunning } && !whisperJob.isRunning }

    func cancelDownloads() {
        let wasPaused = paused
        paused = false
        stopRequested = true
        pullTask?.cancel()
        whisperTask?.cancel()
        whisperResume = nil
        if wasPaused || pullTask == nil {
            for (k, v) in pulls { if case .paused = v { pulls[k] = .idle } }
            if case .paused = whisperJob { whisperJob = .idle }
            downloading = false
        }
        stopTempServer()
        downloadMessage = "Downloads cancelled. Ollama keeps finished parts, so a new download starts where this one stopped."
    }

    // MARK: Server

    func useExisting() {
        usingExisting = true
        if let p = existing.modelsPath, existing.serves(folder, home: home) == false {
            serverMessage = "That server uses \(p). Downloads in step 5 went to \(folder). Use its folder, or start ChatGauge's own server."
        } else {
            serverMessage = "ChatGauge will use the server that's already running. It won't change it."
        }
    }

    func useExistingFolder() {
        guard let p = existing.modelsPath else { return }
        setFolder(p)
        locationConfirmed = true
        serverMessage = "Models folder set to the server's folder."
    }

    var ownAgentPlanLines: [String] {
        let path = OwnOllamaAgent.plistPath(home: home)
        var lines = SetupPlan.agentInstall(plistPath: path, uid: getuid())
        lines.insert("  Label \(OwnOllamaAgent.label), OLLAMA_MODELS=\(SetupPlan.quote(folder)), OLLAMA_HOST=127.0.0.1:11434", at: 1)
        lines.insert("  runs: /bin/sh -c \(SetupPlan.quote(OwnOllamaAgent.script(ollama: tools[.ollama]?.path ?? "/opt/homebrew/bin/ollama", modelsPath: folder)))", at: 2)
        return lines
    }

    /// Self-test only: swap the detected server so the plan for the other case can be shown.
    func selfTestSetServer(_ s: ExistingServer) {
        guard SetupEnv.isTest else { return }
        existing = s; serverMessage = nil
    }

    func proposeOwnAgent() {
        guard existing.offersOwnAgent else { pending = nil; serverMessage = "A server is already running; use it instead of adding another."; return }
        pending = PendingPlan(title: "Create ChatGauge's own Ollama server", lines: ownAgentPlanLines,
                              note: "A user LaunchAgent that starts at login\(ModelsLocation.volumeRoot(of: folder) != nil ? " and waits for the drive to be connected" : ""). Remove it any time in Settings › Model & Server.",
                              runTitle: "Create Server") { [weak self] in self?.installOwnAgent() }
    }

    private func installOwnAgent() {
        // The self-test only shows the plan; it never touches launchd.
        guard !SetupEnv.isTest else { serverMessage = "(Self-test: not run.)"; return }
        guard existing.offersOwnAgent, let ollama = tools[.ollama]?.path else { serverMessage = "Another Ollama server is set up; ChatGauge leaves it alone."; return }
        let path = OwnOllamaAgent.plistPath(home: home)
        let logPath = OwnOllamaAgent.logPath(home: home)
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try OwnOllamaAgent.plistData(ollama: ollama, modelsPath: folder, logPath: logPath).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            serverMessage = "Couldn't write the LaunchAgent: \(error.localizedDescription)"
            return
        }
        ownAgentInstalled = true
        serverMessage = ChatEngine.launchctl(["bootstrap", "gui/\(getuid())", path]) ? "Starting…" : "launchctl couldn't load it; it starts at the next login."
        Task {
            let client = OllamaClient(baseURL: "http://127.0.0.1:11434")
            for _ in 0..<40 {
                if (try? await client?.version(timeout: 1)) != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            store.update { $0.serverURL = "http://127.0.0.1:11434" }
            runChecks()
            serverMessage = "ChatGauge's server is set up."
        }
    }

    // MARK: Test

    var testModel: String? { chatPicks.sorted().first { installedChat.contains($0) } ?? installedChat.first }

    func sayOK() {
        guard let client = OllamaClient(baseURL: store.settings.serverURL) else { return }
        let model = testModel ?? recommendation.defaultChat
        testJob = .running(nil, "Asking \(model)… (the first answer loads the model, which can take a minute)")
        Task {
            do {
                let r = try await client.chatOnce(model: model, messages: [WireMessage(role: "user", content: "Say OK")],
                                                  keepAlive: 300, maxTokens: 8, timeout: 240)
                let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                testJob = .done(t.isEmpty ? "(empty reply)" : t)
            } catch {
                testJob = .failed((error as? OllamaError)?.description ?? error.localizedDescription)
            }
        }
    }

    var micReady: Bool { tools[.whisper]?.path != nil && !installedWhisper.isEmpty }

    func micTest() {
        guard let cli = tools[.whisper]?.path, let name = (whisperPick.flatMap { installedWhisper.contains($0) ? $0 : nil }) ?? installedWhisper.first else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor [weak self] in if ok { self?.micTest() } else { self?.micJob = .failed("Microphone access was declined.") } }
            }
            return
        case .authorized: break
        default:
            micJob = .failed("Microphone access is off: System Settings › Privacy & Security › Microphone.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chatgauge-mictest-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record(forDuration: 3) else {
            micJob = .failed("Couldn't start recording.")
            return
        }
        recorder = r
        micJob = .running(nil, "Listening for 3 seconds… say something")
        let model = WhisperModelPicker.fileURL(name, in: whisperFolder).path
        Task {
            try? await Task.sleep(nanoseconds: 3_300_000_000)
            recorder?.stop()
            recorder = nil
            micJob = .running(nil, "Transcribing on this Mac…")
            let res = await Task.detached {
                VoiceInput.transcribe(recording: url, cli: cli, ffmpeg: nil, model: model, modelName: name, prompt: nil, timeout: 90)
            }.value
            switch res {
            case .success(let t): micJob = .done(t.isEmpty ? "(heard nothing)" : "\u{201C}\(t)\u{201D}")
            case .failure(let e): micJob = .failed(e.text)
            }
        }
    }

    // MARK: Done

    func finish() {
        let path = folder
        let std = (path as NSString).standardizingPath == (ModelsLocation.defaultLocal(home: home) as NSString).standardizingPath
        let w = whisperPick.flatMap { installedWhisper.contains($0) ? $0 : nil } ?? installedWhisper.first
        store.update { s in
            s.modelsLocation = ModelsLocation.volumeRoot(of: path) == nil ? .local : .external
            s.modelsPath = std ? nil : path
            if let w { s.whisperModel = w }
            s.setupCompletedAt = Date()
        }
        store.saveNow()
        finished = true
        Task { await engine.refresh() }
    }

    /// Window closed: stop anything still running (never the user's server; only ChatGauge's temporary one).
    func stopAll() {
        if downloading { cancelDownloads() }
        stopTempServer()
        brewProcess?.process.terminate()
        recorder?.stop()
    }
}

/// ChatGauge's own LaunchAgent, removed from Settings (never anyone else's).
@MainActor
enum OwnAgentControl {
    static var installed: Bool { FileManager.default.fileExists(atPath: OwnOllamaAgent.plistPath()) }

    static func confirmRemove() -> String? {
        let path = OwnOllamaAgent.plistPath()
        guard OwnOllamaAgent.mayRemove(label: OwnOllamaAgent.label), installed else { return nil }
        let a = NSAlert()
        a.messageText = "Remove ChatGauge's Ollama server?"
        a.informativeText = "This will run:\n" + SetupPlan.agentRemove(plistPath: path, uid: getuid()).joined(separator: "\n")
            + "\n\nYour models stay where they are. Other Ollama servers are not touched."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        AppActivation.activateNow()
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        _ = ChatEngine.launchctl(["bootout", "gui/\(getuid())/\(OwnOllamaAgent.label)"])
        do { try FileManager.default.removeItem(atPath: path) } catch { return "Couldn't delete the plist: \(error.localizedDescription)" }
        return "ChatGauge's Ollama server was removed."
    }
}

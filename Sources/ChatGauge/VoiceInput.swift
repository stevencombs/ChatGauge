import AVFoundation
import AppKit
import ChatGaugeCore
import SwiftUI

/// Hold-to-talk: records while the mic button is held, transcribes locally with whisper-cli, and puts the
/// text in the composer. It never sends.
@MainActor
final class VoiceInput: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, transcribing, downloading(Double)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message: String?
    @Published private(set) var level: Float = 0
    @Published private(set) var startedAt: Date?

    private let engine: ChatEngine
    private let whisperPrompt: () -> String?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    static let maxSeconds: TimeInterval = 120

    init(engine: ChatEngine, whisperPrompt: @escaping () -> String?) {
        self.engine = engine
        self.whisperPrompt = whisperPrompt
    }

    // MARK: What's available

    var whisperFolder: URL { engine.location.whisperFolder }
    var installedModels: [String] { WhisperModelPicker.installed(in: whisperFolder) }
    var modelName: String? {
        WhisperModelPicker.pick(installed: installedModels, tier: engine.tier, rules: engine.rules, override: engine.settings.whisperModel)
    }
    var suggestedModel: String { WhisperModelPicker.suggested(tier: engine.tier, rules: engine.rules) }

    /// Why the mic can't be used right now (nil = ready).
    var unavailableReason: String? {
        if !engine.settings.voiceEnabled { return "Voice input is off in Settings → Chat." }
        if VoiceTools.whisperCLI == nil { return "Voice needs whisper.cpp. Install it with: brew install whisper-cpp" }
        if engine.location.availability() != .ready { return "The models drive isn't connected, so the whisper model can't be read." }
        if modelName == nil { return "No whisper model in \(whisperFolder.path)." }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            return "Microphone access is off. Turn on ChatGauge in System Settings → Privacy & Security → Microphone."
        }
        return nil
    }

    var canDownloadModel: Bool {
        engine.settings.voiceEnabled && VoiceTools.whisperCLI != nil && engine.location.availability() == .ready && modelName == nil
    }

    // MARK: Recording

    func begin() {
        guard phase == .idle else { return }
        message = nil
        if let r = unavailableReason { message = r; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async {
                    self?.message = ok ? "Microphone ready. Hold the mic button to talk." : "Microphone access was declined."
                }
            }
            return
        case .authorized: break
        default:
            message = unavailableReason
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chatgauge-voice-\(UUID().uuidString).caf")
        // Record straight to 16 kHz mono when ffmpeg isn't around; otherwise native and let ffmpeg convert.
        let settings: [String: Any] = VoiceTools.ffmpeg == nil
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            let r = try AVAudioRecorder(url: VoiceTools.ffmpeg == nil ? url.deletingPathExtension().appendingPathExtension("wav") : url,
                                        settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: Self.maxSeconds) else { message = "Couldn't start recording."; return }
            recorder = r
            recordingURL = r.url
            startedAt = Date()
            phase = .recording
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            message = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        if !r.isRecording { end(); return }
        r.updateMeters()
        level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
    }

    func end() {
        guard phase == .recording, let r = recorder, let url = recordingURL else { return }
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        r.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        level = 0
        startedAt = nil
        if duration < 0.4 {
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            message = "Hold the mic button while you talk, then let go."
            return
        }
        guard let cli = VoiceTools.whisperCLI, let name = modelName else { phase = .idle; return }
        phase = .transcribing
        let model = WhisperModelPicker.fileURL(name, in: whisperFolder).path
        let prompt = whisperPrompt()
        let ffmpeg = VoiceTools.ffmpeg
        Task.detached(priority: .userInitiated) {
            let result = Self.transcribe(recording: url, cli: cli, ffmpeg: ffmpeg, model: model, modelName: name,
                                         prompt: prompt, timeout: 60 + duration * 4)
            await MainActor.run { [weak self] in self?.finish(result) }
        }
    }

    private func finish(_ result: Result<String, VoiceError>) {
        phase = .idle
        switch result {
        case .success(let text):
            if text.isEmpty {
                message = "Didn't catch anything. Try again a little closer to the mic."
            } else {
                engine.draft = VoiceCommands.insert(text, into: engine.draft)
                message = nil
            }
        case .failure(let e):
            message = e.text
        }
    }

    struct VoiceError: Error { var text: String }

    nonisolated static func transcribe(recording: URL, cli: String, ffmpeg: String?, model: String, modelName: String,
                                               prompt: String?, timeout: TimeInterval) -> Result<String, VoiceError> {
        let fm = FileManager.default
        var wav = recording
        defer {
            try? fm.removeItem(at: recording)
            if wav != recording { try? fm.removeItem(at: wav) }
        }
        if let ffmpeg {
            wav = recording.deletingPathExtension().appendingPathExtension("wav")
            let r = run(ffmpeg, VoiceCommands.ffmpegArgs(input: recording.path, output: wav.path), timeout: 30)
            guard r.status == 0 else { return .failure(VoiceError(text: "ffmpeg couldn't convert the recording.")) }
        }
        let threads = ProcessInfo.processInfo.activeProcessorCount
        let r = run(cli, VoiceCommands.whisperArgs(model: model, modelName: modelName, wav: wav.path, prompt: prompt, threads: threads),
                    timeout: timeout)
        if r.timedOut { return .failure(VoiceError(text: "Transcribing took too long and was stopped.")) }
        guard r.status == 0 else {
            let tail = r.stderr.split(separator: "\n").last.map(String.init) ?? ""
            return .failure(VoiceError(text: "whisper-cli failed\(tail.isEmpty ? "" : ": " + String(tail.prefix(160)))"))
        }
        return .success(VoiceCommands.cleanTranscript(r.stdout))
    }

    nonisolated static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", error.localizedDescription, false) }
        // Read while it runs so a full pipe can't stall the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline { p.terminate(); timedOut = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), timedOut)
    }

    // MARK: Model download (only when the user clicks and confirms)

    func confirmAndDownloadModel() {
        let name = suggestedModel
        let alert = NSAlert()
        alert.messageText = "Download the whisper model \(name)?"
        alert.informativeText = "About \(WhisperModelPicker.approximateSize(name)) from the whisper.cpp model repo on Hugging Face, saved to \(whisperFolder.path). Voice input runs locally after that."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        AppActivation.activateNow()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        download(name)
    }

    private func download(_ name: String) {
        let dest = WhisperModelPicker.fileURL(name, in: whisperFolder)
        let folder = whisperFolder
        phase = .downloading(0)
        message = nil
        let task = URLSession.shared.downloadTask(with: WhisperModelPicker.downloadURL(name)) { [weak self] tmp, response, error in
            var problem: String?
            if let error { problem = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 { problem = "HTTP \(http.statusCode)" }
            else if let tmp {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                } catch { problem = error.localizedDescription }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .idle
                self.message = problem.map { "Download failed: \($0)" } ?? "Whisper \(name) is ready. Hold the mic to talk."
                self.objectWillChange.send()
            }
        }
        downloadTask = task
        let obs = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { if case .downloading = self?.phase { self?.phase = .downloading(f) } }
        }
        progressObservation = obs
        task.resume()
    }

    func cancelDownload() { downloadTask?.cancel() }
    func dismissMessage() { message = nil }
}

/// The mic button in the composer: press and hold to talk.
struct VoiceButton: View {
    @ObservedObject var voice: VoiceInput
    @ViewState private var pressing = false
    @ViewState private var showInfo = false

    var body: some View {
        Group {
            switch voice.phase {
            case .transcribing:
                ProgressView().controlSize(.small).frame(width: 22).help("Transcribing on this Mac…")
            case .downloading(let f):
                Button { voice.cancelDownload() } label: {
                    ProgressView(value: f).progressViewStyle(.circular).controlSize(.small)
                }
                .buttonStyle(.borderless).help("Downloading the whisper model (\(Int(f * 100))%). Click to cancel.")
            default:
                mic
            }
        }
        .popover(isPresented: $showInfo, arrowEdge: .top) { info.padding(12).frame(width: 280) }
        .onChange(of: voice.message) { _, m in showInfo = m != nil }
    }

    private var mic: some View {
        let recording = voice.phase == .recording
        return Image(systemName: recording ? "mic.fill" : (voice.unavailableReason == nil ? "mic" : "mic.slash"))
            .font(.system(size: 15))
            .foregroundStyle(recording ? Palette.red : .secondary)
            .scaleEffect(recording ? 1 + CGFloat(voice.level) * 0.35 : 1)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    voice.begin()
                }
                .onEnded { _ in
                    pressing = false
                    voice.end()
                })
            .help(recording ? "Recording… let go to transcribe" : (voice.unavailableReason ?? "Hold to talk (transcribed on this Mac, never sent until you press Send)"))
            .accessibilityLabel("Hold to talk")
            .accessibilityAddTraits(.isButton)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(voice.message ?? "").font(.callout).fixedSize(horizontal: false, vertical: true)
            if voice.canDownloadModel {
                Button("Download \(voice.suggestedModel) (\(WhisperModelPicker.approximateSize(voice.suggestedModel)))…") {
                    showInfo = false
                    voice.confirmAndDownloadModel()
                }
            }
            HStack {
                Spacer()
                Button("OK") { voice.dismissMessage() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

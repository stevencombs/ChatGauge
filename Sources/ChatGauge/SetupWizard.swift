import AppKit
import ChatGaugeCore
import SwiftUI

private func size(_ b: Int64?) -> String { b.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown" }

/// First-run setup: tools, models on an internal or external drive, the server, and a quick test.
struct SetupWizardView: View {
    @ObservedObject var model: SetupModel
    var close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let p = model.pending { PlanView(plan: p, cancel: { model.pending = nil }, run: {
                            model.pending = nil
                            p.run()
                        }) }
                        content
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .frame(width: 840, height: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SetupStep.allCases, id: \.self) { s in
                Button { model.go(s) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.satisfied(s) && s != model.step ? "checkmark.circle.fill" : s.symbol)
                            .foregroundStyle(model.satisfied(s) && s != model.step ? Palette.green : (s == model.step ? Color.accentColor : .secondary))
                            .frame(width: 18)
                        Text(s.title).fontWeight(s == model.step ? .semibold : .regular)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(s == model.step ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Nothing is installed or downloaded until you click.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(10)
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .frame(width: 200)
        .background(.fill.quinary)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.title2.weight(.semibold))
                Text("Step \(model.step.rawValue + 1) of \(SetupStep.allCases.count) · \(model.step.title)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)
    }

    private var headline: String {
        switch model.step {
        case .welcome: return "Welcome to ChatGauge"
        case .check: return "Check this Mac"
        case .location: return "Where should the models live?"
        case .tools: return "Install the tools"
        case .models: return "Pick the models"
        case .server: return "The Ollama server"
        case .test: return "Try it"
        case .done: return "You're set"
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome { Button("Back") { model.goBack() }.controlSize(.large) }
            Spacer()
            if model.step.skippable && !model.satisfied(model.step) {
                Button("Skip") { model.goNext() }.controlSize(.large)
            }
            if model.step == .done {
                Button(model.finished ? "Close" : "Save & Close") {
                    if !model.finished { model.finish() }
                    close()
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .welcome ? "Get Started" : "Continue") { model.goNext() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(model.step == .check && model.checking)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .check: CheckStep(model: model)
        case .location: LocationStep(model: model)
        case .tools: ToolsStep(model: model)
        case .models: ModelsStep(model: model)
        case .server: ServerStep(model: model)
        case .test: TestStep(model: model)
        case .done: DoneStep(model: model)
        }
    }
}

// MARK: - Pieces

struct PlanView: View {
    var plan: PendingPlan
    var cancel: () -> Void
    var run: () -> Void

    var body: some View {
        PrefGroup(title: "This will run: \(plan.title)", footer: plan.note) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(plan.runTitle, action: run).buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1).padding(.top, 22))
    }
}

struct SetupStatusLine: View {
    var ok: Bool?
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.triangle.fill" : "circle.dotted")
                .foregroundStyle(ok == true ? Palette.green : ok == false ? Palette.orange : .secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct JobView: View {
    var name: String
    var detail: String
    var job: JobState
    var body: some View {
        PrefRow(label: name, detail: detail) {
            switch job {
            case .idle: Text("Not downloaded").foregroundStyle(.secondary)
            case .running(let f, let s):
                VStack(alignment: .trailing, spacing: 2) {
                    if let f { ProgressView(value: f).frame(width: 160) } else { ProgressView().controlSize(.small) }
                    Text(f.map { "\(s) · \(Int($0 * 100))%" } ?? s).font(.caption).foregroundStyle(.secondary)
                }
            case .paused(let f):
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: f ?? 0).frame(width: 160)
                    Text("Paused\(f.map { " · \(Int($0 * 100))%" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            case .done(let s): Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
            case .failed(let s): Text(s).foregroundStyle(Palette.red).font(.caption).frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        let r = model.recommendation
        let chat = SetupCatalog.chat[r.defaultChat]
        let w = SetupCatalog.whisper[r.whisper.name]
        VStack(alignment: .leading, spacing: 16) {
            Text("ChatGauge runs a vision chat model and speech-to-text entirely on this Mac. This guide installs what's missing and puts the models on the drive you choose — the internal disk or an external one.")
                .fixedSize(horizontal: false, vertical: true)
            PrefGroup(title: "What it sets up", footer: "Each install or download is shown first and only runs when you click. Steps that are already done are skipped.") {
                PrefRow(label: "Ollama", detail: "Runs the chat model. Installed with Homebrew.") { Text("about \(size(SetupCatalog.toolsBytes))").foregroundStyle(.secondary) }
                Divider()
                PrefRow(label: "Chat model: \(r.defaultChat)", detail: chat?.note) { Text(size(chat?.bytes)).foregroundStyle(.secondary) }
                Divider()
                PrefRow(label: "Voice (optional): whisper.cpp + \(r.whisper.name)", detail: w?.note) { Text(size(w?.bytes)).foregroundStyle(.secondary) }
            }
            PrefGroup {
                PrefRow(label: "Room needed", detail: "Recommended for this Mac (\(Int(Double(model.memBytes) / 1_073_741_824)) GB memory), plus some headroom.") {
                    Text("about \(size(SetupRecommendation.neededBytes(chat: [r.defaultChat], whisper: r.whisper.name)))").font(.headline)
                }
            }
        }
    }
}

struct CheckStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PrefGroup(title: "This Mac") {
                PrefRow(label: "Memory") { Text("\(Int(Double(model.memBytes) / 1_073_741_824)) GB") }
                Divider()
                PrefRow(label: "macOS") { Text(model.macOS).foregroundStyle(.secondary) }
                Divider()
                PrefRow(label: "Chip") { Text(model.appleSilicon ? "Apple silicon" : "Intel (models run slowly)") }
                Divider()
                PrefRow(label: "Free space on the startup disk") { Text(size(model.volumes.first { $0.path == "/" }?.availableBytes)) }
            }
            PrefGroup(title: "Tools", content: {
                PrefRow(label: "Homebrew") {
                    SetupStatusLine(ok: model.brew.path != nil, text: model.brew.path == nil ? "Not installed" : (model.brew.version ?? "Installed"))
                }
                ForEach(SetupTool.allCases, id: \.self) { t in
                    Divider()
                    PrefRow(label: t.title, detail: t.purpose) {
                        let i = model.tools[t]
                        SetupStatusLine(ok: i?.path != nil ? true : (t.required ? false : nil),
                                   text: i?.path == nil ? "Not installed" : (i?.version.map { "Version \($0)" } ?? "Installed"))
                    }
                }
            }, accessory: {
                if model.checking { ProgressView().controlSize(.small) } else { Button("Check Again") { model.runChecks() } }
            })
            PrefGroup(title: "Ollama server") {
                PrefRow(label: serverTitle, detail: serverDetail) {
                    SetupStatusLine(ok: model.existing.isPresent ? true : nil, text: model.existing.isPresent ? "Found" : "None")
                }
            }
        }
    }

    private var serverTitle: String {
        switch model.existing {
        case .running(let v, _, _): return "Running\(v.map { " · Ollama \($0)" } ?? "")"
        case .agentNotRunning(let l, _): return "Set up but not running (\(l))"
        case .none: return "No server yet"
        }
    }

    private var serverDetail: String {
        switch model.existing {
        case .running(_, let p, let l):
            return "Models folder: \(p ?? "not reported")" + (l.map { " · started by \($0)" } ?? "")
        case .agentNotRunning(_, let p): return "Models folder: \(p ?? "unknown"). Its drive may be unplugged."
        case .none: return "Step 6 can create one for ChatGauge."
        }
    }
}

struct LocationStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PrefGroup(title: "Drives", footer: "An external SSD keeps the internal disk free. ChatGauge sets OLLAMA_MODELS to the folder; it doesn't use symlinks.") {
                ForEach(Array(model.volumes.enumerated()), id: \.element.path) { i, v in
                    if i > 0 { Divider() }
                    Button { model.choose(volume: v) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: v.isInternal ? "internaldrive" : "externaldrive")
                                .font(.title3).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.path == "/" ? "\(v.name) (this Mac)" : v.name)
                                Text("\(size(v.availableBytes)) free of \(size(v.totalBytes)) · \(v.format.isEmpty ? "unknown format" : v.format)\(v.isReadOnly ? " · read-only" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.volume?.path == v.path {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.volumes.isEmpty { Text("Checking drives…").foregroundStyle(.secondary).padding(.vertical, 6) }
            }
            PrefGroup(title: "Models folder") {
                PrefRow(label: model.folder, detail: folderDetail) {
                    Button("Choose…") { model.chooseFolderPanel() }
                }
                ForEach(Array(model.folderIssues.enumerated()), id: \.offset) { _, issue in
                    Divider()
                    SetupStatusLine(ok: false, text: issue.message).foregroundStyle(issue.isError ? Palette.red : .primary).padding(.vertical, 5)
                }
                Divider()
                HStack {
                    if model.progress.locationReady { SetupStatusLine(ok: true, text: "Using this folder.") }
                    Spacer()
                    Button(model.folderExists ? "Use This Folder" : "Create Folder…") { model.proposeUseFolder() }
                        .disabled(!VolumeCheck.canUse(model.folderIssues))
                }
                .padding(.vertical, 6)
            }
            if let m = model.serverMessage, model.step == .location { Text(m).foregroundStyle(.secondary) }
        }
    }

    private var folderDetail: String {
        let n = model.installedChat.count
        if !model.folderExists { return "Will be created. Needs about \(size(model.neededBytes))." }
        return n > 0 ? "\(n) model\(n == 1 ? "" : "s") already here." : "Empty. Needs about \(size(model.neededBytes))."
    }
}

struct ToolsStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.brew.path == nil {
                PrefGroup(title: "Homebrew isn't installed", footer: "ChatGauge never runs an install script for you. After installing, click Check Again.") {
                    Text("Homebrew is the usual way to install command-line tools on a Mac. Install it from brew.sh (it asks for your password in Terminal), or install the Ollama app directly from ollama.com.")
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                    HStack {
                        Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                        Link("Ollama for Mac", destination: URL(string: "https://ollama.com/download/mac")!)
                        Spacer()
                        Button("Check Again") { model.runChecks() }
                    }
                    .padding(.vertical, 6)
                }
            }
            PrefGroup(title: "Tools", footer: "Voice needs whisper.cpp and ffmpeg; skip them if you won't dictate.") {
                ForEach(Array(SetupTool.allCases.enumerated()), id: \.offset) { i, t in
                    if i > 0 { Divider() }
                    PrefRow(label: t.title + (t.required ? "" : " (for voice)"), detail: t.purpose) {
                        if let v = model.tools[t], v.path != nil {
                            SetupStatusLine(ok: true, text: v.version.map { "Installed · \($0)" } ?? "Installed")
                        } else if model.installing == t {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Install…") { model.proposeInstall(t) }.disabled(model.brew.path == nil || model.installing != nil)
                        }
                    }
                }
            }
            if !model.log.isEmpty || model.installing != nil {
                PrefGroup(title: "Homebrew output", content: {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(model.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).id("end")
                        }
                        .frame(height: 150)
                        .onChange(of: model.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .padding(.vertical, 6)
                }, accessory: {
                    if model.installing != nil { Button("Stop") { model.stopInstall() } }
                })
            }
        }
    }
}

struct ModelsStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        let r = model.recommendation
        VStack(alignment: .leading, spacing: 16) {
            PrefGroup(title: "Chat model", footer: "Recommended for \(Int(Double(model.memBytes) / 1_073_741_824)) GB of memory: \(r.defaultChat).\(r.optionalChat.first.map { " \($0) is sharper but slower." } ?? "")") {
                ForEach(Array(r.chat.enumerated()), id: \.element.name) { i, o in
                    if i > 0 { Divider() }
                    pickRow(o, recommended: o.name == r.defaultChat)
                }
            }
            PrefGroup(title: "Optional uncensored models",
                      footer: "Not selected by default. Each Install shows a dry run and downloads only after you click. Uses the existing Ollama server when it serves this folder.") {
                ForEach(Array(ModelCatalog.uncensored.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Divider() }
                    HStack(spacing: 10) {
                        JobView(name: e.name, detail: "\(size(e.bytes)) · \(e.blurb)",
                                job: model.installedChat.contains(e.name) ? .done("Installed") : (model.pulls[e.name] ?? .idle))
                        if model.installedChat.contains(e.name) {
                            Text("Installed").foregroundStyle(.secondary)
                        } else if model.pulls[e.name]?.isRunning == true {
                            Button("Cancel") { model.cancelDownloads() }
                        } else {
                            Button("Install…") { model.proposeUncensored(e.name) }
                                .disabled(model.downloading || (model.tools[.ollama]?.path == nil && model.viaExistingURL == nil))
                        }
                    }
                }
            }
            PrefGroup(title: "Voice model (whisper)", footer: "Saved in \(model.whisperFolder.path).") {
                Toggle(isOn: Binding(get: { model.whisperPick != nil }, set: { model.whisperPick = $0 ? r.whisper.name : nil })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Voice input with \(r.whisper.name)")
                        Text("\(size(r.whisper.bytes)) · \(r.whisper.note)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).padding(.vertical, 7)
                if let w = model.whisperPick {
                    Divider()
                    JobView(name: "ggml-\(w).bin", detail: size(SetupCatalog.whisper[w]?.bytes),
                            job: model.installedWhisper.contains(w) && !model.whisperJob.isRunning ? .done("Installed") : model.whisperJob)
                }
            }
            HStack {
                Text(model.missingChat.isEmpty && model.missingWhisper == nil ? "Everything picked is downloaded." : "To download: about \(size(model.neededBytes)) into \(model.folder)")
                    .foregroundStyle(.secondary).font(.callout)
                Spacer()
                if model.downloading && !model.paused {
                    Button("Pause") { model.pauseDownloads() }
                    Button("Cancel") { model.cancelDownloads() }
                } else if model.paused {
                    Button("Resume") { model.resumeDownloads() }.buttonStyle(.borderedProminent)
                    Button("Cancel") { model.cancelDownloads() }
                } else {
                    Button("Download…") { model.proposeDownloads() }
                        .disabled(model.missingChat.isEmpty && model.missingWhisper == nil)
                }
            }
            if let m = model.downloadMessage { Text(m).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private func pickRow(_ o: ModelOption, recommended: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.chatPicks.contains(o.name) }, set: { on in
                if on { model.chatPicks.insert(o.name) } else { model.chatPicks.remove(o.name) }
            }))
            .labelsHidden().disabled(model.downloading)
            JobView(name: o.name + (recommended ? "  (recommended)" : ""), detail: "\(size(o.bytes)) · \(o.note)",
                    job: model.installedChat.contains(o.name) ? .done("Installed") : (model.pulls[o.name] ?? .idle))
        }
    }
}

struct ServerStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.existing {
            case .running(let v, let p, let l):
                PrefGroup(title: "A server is already running", footer: "ChatGauge uses it as is. It never restarts, changes or replaces another app's server.") {
                    PrefRow(label: "Ollama \(v ?? "")", detail: "Models: \(p ?? "not reported")\(l.map { " · \($0)" } ?? "")") {
                        Button("Use the Existing Server") { model.useExisting() }.buttonStyle(.borderedProminent)
                    }
                    if p != nil, model.existing.serves(model.folder) == false {
                        Divider()
                        PrefRow(label: "It uses a different models folder", detail: "Your pick: \(model.folder)") {
                            Button("Use Its Folder") { model.useExistingFolder() }
                        }
                    }
                }
            case .agentNotRunning(let label, let p):
                PrefGroup(title: "A server is set up but not running", footer: "ChatGauge leaves \(label) alone. Connect its drive or start it the way you set it up, then check again.") {
                    PrefRow(label: label, detail: "Models: \(p ?? "unknown")") {
                        HStack {
                            if p != nil { Button("Use Its Folder") { model.useExistingFolder() } }
                            Button("Check Again") { model.runChecks() }
                        }
                    }
                }
            case .none:
                PrefGroup(title: "No server yet", footer: "Optional. Without it, start Ollama yourself (the Ollama app or `ollama serve`) before chatting.") {
                    PrefRow(label: "Create ChatGauge's own server", detail: "A login item (\(OwnOllamaAgent.label)) that runs Ollama with OLLAMA_MODELS = \(model.folder)\(ModelsLocation.volumeRoot(of: model.folder) != nil ? ", waiting until the drive is connected" : ""). Remove it any time in Settings.") {
                        if model.ownAgentInstalled { SetupStatusLine(ok: true, text: "Created") }
                        else { Button("Create…") { model.proposeOwnAgent() }.disabled(model.tools[.ollama]?.path == nil) }
                    }
                }
            }
            if let m = model.serverMessage, model.step == .server { SetupStatusLine(ok: model.usingExisting || model.ownAgentInstalled ? true : nil, text: m) }
        }
    }
}

struct TestStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PrefGroup(title: "Chat", footer: "Uses \(model.store.settings.serverURL).") {
                PrefRow(label: "Ask \(model.testModel ?? "the model") to say OK") {
                    Button("Say OK") { model.sayOK() }.disabled(model.testJob.isRunning)
                }
                if model.testJob != .idle {
                    Divider()
                    result(model.testJob)
                }
            }
            PrefGroup(title: "Microphone (optional)", footer: "Records 3 seconds and transcribes it on this Mac. Nothing is saved.") {
                PrefRow(label: "Test the microphone", detail: model.micReady ? nil : "Install whisper.cpp and a voice model first.") {
                    Button("Record 3 Seconds") { model.micTest() }.disabled(!model.micReady || model.micJob.isRunning)
                }
                if model.micJob != .idle {
                    Divider()
                    result(model.micJob)
                }
            }
        }
    }

    @ViewBuilder private func result(_ j: JobState) -> some View {
        switch j {
        case .running(_, let s): HStack { ProgressView().controlSize(.small); Text(s).foregroundStyle(.secondary) }.padding(.vertical, 6)
        case .done(let s): SetupStatusLine(ok: true, text: "Reply: \(s)").padding(.vertical, 6)
        case .failed(let s): SetupStatusLine(ok: false, text: s).padding(.vertical, 6)
        default: EmptyView()
        }
    }
}

struct DoneStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        let hk = model.store.settings.hotKey
        VStack(alignment: .leading, spacing: 16) {
            PrefGroup(title: "Summary") {
                PrefRow(label: "Models folder") { Text(model.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Divider()
                PrefRow(label: "Chat models") { Text(model.installedChat.isEmpty ? "none yet" : model.installedChat.joined(separator: ", ")) }
                Divider()
                PrefRow(label: "Voice") { Text(model.installedWhisper.first ?? "off") }
                Divider()
                PrefRow(label: "Server") { Text(model.existing.isPresent ? "existing" : (model.ownAgentInstalled ? "ChatGauge's own" : "start Ollama yourself")) }
            }
            PrefGroup {
                PrefRow(label: "Open ChatGauge any time", detail: "From the menu bar gauge, or with the shortcut. Run this setup again from Settings › Model & Server.") {
                    Text(hk.enabled ? hk.display : "menu bar").font(.title3.weight(.semibold))
                }
            }
            if model.finished { SetupStatusLine(ok: true, text: "Settings saved.") }
        }
    }
}

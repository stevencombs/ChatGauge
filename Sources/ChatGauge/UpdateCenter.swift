import AppKit
import ChatGaugeCore
import Combine
import SwiftUI
@preconcurrency import UserNotifications

/// Daily, read-only checks for ChatGauge, the Homebrew tools and the installed models.
/// Installs happen only on a click, or in "auto when idle" mode, and never while a chat is
/// generating, a model is loading or DaVinci Resolve is open. ChatGauge itself is never auto-installed.
@MainActor
final class UpdateCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var items: [UpdateItem] = []
    @Published private(set) var isChecking = false
    @Published private(set) var installing: String?
    @Published private(set) var message: String?
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "ChatGaugeLastUpdateCheck") as? Date
    @Published private(set) var latestRelease: ReleaseInfo?

    private let engine: ChatEngine
    private let settingsStore: SettingsStore
    private var timer: Timer?
    private var lastActivity = Date()
    private var cancellables = Set<AnyCancellable>()
    nonisolated private static let categoryID = "CHATGAUGE_UPDATES"
    private static let notifiedKey = "ChatGaugeNotifiedUpdates"

    var settings: ChatSettings { settingsStore.settings }
    var pending: [UpdateItem] { items.filter(\.needsUpdate) }
    static let brewCaskCommand = "brew upgrade --cask chatgauge"

    init(engine: ChatEngine, settingsStore: SettingsStore) {
        self.engine = engine
        self.settingsStore = settingsStore
        super.init()
        engine.$isStreaming.sink { [weak self] _ in self?.lastActivity = Date() }.store(in: &cancellables)
        engine.$draft.sink { [weak self] _ in self?.lastActivity = Date() }.store(in: &cancellables)
    }

    func start() {
        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            let c = UNUserNotificationCenter.current()
            c.delegate = self
            let update = UNNotificationAction(identifier: "UPDATE", title: "Update")
            let later = UNNotificationAction(identifier: "LATER", title: "Later")
            c.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: [update, later], intentIdentifiers: [])])
        }
        // First look a little after launch, then every 30 minutes see if a daily check is due.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if settings.checkForUpdates, UpdatePolicy.isDue(lastChecked: lastChecked), !isChecking {
            Task { await check(userInitiated: false) }
        } else {
            autoInstallIfIdle()
        }
    }

    var context: UpdatePolicy.Context {
        let resolve = NSWorkspace.shared.runningApplications.contains { ResolveWatch.isResolve(bundleID: $0.bundleIdentifier) }
        return .init(generating: engine.isStreaming, loading: engine.loadingSince != nil,
                     resolveOpen: resolve, idleFor: Date().timeIntervalSince(lastActivity))
    }

    // MARK: Checking

    func checkNow() { Task { await check(userInitiated: true) } }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        message = nil
        var found: [UpdateItem] = []
        found.append(await checkApp())
        if settings.checkTools { found += await checkTools() }
        if settings.checkModels { found += await checkModels() }
        items = found
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: "ChatGaugeLastUpdateCheck")
        isChecking = false
        if !userInitiated { notifyIfNew() }
        autoInstallIfIdle()
    }

    private func checkApp() async -> UpdateItem {
        let current = AppInfo.version
        var item = UpdateItem(kind: .app, name: "ChatGauge", installed: current, available: nil,
                              detail: "\(current) · \(BrewOutdated.isBrewInstalledCask("chatgauge") ? "brew cask" : "app")")
        do {
            let (data, resp) = try await URLSession.shared.data(for: ReleaseInfo.latestRequest(repo: AppInfo.repo))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { item.detail += " · no releases published yet"; return item }
            guard code == 200, let r = ReleaseInfo.parseLatest(data) else { item.detail += " · couldn't read the latest release"; return item }
            latestRelease = r
            if let mine = SemVer(current), r.version > mine { item.available = r.version.description }
        } catch {
            item.detail += " · offline"
        }
        return item
    }

    private func checkTools() async -> [UpdateItem] {
        guard let brew = BrewOutdated.brewPath() else { return [] }
        let installed = BrewOutdated.watched.filter { BrewOutdated.isBrewInstalled($0) }
        guard !installed.isEmpty else { return [] }
        let (status, out) = await Self.run(brew, ["outdated", "--json=v2", "--formula"], timeout: 120)
        guard status == 0 else { message = "Homebrew didn't answer; tools weren't checked."; return [] }
        let outdated = BrewOutdated.parse(out)
        return installed.map { name in
            let o = outdated.first { $0.name == name }
            return UpdateItem(kind: .tool, name: Self.toolTitle(name), installed: o?.installed ?? "installed",
                              available: o?.current,
                              detail: "Homebrew formula" + (name == "ollama" ? "" : " · optional"))
        }
    }

    private func checkModels() async -> [UpdateItem] {
        let place = engine.location.volumeName.map { "Models folder (\($0))" } ?? "Models folder"
        var out: [UpdateItem] = []
        for m in engine.models.prefix(12) {
            guard let req = ModelDigest.manifestRequest(for: m.name) else { continue }
            var item = UpdateItem(kind: .model, name: m.name, installed: String((m.digest ?? "").prefix(12)), available: nil, detail: place)
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                if ModelDigest.isNewer(local: m.digest, remoteManifest: data) { item.available = "new digest" }
            } else {
                item.detail += " · not in the Ollama library"
            }
            out.append(item)
        }
        return out
    }

    static func toolTitle(_ formula: String) -> String {
        switch formula {
        case "ollama": return "Ollama"
        case "whisper-cpp": return "whisper.cpp"
        default: return formula
        }
    }

    static func formula(forTitle t: String) -> String {
        switch t {
        case "Ollama": return "ollama"
        case "whisper.cpp": return "whisper-cpp"
        default: return t
        }
    }

    // MARK: Installing

    func install(_ item: UpdateItem) {
        if let why = UpdatePolicy.blockedReason(context) {
            message = "Waiting: \(why). Try again when it's done."
            return
        }
        switch item.kind {
        case .app:
            if let r = latestRelease { NSWorkspace.shared.open(r.url) } else { NSWorkspace.shared.open(AppInfo.releasesURL) }
            message = "Update ChatGauge with Homebrew: \(Self.brewCaskCommand), or download the zip from the release page."
        case .model:
            installing = item.name
            message = "Downloading the new \(item.name) with Ollama…"
            engine.pull(item.name)
            watchPull(item)
        case .tool:
            guard let brew = BrewOutdated.brewPath() else { return }
            let formula = Self.formula(forTitle: item.name)
            installing = item.name
            message = "Updating \(item.name) with Homebrew…"
            Task {
                let (status, _) = await Self.run(brew, ["upgrade", formula], timeout: 1800)
                installing = nil
                if status == 0 {
                    markDone(item)
                    message = formula == "ollama"
                        ? "Ollama updated. The running server keeps the old version until it restarts (quit and reopen Ollama, or log out and in). ChatGauge doesn't restart it for you."
                        : "\(item.name) updated."
                } else {
                    message = "Homebrew couldn't update \(item.name). Run `brew upgrade \(formula)` in Terminal to see why."
                }
            }
        }
    }

    func installAll() {
        for i in pending where i.kind != .app {
            if installing != nil && i.kind == .model { continue }
            install(i)
        }
        if pending.contains(where: { $0.kind == .app }), let app = pending.first(where: { $0.kind == .app }) { install(app) }
    }

    private func watchPull(_ item: UpdateItem) {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while engine.pullProgress != nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            installing = nil
            if engine.pullMessage?.contains("installed") == true { markDone(item); message = "\(item.name) is up to date." }
            else { message = engine.pullMessage }
        }
    }

    private func markDone(_ item: UpdateItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].available = nil }
    }

    private func autoInstallIfIdle() {
        guard installing == nil else { return }
        let c = context
        if let next = pending.first(where: { UpdatePolicy.shouldAutoInstall($0, mode: settings.updateMode, context: c) }) {
            install(next)
        }
    }

    // MARK: Notifications

    private func notifyIfNew() {
        let ids = pending.map(\.id).sorted()
        guard !ids.isEmpty else { return }
        let key = ids.joined(separator: "|") + "|" + pending.compactMap(\.available).joined(separator: "|")
        guard UserDefaults.standard.string(forKey: Self.notifiedKey) != key else { return }
        UserDefaults.standard.set(key, forKey: Self.notifiedKey)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let names = pending.map(\.name)
        let body = settings.updateMode == .autoWhenIdle
            ? "\(UpdatePolicy.summary(names)). Installs when you're not chatting."
            : "\(UpdatePolicy.summary(names)). Install when you're not chatting."
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "Updates available"
            content.body = body
            content.categoryIdentifier = UpdateCenter.categoryID
            c.add(UNNotificationRequest(identifier: "chatgauge-updates", content: content, trigger: nil))
        }
    }

    var openUpdatesTab: (() -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if action == "UPDATE" { self.installAll() }
                if action != "LATER" { self.openUpdatesTab?() }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    // MARK: Process

    nonisolated static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> (Int32, Data) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return (Int32(-1), Data()) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            return (p.terminationStatus, data)
        }.value
    }

    var diagnostics: [(String, String)] {
        [("Updates", settings.checkForUpdates ? "daily · \(settings.updateMode == .notify ? "notify" : "auto when idle")" : "off"),
         ("Last check", lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "never"),
         ("Pending", pending.isEmpty ? "none" : pending.map(\.name).joined(separator: ", "))]
    }
}

extension BrewOutdated {
    static func isBrewInstalledCask(_ cask: String, fm: FileManager = .default) -> Bool {
        ["/opt/homebrew/Caskroom/\(cask)", "/usr/local/Caskroom/\(cask)"].contains { fm.fileExists(atPath: $0) }
    }
}

// MARK: - Views

struct UpdatesPane: View {
    @ObservedObject var center: UpdateCenter
    @ObservedObject var store: SettingsStore
    var openWhatsNew: () -> Void
    private var s: ChatSettings { store.settings }

    var body: some View {
        PrefGroup(title: "Updates",
                  footer: "\(lastCheckedText) Checks are read-only; nothing installs until you choose Update.") {
            PrefToggle(label: "Check for updates daily", detail: "ChatGauge, Ollama, your models, whisper.cpp and ffmpeg if installed",
                       isOn: Binding(get: { s.checkForUpdates }, set: { v in store.update { $0.checkForUpdates = v } }))
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("When updates are found")
                Picker("", selection: Binding(get: { s.updateMode }, set: { v in store.update { $0.updateMode = v } })) {
                    HStack { Text(UpdateMode.notify.title); Text("Notification and a popover row. Nothing installs until you click Update.").font(.caption).foregroundStyle(.secondary) }
                        .tag(UpdateMode.notify)
                    HStack { Text(UpdateMode.autoWhenIdle.title); Text("Never while a chat is generating or Resolve is open").font(.caption).foregroundStyle(.secondary) }
                        .tag(UpdateMode.autoWhenIdle)
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            .padding(.vertical, 7)
            Divider()
            HStack(spacing: 18) {
                Toggle("Homebrew tools", isOn: Binding(get: { s.checkTools }, set: { v in store.update { $0.checkTools = v } }))
                Toggle("Model digests", isOn: Binding(get: { s.checkModels }, set: { v in store.update { $0.checkModels = v } }))
            }
            .padding(.vertical, 7)
        }

        PrefGroup(title: "Available",
                  footer: "After an Ollama upgrade the running server keeps the old version until it restarts; ChatGauge never force-restarts it or unloads models it didn't load.") {
            if center.items.isEmpty {
                PrefRow(label: center.isChecking ? "Checking…" : "Not checked yet") { EmptyView() }
            }
            ForEach(Array(center.items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider() }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        Text(item.kind == .model ? item.detail : (item.kind == .app ? item.detail : "\(item.installed) · \(item.detail)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 300, alignment: .leading)
                    Text(availableText(item)).foregroundStyle(.secondary)
                    Spacer()
                    if center.installing == item.name {
                        ProgressView().controlSize(.small)
                    } else if item.needsUpdate {
                        Button("Update") { center.install(item) }.buttonStyle(.borderedProminent)
                    } else {
                        Text("Up to date").foregroundStyle(Palette.green)
                    }
                }
                .padding(.vertical, 7)
            }
        } accessory: {
            HStack {
                if center.isChecking { ProgressView().controlSize(.small) }
                Button("Check Now") { center.checkNow() }.disabled(center.isChecking)
                Button("What's New") { openWhatsNew() }
                Button("Update All") { center.installAll() }.buttonStyle(.borderedProminent).disabled(center.pending.isEmpty)
            }
        }
        if let m = center.message {
            Text(.init(m)).font(.caption).foregroundStyle(Palette.orange).fixedSize(horizontal: false, vertical: true)
        }
        if center.pending.contains(where: { $0.kind == .app }) {
            HStack {
                Text(UpdateCenter.brewCaskCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UpdateCenter.brewCaskCommand, forType: .string)
                }
            }
        }
    }

    private func availableText(_ i: UpdateItem) -> String {
        guard let a = i.available else { return "—" }
        switch i.kind {
        case .app: return "version \(a)"
        case .tool: return "version \(a)"
        case .model: return a
        }
    }

    private var lastCheckedText: String {
        guard let d = center.lastChecked else { return "Not checked yet." }
        return "Last checked \(d.formatted(date: .abbreviated, time: .shortened))."
    }
}

struct AboutUpdatesRow: View {
    @ObservedObject var center: UpdateCenter
    var body: some View {
        PrefRow(label: headline, detail: center.lastChecked.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" }) {
            if center.isChecking { ProgressView().controlSize(.small) }
            Button("Check Now") { center.checkNow() }.disabled(center.isChecking)
        }
    }
    private var headline: String {
        if let a = center.items.first(where: { $0.kind == .app && $0.needsUpdate })?.available { return "Version \(a) is available" }
        return center.lastChecked == nil ? "Not checked yet" : "ChatGauge is up to date"
    }
}

/// The popover row when something can be updated.
struct UpdatesPopoverRow: View {
    @ObservedObject var center: UpdateCenter
    var openDetails: () -> Void
    var body: some View {
        if !center.pending.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Updates available").font(.system(size: 12, weight: .semibold))
                    Text(UpdatePolicy.summary(center.pending.map(\.name))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if center.installing != nil { ProgressView().controlSize(.small) }
                Button("Details") { openDetails() }.controlSize(.small)
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

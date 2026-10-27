import AppKit
import ChatGaugeCore
import Combine
import UniformTypeIdentifiers

/// Per-Mac settings in ~/Library/Application Support/ChatGauge/settings.json. No sync; Export/Import moves them.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: ChatSettings {
        didSet {
            guard !applying, !settings.sameContent(as: oldValue) else { return }
            settings.modifiedAt = Date()
            scheduleSave()
        }
    }
    @Published var lastMessage: String?
    /// True on the very first launch on this Mac (no settings file yet).
    let firstLaunch: Bool

    private let url: URL
    private var applying = false
    private var saveWork: DispatchWorkItem?

    init(url: URL = AppPaths.settingsFile()) {
        self.url = url
        firstLaunch = !FileManager.default.fileExists(atPath: url.path)
        settings = SettingsFile.load(from: url)
    }

    /// First launch: if a LaunchAgent already serves Ollama from a folder (e.g. an external drive), use that folder.
    func adoptServerFolderIfFirstLaunch(agents: [OllamaAgent]) {
        guard firstLaunch, let path = agents.first(where: { $0.modelsPath != nil })?.modelsPath else { return }
        var s = settings
        let local = ModelsLocation.defaultLocal()
        if (path as NSString).standardizingPath != (local as NSString).standardizingPath {
            s.modelsLocation = .external
            s.modelsPath = path
            settings = s
        }
    }

    func update(_ change: (inout ChatSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        try? SettingsFile.save(settings, to: url)
    }

    // MARK: Export / Import

    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ChatGauge Settings.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try SettingsFile.encode(settings).write(to: dest, options: .atomic)
            lastMessage = "Exported to \(dest.lastPathComponent)."
        } catch {
            lastMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            let s = try SettingsFile.decode(try Data(contentsOf: src))
            settings = s
            saveNow()
            lastMessage = "Imported \(src.lastPathComponent)."
        } catch let e as SettingsFileError {
            lastMessage = e.description
        } catch {
            lastMessage = "Couldn't read that file."
        }
    }

    func resetToDefaults() {
        settings = ChatSettings()
        saveNow()
        lastMessage = "Settings reset to defaults."
    }
}

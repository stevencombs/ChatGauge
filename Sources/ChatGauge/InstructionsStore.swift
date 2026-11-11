import AppKit
import ChatGaugeCore
import Combine

/// The saved instructions (instructions.json) and the editor's working copy.
@MainActor
final class InstructionsStore: ObservableObject {
    @Published private(set) var file: InstructionsFile
    /// The editor edits this; Save writes it, Revert throws it away.
    @Published var draft: InstructionsFile
    @Published var message: String?
    let url: URL

    init(url: URL = AppPaths.instructionsFile()) {
        self.url = url
        let f = InstructionsFile.load(from: url)
        file = f
        draft = f
    }

    var hasChanges: Bool { draft.normalized() != file.normalized() }

    func save() {
        var f = draft.normalized()
        f.updatedAt = Date()
        do {
            try f.save(to: url)
            file = f
            draft = f
            message = "Saved"
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func revert() {
        draft = file
        message = nil
    }

    /// Switch preset from the popover (saves right away; leaves other unsaved edits in the draft alone).
    func activate(_ id: UUID) {
        var f = file
        f.activePresetID = id
        f.updatedAt = Date()
        try? f.save(to: url)
        file = f.normalized()
        draft.activePresetID = id
    }

    func setEnabled(_ on: Bool) {
        var f = file
        f.enabled = on
        try? f.save(to: url)
        file = f.normalized()
        draft.enabled = on
    }

    // MARK: Draft editing helpers

    var activeIndex: Int? { draft.presets.firstIndex { $0.id == draft.activePresetID } ?? (draft.presets.isEmpty ? nil : 0) }

    /// nil = the default instructions used when a model has no override.
    @Published var selectedModel: String? = nil

    var standing: String {
        get { draft.standing(for: selectedModel) }
        set { draft.setStanding(newValue, for: selectedModel) }
    }

    var glossaryText: String {
        get { draft.glossary.joined(separator: "\n") }
        set { draft.glossary = newValue.components(separatedBy: "\n") }
    }

    func newPreset(named name: String) {
        guard draft.presets.count < InstructionLimits.presets else {
            message = "Up to \(InstructionLimits.presets) presets."
            return
        }
        let p = InstructionPreset(name: name.isEmpty ? "New preset" : name, standing: "")
        draft.presets.append(p)
        draft.activePresetID = p.id
        draft = draft.normalized()
    }

    func renameActive(to name: String) {
        guard let i = activeIndex else { return }
        draft.presets[i].name = name
        draft = draft.normalized()
    }

    func deleteActive() {
        guard let i = activeIndex, draft.presets.count > 1 else { return }
        draft.presets.remove(at: i)
        draft.activePresetID = draft.presets.first?.id
    }

    /// Dry-run for the one-time, read-only ClipGauge glossary import (OT-100).
    func glossaryImportPlan(location: ModelsLocation) -> ClipGaugeImport.Plan? {
        let src = location.clipGaugeInstructions
        guard let data = FileManager.default.contents(atPath: src.path) else {
            message = "No ClipGauge instructions found at \(src.path)."
            return nil
        }
        guard let found = ClipGaugeImport.read(data) else {
            message = "ClipGauge's instructions have no glossary to import."
            return nil
        }
        return ClipGaugeImport.plan(existing: draft.glossary, imported: found.glossary,
                                    alreadyImported: draft.clipGaugeGlossaryImported, sourcePath: src.path)
    }

    func applyGlossaryImport(_ plan: ClipGaugeImport.Plan) {
        let next = ClipGaugeImport.apply(draft, plan: plan)
        if next == draft {
            message = plan.alreadyImported ? "The ClipGauge glossary was already imported once." : "Nothing new to import."
            return
        }
        draft = next
        message = "Imported \(plan.termsToAdd.count) new term(s) from ClipGauge. Click Save to keep them. ClipGauge's file was not changed."
    }

    static func clipGaugeAvailable(_ location: ModelsLocation) -> Bool {
        FileManager.default.fileExists(atPath: location.clipGaugeInstructions.path)
    }
}

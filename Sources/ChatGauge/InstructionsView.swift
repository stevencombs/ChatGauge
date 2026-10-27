import AppKit
import ChatGaugeCore
import SwiftUI

/// The Instructions editor (its own window, and the Settings › Instructions tab).
struct InstructionsEditor: View {
    @ObservedObject var store: InstructionsStore
    var location: ModelsLocation
    @ViewState private var showPreview = false
    @ViewState private var naming: NameSheet?

    enum NameSheet: Identifiable {
        case new, rename
        var id: Int { self == .new ? 0 : 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preset").font(.headline)
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active preset")
                        Text("Switch presets from the popover too").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { store.draft.activePresetID ?? UUID() },
                                                  set: { store.draft.activePresetID = $0 })) {
                        ForEach(store.draft.presets) { p in Text(p.name).tag(p.id) }
                    }
                    .labelsHidden().frame(width: 180)
                    Button("New…") { naming = .new }
                    Button("Rename") { naming = .rename }
                    Button {
                        store.deleteActive()
                    } label: { Image(systemName: "trash") }
                        .disabled(store.draft.presets.count <= 1).help("Delete this preset")
                }
                .padding(4)
            }
            HStack {
                Toggle("Send instructions with every chat", isOn: Binding(get: { store.draft.enabled }, set: { store.draft.enabled = $0 }))
                Spacer()
                Text("Presets: " + store.draft.presets.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Text("Standing instructions (system prompt)").font(.headline).padding(.top, 4)
            TextEditor(text: Binding(get: { store.standing }, set: { store.standing = $0 }))
                .font(.body)
                .frame(minHeight: 120, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            HStack {
                Text("Sent as the system message on every chat that uses this preset.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let n = store.standing.count
                Text("\(n.formatted()) / \(InstructionLimits.standingChars.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(n >= InstructionLimits.standingChars ? Palette.color(.problem) : n > InstructionLimits.standingChars * 9 / 10 ? Palette.color(.busy) : .secondary)
            }

            Text("Glossary").font(.headline).padding(.top, 4)
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Words to spell exactly")
                        Text("One per line. Added to the instructions and to Whisper's prompt for voice input.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import from ClipGauge…") { store.importFromClipGauge(location: location) }
                        .disabled(!InstructionsStore.clipGaugeAvailable(location))
                        .help(InstructionsStore.clipGaugeAvailable(location) ? "Adds ClipGauge's glossary terms (ClipGauge's file is not changed)" : "No ClipGauge instructions found next to the models folder")
                }
                .padding(4)
            }
            TextEditor(text: Binding(get: { store.glossaryText }, set: { store.glossaryText = $0 }))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            HStack {
                let terms = InstructionText.parseGlossary(store.draft.glossary)
                Text("\(terms.count) of \(InstructionLimits.glossaryTerms) terms · \(InstructionText.glossaryLength(terms)) / \(InstructionLimits.glossaryChars) characters (each term up to \(InstructionLimits.glossaryTermChars))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Button { showPreview = true } label: { Label("Preview Prompt", systemImage: "magnifyingglass") }
                if let m = store.message {
                    Label(m, systemImage: m == "Saved" ? "checkmark.circle.fill" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(m == "Saved" ? Palette.color(.ok) : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Revert") { store.revert() }.disabled(!store.hasChanges)
                Button("Save") { store.save() }.keyboardShortcut("s", modifiers: .command).disabled(!store.hasChanges)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showPreview) { PromptPreview(file: store.draft.normalized()) }
        .sheet(item: $naming) { kind in
            NamePrompt(title: kind == .new ? "New preset" : "Rename preset",
                       initial: kind == .new ? "" : (store.activeIndex.map { store.draft.presets[$0].name } ?? "")) { name in
                if kind == .new { store.newPreset(named: name) } else { store.renameActive(to: name) }
            }
        }
        .onChange(of: store.draft) { _, _ in if store.message == "Saved" { store.message = nil } }
    }
}

struct PromptPreview: View {
    var file: InstructionsFile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What ChatGauge sends").font(.headline)
            Text("This is the system message at the start of every chat with “\(file.active?.name ?? "")”.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(file.systemPrompt() ?? "(No system message: instructions are off or empty.)")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            if let w = file.whisperPrompt() {
                Text("Whisper prompt (voice input): \(w)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 520, height: 380)
    }
}

struct NamePrompt: View {
    var title: String
    var initial: String
    var onDone: (String) -> Void
    @ViewState private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name).frame(width: 280).onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: done).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear { name = initial }
    }
    private func done() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onDone(n)
        dismiss()
    }
}

/// The popover's instructions line becomes a quick preset switcher.
struct PresetMenu: View {
    @ObservedObject var store: InstructionsStore
    var openEditor: () -> Void
    var body: some View {
        Menu {
            ForEach(store.file.presets) { p in
                Button((store.file.enabled && p.id == store.file.active?.id ? "✓ " : "") + p.name) {
                    store.activate(p.id)
                    if !store.file.enabled { store.setEnabled(true) }
                }
            }
            Divider()
            Button(store.file.enabled ? "Turn Instructions Off" : "Turn Instructions On") { store.setEnabled(!store.file.enabled) }
            Button("Edit Instructions…", action: openEditor)
        } label: {
            Text("Instructions: \(store.file.summary)").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch the instructions preset")
    }
}

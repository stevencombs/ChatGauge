import AppKit
import ChatGaugeCore
import SwiftUI

/// The Instructions editor (its own window, and the Settings › Instructions tab).
struct InstructionsEditor: View {
    @ObservedObject var store: InstructionsStore
    var location: ModelsLocation
    var models: [String] = []
    @ViewState private var showPreview = false
    @ViewState private var importPlan: ClipGaugeImport.Plan?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Instructions for each model").font(.headline)
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model")
                        Text("Each installed model has its own instructions, used for every chat on that model.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { store.selectedModel ?? "" },
                                                  set: { store.selectedModel = $0.isEmpty ? nil : $0 })) {
                        Text("Default (models without their own text)").tag("")
                        ForEach(models, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden().frame(width: 260)
                }
                .padding(4)
            }
            HStack {
                Toggle("Send instructions with every chat", isOn: Binding(get: { store.draft.enabled }, set: { store.draft.enabled = $0 }))
                Spacer()
                Text(store.draft.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                Text(store.selectedModel == nil
                     ? "Sent as the system message when a model has no instructions of its own."
                     : "Sent as the system message on every chat that uses \(store.selectedModel ?? "").")
                    .font(.caption).foregroundStyle(.secondary)
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
                    Button("Import ClipGauge glossary…") {
                        importPlan = store.glossaryImportPlan(location: location)
                    }
                    .disabled(!InstructionsStore.clipGaugeAvailable(location) || store.draft.clipGaugeGlossaryImported)
                    .help(importHelp)
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
                    Label(m, systemImage: m.hasPrefix("Imported") || m == "Saved" ? "checkmark.circle.fill" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(m == "Saved" || m.hasPrefix("Imported") ? Palette.color(.ok) : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Revert") { store.revert() }.disabled(!store.hasChanges)
                Button("Save") { store.save() }.keyboardShortcut("s", modifiers: .command).disabled(!store.hasChanges)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showPreview) {
            PromptPreview(file: store.draft.normalized(), model: store.selectedModel)
        }
        .sheet(item: Binding(
            get: { importPlan.map { ImportPlanSheet(plan: $0) } },
            set: { importPlan = $0?.plan }
        )) { sheet in
            ImportDryRun(plan: sheet.plan, onImport: {
                store.applyGlossaryImport(sheet.plan)
                importPlan = nil
            }, onCancel: { importPlan = nil })
        }
        .onChange(of: store.draft) { _, _ in if store.message == "Saved" { store.message = nil } }
    }

    private var importHelp: String {
        if store.draft.clipGaugeGlossaryImported { return "The ClipGauge glossary was already imported once." }
        if InstructionsStore.clipGaugeAvailable(location) { return "Shows a dry run first. ClipGauge's file is not changed." }
        return "No ClipGauge instructions found next to the models folder"
    }
}

private struct ImportPlanSheet: Identifiable {
    var plan: ClipGaugeImport.Plan
    var id: String { plan.sourcePath }
}

private struct ImportDryRun: View {
    var plan: ClipGaugeImport.Plan
    var onImport: () -> Void
    var onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import ClipGauge glossary?").font(.headline)
            Text("This is a read-only, one-time import. Nothing is written to ClipGauge.").font(.caption).foregroundStyle(.secondary)
            ForEach(plan.lines, id: \.self) { line in
                Text(line).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Import", action: onImport).keyboardShortcut(.defaultAction)
                    .disabled(!plan.canApply)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}

struct PromptPreview: View {
    var file: InstructionsFile
    var model: String? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What ChatGauge sends").font(.headline)
            Text(model == nil
                 ? "This is the system message for models that use the default instructions."
                 : "This is the system message at the start of every chat with \(model ?? "").")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(file.systemPrompt(for: model) ?? "(No system message: instructions are off or empty.)")
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

/// The popover's instructions line opens the editor. Per-model text lives in Settings.
struct PresetMenu: View {
    @ObservedObject var store: InstructionsStore
    var openEditor: () -> Void

    var body: some View {
        Menu {
            Button(store.file.enabled ? "Instructions on" : "Instructions off") {
                store.setEnabled(!store.file.enabled)
            }
            Button("Edit instructions…", action: openEditor)
        } label: {
            Image(systemName: "text.alignleft")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.file.enabled ? "Instructions: per model" : "Instructions are off")
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
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        onDone(n)
        dismiss()
    }
}

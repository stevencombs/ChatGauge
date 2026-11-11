import AppKit
import ChatGaugeCore
import Foundation

/// Downloads optional image models. The default stub never touches the network.
protocol ImageDownloading: AnyObject {
    func install(_ entry: ImageModelEntry, into folder: URL, progress: @escaping @MainActor (Double, String) -> Void) async throws
    func cancel()
}

/// Runs an mflux generate command. The default stub never launches mflux.
protocol ImageExecuting: AnyObject {
    func run(_ command: ImageGenerate.Command, progress: @escaping @MainActor (Double, String) -> Void) async throws -> Data
    func cancel()
}

/// Creates the destination folder and a `.installed` marker. Used in tests and UI self-test.
final class StubImageDownloader: ImageDownloading {
    var cancelled = false
    var installed: [String] = []
    /// When true, the stub still writes nothing to a real models drive (it only writes under the given folder).
    func install(_ entry: ImageModelEntry, into folder: URL, progress: @escaping @MainActor (Double, String) -> Void) async throws {
        cancelled = false
        let dest = ImageCatalog.installDestination(entry, in: folder)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for step in [0.15, 0.4, 0.7, 1.0] {
            if cancelled { throw CancellationError() }
            await progress(step, "Installing \(entry.title)…")
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        try Data("stub\n".utf8).write(to: dest.appendingPathComponent(".installed"))
        installed.append(entry.id)
    }

    func cancel() { cancelled = true }
}

/// Returns a 1×1 PNG and writes it to `command.output`. Never launches mflux.
final class StubImageExecutor: ImageExecuting {
    var cancelled = false
    var lastCommand: ImageGenerate.Command?
    static let png: Data = {
        // 1×1 PNG
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+XWdkAAAAASUVORK5CYII="
        return Data(base64Encoded: b64) ?? Data()
    }()

    func run(_ command: ImageGenerate.Command, progress: @escaping @MainActor (Double, String) -> Void) async throws -> Data {
        cancelled = false
        lastCommand = command
        for step in [0.2, 0.55, 1.0] {
            if cancelled { throw CancellationError() }
            await progress(step, "Generating…")
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        try FileManager.default.createDirectory(at: command.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StubImageExecutor.png.write(to: command.output)
        return StubImageExecutor.png
    }

    func cancel() { cancelled = true }
}

enum ChatComposerMode: String, Equatable, Sendable {
    case chat, image
}

extension ChatEngine {
    /// Refresh which optional image models are on the models drive (not Ollama).
    func refreshImageModels() {
        let folder = imageModelsFolder
        imageInstalled = Set(ImageCatalog.all.filter { ImageCatalog.isInstalled($0, in: folder) }.map(\.id))
        if mfluxPathOverride != nil {
            mfluxInstalled = mfluxPathOverride != nil
        } else if let ev = ProcessInfo.processInfo.environment["CHATGAUGE_STUB_MFLUX"], !ev.isEmpty {
            mfluxInstalled = true
        } else {
            mfluxInstalled = Self.which(MfluxInstall.generateFlux2) != nil
        }
    }

    static func which(_ exe: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let c = (dir as NSString).appendingPathComponent(exe)
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    var canSendImage: Bool {
        !isGeneratingImage && !isStreaming
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func generateImage() {
        guard composerMode == .image, canSendImage else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ImageCatalog.isVisible(imageModelID) { imageModelID = ImageCatalog.klein4b.id }
        guard let entry = ImageCatalog.entry(imageModelID), ImageCatalog.isVisible(entry.id) else { return }
        switch location.availability() {
        case .driveMissing(let v):
            imageMessage = ImageGenerateError.driveMissing(v).description
            return
        case .notChosen, .folderMissing:
            imageMessage = "The models folder isn’t ready."
            return
        case .ready: break
        }
        refreshImageModels()
        if !mfluxInstalled, mfluxPathOverride == nil {
            imageMessage = ImageGenerateError.mfluxMissing.description
            return
        }
        let needed = entry.uncensored ? (entry.pairsWith ?? ImageCatalog.klein4b.id) : entry.id
        if entry.kind == .textEncoder || (entry.uncensored && imageModelID == entry.id) {
            if !imageInstalled.contains(ImageCatalog.klein4b.id) {
                imageMessage = ImageGenerateError.modelNotInstalled(ImageCatalog.klein4b.title).description
                return
            }
            if !imageInstalled.contains(ImageCatalog.kleinUncensoredEncoder.id) {
                imageMessage = ImageGenerateError.encoderNotInstalled.description
                return
            }
        } else if !imageInstalled.contains(needed) && !imageInstalled.contains(entry.id) {
            imageMessage = ImageGenerateError.modelNotInstalled(entry.title).description
            return
        }
        let out = ImageGenerate.outputURL(in: imagesOutputFolder, model: entry.id, prompt: text)
        let exe = mfluxPathOverride ?? Self.which(entry.command) ?? entry.command
        let result = ImageGenerate.command(
            entry: entry,
            prompt: text,
            output: out,
            modelsFolder: imageModelsFolder,
            mflux: exe,
            uncensored: entry.uncensored,
            uncensoredLoadable: uncensoredLoadable
        )
        switch result {
        case .failure(let err):
            imageMessage = err.description
            return
        case .success(let cmd):
            if conversation.isEmpty {
                conversation.title = Conversation.makeTitle(from: text, hasImage: true)
                conversation.instructions = instructionsName()
            }
            conversation.messages.append(ChatMessage(role: .user, text: text))
            let reply = ChatMessage(role: .assistant, text: "", model: entry.title)
            conversation.messages.append(reply)
            conversation.updatedAt = Date()
            draft = ""
            isGeneratingImage = true
            imageProgress = 0
            imageMessage = "Generating…"
            let replyID = reply.id
            imageTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await self.imageExecutor.run(cmd) { p, msg in
                        self.imageProgress = p
                        self.imageMessage = msg
                    }
                    if Task.isCancelled { throw CancellationError() }
                    if let i = self.conversation.messages.lastIndex(where: { $0.id == replyID }) {
                        self.conversation.messages[i].text = "Saved to \(cmd.output.path)"
                        self.conversation.messages[i].images = [data]
                    }
                    self.imageMessage = "Saved to \(cmd.output.lastPathComponent)"
                } catch is CancellationError {
                    if let i = self.conversation.messages.lastIndex(where: { $0.id == replyID }) {
                        self.conversation.messages[i].error = "Stopped."
                    }
                    self.imageMessage = "Stopped."
                } catch {
                    if let i = self.conversation.messages.lastIndex(where: { $0.id == replyID }) {
                        self.conversation.messages[i].error = error.localizedDescription
                    }
                    self.imageMessage = error.localizedDescription
                }
                self.isGeneratingImage = false
                self.imageProgress = nil
                self.imageTask = nil
                self.conversation.updatedAt = Date()
                self.onConversationUpdated?(self.conversation)
            }
        }
    }

    func cancelImage() {
        imageExecutor.cancel()
        imageTask?.cancel()
    }

    func installImageModel(_ id: String) {
        guard let entry = ImageCatalog.entry(id), ImageCatalog.isVisible(id), imagePullTarget == nil else { return }
        let folder = imageModelsFolder
        imagePullTarget = id
        imagePullProgress = 0
        imagePullMessage = "Starting…"
        imageInstallTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.imageDownloader.install(entry, into: folder) { p, msg in
                    self.imagePullProgress = p
                    self.imagePullMessage = msg
                }
                self.refreshImageModels()
                self.imagePullMessage = "Installed \(entry.title)."
            } catch is CancellationError {
                self.imagePullMessage = "Cancelled."
            } catch {
                self.imagePullMessage = error.localizedDescription
            }
            self.imagePullProgress = nil
            self.imagePullTarget = nil
            self.imageInstallTask = nil
        }
    }

    func cancelImageInstall() {
        imageDownloader.cancel()
        imageInstallTask?.cancel()
    }

    func removeImageModel(_ id: String) -> String? {
        guard let entry = ImageCatalog.entry(id), ImageCatalog.isVisible(id) else { return "Unknown model." }
        let dest = ImageCatalog.installDestination(entry, in: imageModelsFolder)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            refreshImageModels()
            let plan = ImageRemoval.plan(entry, folder: imageModelsFolder)
            return "Removed \(entry.title). Freed about \(plan.freeLabel)."
        } catch {
            return "Couldn't remove \(entry.title): \(error.localizedDescription)"
        }
    }
}

import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct ImageCatalogTests {
    @Test func catalogSizesAndLicenses() {
        #expect(ImageCatalog.klein4b.repo == "mflux-community/flux2-klein-4b-mflux-q4")
        #expect(ImageCatalog.klein4b.bytes == 4_619_704_206)
        #expect(ImageCatalog.klein4b.license == "Apache 2.0")
        #expect(ImageCatalog.zImageTurbo.repo == "mflux-community/z-image-turbo-mflux-q4")
        #expect(ImageCatalog.zImageTurbo.bytes == 5_902_988_435)
        #expect(ImageCatalog.kleinUncensoredEncoder.repo == "ponpoke/flux2-klein-4b-uncensored-text-encoder")
        #expect(ImageCatalog.kleinUncensoredEncoder.bytes == 8_056_410_867)
        #expect(ImageCatalog.kleinUncensoredEncoder.uncensored)
        #expect(ImageCatalog.kleinUncensoredEncoder.kind == .textEncoder)
        #expect(ImageCatalog.all.count == 3)
        #expect(!ImageCatalog.standard.contains(where: { $0.uncensored }))
    }

    @Test func ramSuggestionPrefersKlein() {
        let sixteen = UInt64(16) * 1_073_741_824
        let thirtyTwo = UInt64(32) * 1_073_741_824
        let sixtyFour = UInt64(64) * 1_073_741_824
        #expect(ImageCatalog.suggested(memBytes: sixteen).id == ImageCatalog.klein4b.id)
        #expect(ImageCatalog.suggested(memBytes: thirtyTwo).id == ImageCatalog.klein4b.id)
        #expect(ImageCatalog.suggested(memBytes: sixtyFour).id == ImageCatalog.klein4b.id)
        let low = ImageCatalog.suggestionLabel(memBytes: sixteen)
        #expect(low.contains("16 GB"))
        #expect(low.contains("FLUX.2 Klein 4B"))
        #expect(ImageCatalog.suggestionLabel(memBytes: thirtyTwo).contains("Z-Image Turbo"))
    }

    @Test func installAndRemoveDryRun() {
        let folder = URL(fileURLWithPath: "/Volumes/Models/mflux-models", isDirectory: true)
        let plan = ImageCatalog.installPlan(ImageCatalog.klein4b, into: folder)
        #expect(plan.contains { $0.contains("mflux-community/flux2-klein-4b-mflux-q4") })
        #expect(plan.contains { $0.contains("4.6") || $0.lowercased().contains("gb") || $0.contains("license: Apache 2.0") })
        let un = ImageCatalog.installPlan(ImageCatalog.kleinUncensoredEncoder, into: folder)
        #expect(un.contains { $0.contains("ponpoke/flux2-klein-4b-uncensored-text-encoder") })
        #expect(un.contains { $0.contains("will not silently use the official encoder") })
        #expect(un.contains { $0.contains("flux-non-commercial-v2.1") || $0.contains("gated") })
        let removal = ImageRemoval.plan(ImageCatalog.zImageTurbo, folder: folder)
        #expect(removal.lines.contains { $0.contains("z-image-turbo-mflux-q4") })
        #expect(removal.warning?.contains("does not touch Ollama") == true)
        #expect(removal.bytes == ImageCatalog.zImageTurbo.bytes)
        #expect(!removal.path.contains("blobs"))
    }

    @Test func mfluxInstallIsClickOnlyDryRun() {
        let missingUV = MfluxInstall.plan(brew: "/opt/homebrew/bin/brew", uv: nil)
        #expect(missingUV.contains { $0.contains("brew") && $0.contains("install uv") })
        #expect(missingUV.contains { $0.contains("tool install mflux") })
        let haveUV = MfluxInstall.plan(brew: "/opt/homebrew/bin/brew", uv: "/opt/homebrew/bin/uv")
        #expect(!haveUV.contains { $0.contains("install uv") && !$0.contains("tool") })
        #expect(haveUV.contains { $0.contains("/opt/homebrew/bin/uv") && $0.contains("tool install mflux") })
    }

    @Test func generateCommandUsesLocalModelAndNotOllama() {
        let models = URL(fileURLWithPath: "/Volumes/Models/mflux-models")
        let out = URL(fileURLWithPath: "/Volumes/Models/ChatGauge Images/out.png")
        let r = ImageGenerate.command(
            entry: ImageCatalog.klein4b,
            prompt: "a red bicycle",
            output: out,
            modelsFolder: models,
            mflux: "/tmp/fake-mflux-generate-flux2"
        )
        guard case .success(let cmd) = r else {
            Issue.record("expected success")
            return
        }
        #expect(cmd.executable.hasSuffix("mflux-generate-flux2") || cmd.executable == "/tmp/fake-mflux-generate-flux2")
        #expect(cmd.arguments.contains("--model"))
        #expect(cmd.arguments.contains { $0.contains("flux2-klein-4b-mflux-q4") })
        #expect(cmd.arguments.contains("flux2-klein-4b"))
        #expect(cmd.arguments.contains("a red bicycle"))
        #expect(!cmd.display.contains("ollama"))
        #expect(!cmd.display.contains("/api/"))
    }

    @Test func uncensoredDoesNotFallBackToOfficialEncoder() {
        let models = URL(fileURLWithPath: "/Volumes/Models/mflux-models")
        let out = URL(fileURLWithPath: "/Volumes/Models/ChatGauge Images/out.png")
        let blocked = ImageGenerate.command(
            entry: ImageCatalog.klein4b,
            prompt: "a cat",
            output: out,
            modelsFolder: models,
            mflux: "/tmp/fake-mflux",
            uncensored: true,
            uncensoredLoadable: false
        )
        #expect(blocked == .failure(.uncensoredNotLoadable))
        if case .failure(let err) = blocked {
            #expect(err.description.contains("will not silently use the official encoder"))
        }
        let ok = ImageGenerate.command(
            entry: ImageCatalog.kleinUncensoredEncoder,
            prompt: "a cat",
            output: out,
            modelsFolder: models,
            mflux: "/tmp/fake-mflux",
            uncensoredLoadable: true
        )
        guard case .success(let cmd) = ok else {
            Issue.record("expected loadable uncensored command")
            return
        }
        #expect(cmd.arguments.contains { $0.contains("uncensored-text-encoder") })
        #expect(!cmd.arguments.contains { $0.hasSuffix("flux2-klein-4b-mflux-q4") })
    }

    @Test func emptyPromptAndSlug() {
        let models = URL(fileURLWithPath: "/tmp/mflux-models")
        let out = URL(fileURLWithPath: "/tmp/out.png")
        let r = ImageGenerate.command(entry: ImageCatalog.klein4b, prompt: "   ", output: out, modelsFolder: models, mflux: "mflux")
        #expect(r == .failure(.emptyPrompt))
        #expect(ImageGenerate.slugify("A Red Bicycle!!") == "a-red-bicycle")
        let url = ImageGenerate.outputURL(in: URL(fileURLWithPath: "/tmp/ChatGauge Images"), model: "flux2-klein-4b", prompt: "Hello", seed: 7)
        #expect(url.lastPathComponent.contains("flux2-klein-4b"))
        #expect(url.lastPathComponent.contains("hello"))
        #expect(url.lastPathComponent.hasSuffix("-7.png"))
    }

    @Test func isInstalledLooksAtImageFolderNotOllama() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cg-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = ImageCatalog.installDestination(ImageCatalog.klein4b, in: dir)
        #expect(!ImageCatalog.isInstalled(ImageCatalog.klein4b, in: dir))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: dest.appendingPathComponent("0.safetensors"))
        #expect(ImageCatalog.isInstalled(ImageCatalog.klein4b, in: dir))
    }
}

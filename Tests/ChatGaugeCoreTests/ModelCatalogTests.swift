import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct ModelCatalogTests {
    @Test func catalogBlurbs() {
        #expect(ModelCatalog.entry("qwen2.5vl:7b")?.blurb.contains("Standard vision") == true)
        #expect(ModelCatalog.entry("qwen2.5vl:32b")?.blurb.contains("21 GB") == true)
        #expect(ModelCatalog.uncensored.count == 2)
        #expect(ModelCatalog.entry("huihui_ai/qwen2.5-vl-abliterated:7b")?.uncensored == true)
        #expect(ModelCatalog.entry("huihui_ai/qwen3-vl-abliterated:8b-instruct")?.bytes == 6_100_000_000)
    }

    @Test func plainDescriptionForUnknown() {
        let vision = ModelInfo(name: "someone/custom-vl:4b", capabilities: ["vision", "completion"])
        let text = ModelInfo(name: "llama3.2:3b", capabilities: ["completion"])
        #expect(ModelCatalog.description(for: vision) == "vision")
        #expect(ModelCatalog.description(for: text) == "text")
        #expect(ModelCatalog.description(name: "llava:7b") == "vision")
        #expect(ModelCatalog.description(name: "mistral:7b") == "text")
    }

    @Test func menuRowsInstalledThenInstallable() {
        let installed = [ModelInfo(name: "qwen2.5vl:7b", size: 6_000_000_000, capabilities: ["vision"])]
        let rows = ModelCatalog.menuRows(installed: installed)
        #expect(rows.first?.name == "qwen2.5vl:7b")
        #expect(rows.first?.isInstalled == true)
        #expect(rows.contains { !$0.isInstalled && $0.name.contains("abliterated") })
        #expect(rows.filter(\.isInstalled).count == 1)
    }

    @Test func pullPlanDryRun() {
        let lines = ModelCatalog.pullPlan(model: "qwen2.5vl:7b", serverURL: "http://127.0.0.1:11434")
        #expect(lines == [#"POST http://127.0.0.1:11434/api/pull {"model":"qwen2.5vl:7b"}"#])
    }

    @Test func removalUnloadWhenOurs() {
        let p = ModelRemoval.plan(model: "qwen2.5vl:7b", size: 6_000_000_000,
                                  loaded: ["qwen2.5vl:7b"], mine: ["qwen2.5vl:7b"],
                                  streamingModel: nil, chatCount: 2, serverURL: "http://127.0.0.1:11434/")
        #expect(p.unloadFirst)
        #expect(p.block == nil)
        #expect(p.lines[0].contains("Unload"))
        #expect(p.lines[1].contains("DELETE http://127.0.0.1:11434/api/delete"))
        #expect(p.warning?.contains("2 saved chats") == true)
        #expect(p.freeLabel.contains("GB") || p.freeLabel.contains("MB") || p.freeLabel.contains("byte"))
    }

    @Test func removalBlockedWhileStreamingOrForeignLoad() {
        let stream = ModelRemoval.plan(model: "a", size: 1, loaded: ["a"], mine: ["a"],
                                       streamingModel: "a", chatCount: 0, serverURL: "http://127.0.0.1:11434")
        #expect(stream.block == .streaming)
        #expect(!stream.unloadFirst)

        let other = ModelRemoval.plan(model: "a", size: 1, loaded: ["a"], mine: [],
                                      streamingModel: nil, chatCount: 0, serverURL: "http://127.0.0.1:11434")
        #expect(other.block == .loadedByOther)
        #expect(!other.unloadFirst)
    }

    @Test func setupCatalogSharesNotes() {
        #expect(SetupCatalog.chat["qwen2.5vl:7b"]?.note == ModelCatalog.entry("qwen2.5vl:7b")?.blurb)
        #expect(SetupCatalog.uncensored["huihui_ai/qwen3-vl-abliterated:8b-instruct"] != nil)
        let need = SetupRecommendation.neededBytes(chat: ["huihui_ai/qwen2.5-vl-abliterated:7b"], whisper: nil)
        #expect(need > 6_000_000_000)
    }

    @Test func preferredFallsBackWhenChatModelMissing() {
        let installed = [ModelInfo(name: "qwen2.5vl:7b")]
        // conversation.model is handled by ChatEngine; ModelSelection still picks settings default.
        #expect(ModelSelection.preferred(choice: .named("huihui_ai/qwen2.5-vl-abliterated:7b"),
                                         tier: .pro, installed: installed) == "qwen2.5vl:7b")
    }
}

import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct ConversationTests {
    @Test func titleFromFirstLine() {
        #expect(Conversation.makeTitle(from: "Hello there\nsecond line") == "Hello there")
        #expect(Conversation.makeTitle(from: "   ", hasImage: true) == "Image")
        #expect(Conversation.makeTitle(from: "") == "New chat")
        let long = String(repeating: "word ", count: 30)
        let t = Conversation.makeTitle(from: long)
        #expect(t.count <= 61)
        #expect(t.hasSuffix("…"))
    }

    @Test func emptyUntilUserSpeaks() {
        var c = Conversation()
        #expect(c.isEmpty)
        c.messages.append(ChatMessage(role: .user, text: "hi"))
        #expect(!c.isEmpty)
    }

    @Test func wireAddsSystemAndSkipsEmptyReplies() {
        var c = Conversation()
        c.messages = [
            ChatMessage(role: .user, text: "one"),
            ChatMessage(role: .assistant, text: ""),
            ChatMessage(role: .user, text: "two"),
        ]
        let w = c.wire(system: "  Be brief.  ")
        #expect(w.map(\.role) == ["system", "user", "user"])
        #expect(w.first?.content == "Be brief.")
        #expect(c.wire(system: "   ").first?.role == "user")
        #expect(c.wire(system: nil).count == 2)
    }

    @Test func wireKeepsOnlyRecentImages() {
        var c = Conversation()
        for i in 0..<6 {
            c.messages.append(ChatMessage(role: .user, text: "\(i)", images: [Data([UInt8(i)])]))
            c.messages.append(ChatMessage(role: .assistant, text: "ok"))
        }
        let w = c.wire(system: nil, imageTurns: 4)
        let withImages = w.filter { !$0.images.isEmpty }.map(\.content)
        #expect(withImages == ["2", "3", "4", "5"])
    }
}

@Suite struct EngineStatusTests {
    @Test func levels() {
        #expect(EngineStatus.ready(model: "m").level == .ok)
        #expect(EngineStatus.loading(model: "m").level == .busy)
        #expect(EngineStatus.driveMissing(volume: "Lexar").level == .problem)
        #expect(EngineStatus.serverDown.level == .problem)
    }

    @Test func canChat() {
        #expect(EngineStatus.idle(model: "m").canChat)
        #expect(EngineStatus.loading(model: "m").canChat)
        #expect(!EngineStatus.generating(model: "m").canChat)
        #expect(!EngineStatus.driveMissing(volume: "X").canChat)
        #expect(!EngineStatus.noModels.canChat)
    }

    @Test func modelAndText() {
        #expect(EngineStatus.ready(model: "qwen2.5vl:7b").model == "qwen2.5vl:7b")
        #expect(EngineStatus.serverDown.model == nil)
        #expect(EngineStatus.driveMissing(volume: "Lexar").title.contains("Lexar"))
        #expect(EngineStatus.loading(model: "m").detail?.contains("10 seconds") == true)
    }
}

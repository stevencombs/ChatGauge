import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct ChatFilesTests {
    static func sample() -> Conversation {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        return Conversation(title: "Spec sheet: ports -- on the back", createdAt: t, updatedAt: t.addingTimeInterval(60),
                            model: "qwen2.5vl:7b", instructions: "Spec sheet", messages: [
            ChatMessage(role: .user, text: "What ports?\n\n**bold** and <!-- not a marker -->", createdAt: t),
            ChatMessage(role: .assistant, text: "Two USB-A.\n\n- HDMI\n- Ethernet", createdAt: t.addingTimeInterval(5),
                        model: "qwen2.5vl:7b", note: "Memory is low --> smaller model.", error: nil),
        ])
    }

    @Test func markdownRoundTrip() throws {
        let c = Self.sample()
        let md = ChatCodec.markdown(c)
        #expect(md.hasPrefix("---\nchatgauge: 1\n"))
        let back = try #require(ChatCodec.parseMarkdown(md))
        #expect(back.id == c.id)
        #expect(back.title == c.title)
        #expect(back.model == c.model)
        #expect(back.instructions == "Spec sheet")
        #expect(back.messages.map(\.text) == c.messages.map(\.text))
        #expect(back.messages.map(\.role) == [.user, .assistant])
        #expect(back.messages[1].note == "Memory is low --> smaller model.")
        #expect(abs(back.updatedAt.timeIntervalSince(c.updatedAt)) < 0.01)
    }

    @Test func jsonRoundTrip() throws {
        let c = Self.sample()
        let back = try #require(ChatCodec.parseJSON(ChatCodec.json(c)))
        #expect(back.messages.map(\.text) == c.messages.map(\.text))
        #expect(back.title == c.title)
        #expect(ChatCodec.parseJSON(Data("{\"app\":\"Other\"}".utf8)) == nil)
    }

    @Test func fileNamesAreSafe() {
        var c = Self.sample()
        c.title = "a/b:c?*  [x] #tag"
        let name = ChatCodec.fileName(for: c, format: .markdown)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix("[\(ChatCodec.shortID(c.id))].md"))
        c.title = ""
        #expect(ChatCodec.fileName(for: c, format: .json).contains(" Chat ["))
    }

    @Test func librarySaveRenameDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cg-chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = ChatLibrary(folder: dir)
        var c = Self.sample()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        c.messages[0].images = [png]
        let (url, saved) = try lib.save(c, format: .markdown)
        #expect(saved.messages[0].imageFiles.count == 1)
        #expect(saved.messages[0].imageFiles[0].hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try #require(lib.load(url))
        #expect(loaded.messages[0].images == [png])

        // Switching format replaces the old file.
        _ = try lib.save(saved, format: .json)
        #expect(lib.existing(c.id).count == 1)
        #expect(lib.existing(c.id).first?.pathExtension == "json")

        try lib.rename(c.id, to: "Renamed chat", format: .markdown)
        let list = lib.list()
        #expect(list.count == 1)
        #expect(list.first?.title == "Renamed chat")
        #expect(list.first?.matches("usb zebra") == false)
        #expect(list.first?.matches("two usb-a") == true)
    }

    @Test func listSortsNewestFirstAndSkipsForeignFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cg-chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = ChatLibrary(folder: dir)
        var a = Self.sample()
        a.title = "Older"
        var b = Conversation(title: "Newer", createdAt: a.createdAt, updatedAt: a.updatedAt.addingTimeInterval(500),
                             messages: [ChatMessage(role: .user, text: "hi")])
        b.model = "x"
        _ = try lib.save(a, format: .markdown)
        _ = try lib.save(b, format: .json)
        try Data("# my own notes".utf8).write(to: dir.appendingPathComponent("notes.md"))
        #expect(lib.list().map(\.title) == ["Newer", "Older"])
    }

    @Test func perChatModelInHeader() throws {
        var c = Self.sample()
        c.model = "huihui_ai/qwen3-vl-abliterated:8b-instruct"
        let back = try #require(ChatCodec.parseMarkdown(ChatCodec.markdown(c)))
        #expect(back.model == "huihui_ai/qwen3-vl-abliterated:8b-instruct")
        let j = try #require(ChatCodec.parseJSON(ChatCodec.json(c)))
        #expect(j.model == c.model)
    }
}

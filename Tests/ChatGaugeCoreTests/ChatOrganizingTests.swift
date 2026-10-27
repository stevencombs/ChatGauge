import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct ChatOrganizingTests {
    /// A chat file exactly as builds up to 12 wrote it (no `pinned` or `titled` lines).
    static let oldFile = """
    ---
    chatgauge: 1
    id: 6e1b5548-0000-4000-8000-000000000001
    title: "Hello"
    created: 2026-10-27T11:46:02.120Z
    updated: 2026-10-27T11:46:09.800Z
    model: "qwen2.5vl:7b"
    ---

    # Hello

    <!-- chatgauge-message {"createdAt":"2026-10-27T11:46:02.120Z","id":"6E1B5548-0000-4000-8000-0000000000A1","role":"user"} -->
    **You** · Oct 27, 2026 at 7:46 AM

    Hello

    <!-- chatgauge-message {"createdAt":"2026-10-27T11:46:09.800Z","id":"6E1B5548-0000-4000-8000-0000000000A2","model":"qwen2.5vl:7b","role":"assistant"} -->
    **qwen2.5vl:7b** · Oct 27, 2026 at 7:46 AM

    Hi! How can I help?

    """

    @Test func oldHeaderWithoutPinnedStillDecodes() throws {
        let c = try #require(ChatCodec.parseMarkdown(Self.oldFile))
        #expect(c.id.uuidString.lowercased() == "6e1b5548-0000-4000-8000-000000000001")
        #expect(c.title == "Hello")
        #expect(c.pinned == false)
        #expect(c.titleSource == .firstLine)
        #expect(c.model == "qwen2.5vl:7b")
        #expect(c.messages.map(\.text) == ["Hello", "Hi! How can I help?"])
        // Saving it again (unpinned, first-line title) writes no new header lines.
        let again = ChatCodec.markdown(c)
        #expect(!again.contains("pinned:"))
        #expect(!again.contains("titled:"))
    }

    @Test func oldJSONWithoutPinnedStillDecodes() throws {
        let json = """
        {"app":"ChatGauge","createdAt":"2026-10-27T11:46:02.120Z","formatVersion":1,"id":"6E1B5548-0000-4000-8000-000000000001",
         "messages":[{"createdAt":"2026-10-27T11:46:02.120Z","id":"6E1B5548-0000-4000-8000-0000000000A1","role":"user","text":"Hello"}],
         "title":"Hello","updatedAt":"2026-10-27T11:46:09.800Z"}
        """
        let c = try #require(ChatCodec.parseJSON(Data(json.utf8)))
        #expect(c.pinned == false)
        #expect(c.titleSource == .firstLine)
        #expect(c.messages.count == 1)
        let out = String(decoding: ChatCodec.json(c), as: UTF8.self)
        #expect(!out.contains("pinned"))
        #expect(!out.contains("titled"))
    }

    @Test func pinnedAndTitleSourceRoundTrip() throws {
        var c = ChatFilesTests.sample()
        c.pinned = true
        c.titleSource = .user
        let md = ChatCodec.markdown(c)
        #expect(md.contains("\npinned: true\n"))
        #expect(md.contains("\ntitled: user\n"))
        let back = try #require(ChatCodec.parseMarkdown(md))
        #expect(back.pinned)
        #expect(back.titleSource == .user)
        let j = try #require(ChatCodec.parseJSON(ChatCodec.json(c)))
        #expect(j.pinned)
        #expect(j.titleSource == .user)
        c.titleSource = .model
        #expect(ChatCodec.parseMarkdown(ChatCodec.markdown(c))?.titleSource == .model)
    }

    static func summary(_ title: String, _ updated: Date, pinned: Bool = false) -> ChatSummary {
        ChatSummary(id: UUID(), title: title, createdAt: updated, updatedAt: updated, model: nil, pinned: pinned,
                    preview: "", messageCount: 2, url: URL(fileURLWithPath: "/tmp/\(title).md"), searchText: title.lowercased())
    }

    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        return c
    }

    @Test func groupsByDay() {
        let cal = Self.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8, minute: 30))!
        func at(_ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
        let chats = [
            Self.summary("early today", at(27, 0)),
            Self.summary("late yesterday", at(26, 23)),
            Self.summary("yesterday morning", at(26, 1)),
            Self.summary("six days", at(21, 9)),
            Self.summary("seven days", at(20, 9)),
            Self.summary("eight days", at(19, 9)),
            Self.summary("old pinned", at(1, 9), pinned: true),
        ]
        let s = ChatGrouping.sections(chats, now: now, calendar: cal)
        #expect(s.map(\.group) == [.pinned, .today, .yesterday, .lastWeek, .older])
        #expect(s.map { $0.chats.map(\.title) } == [["old pinned"], ["early today"], ["late yesterday", "yesterday morning"],
                                                     ["six days", "seven days"], ["eight days"]])
        #expect(ChatGrouping.ordered(chats, now: now, calendar: cal).map(\.title).first == "old pinned")
        // Empty groups are left out.
        #expect(ChatGrouping.sections([Self.summary("a", at(27, 1))], now: now, calendar: cal).map(\.group) == [.today])
    }

    @Test func previousAndNext() {
        let t = Date()
        let list = (0..<3).map { Self.summary("c\($0)", t.addingTimeInterval(Double(-$0) * 60)) }
        #expect(ChatGrouping.neighbor(of: list[0].id, in: list, step: 1)?.title == "c1")
        #expect(ChatGrouping.neighbor(of: list[1].id, in: list, step: -1)?.title == "c0")
        #expect(ChatGrouping.neighbor(of: list[0].id, in: list, step: -1) == nil)
        #expect(ChatGrouping.neighbor(of: list[2].id, in: list, step: 1) == nil)
        #expect(ChatGrouping.neighbor(of: UUID(), in: list, step: 1)?.title == "c0")
        #expect(ChatGrouping.neighbor(of: nil, in: [], step: 1) == nil)
    }

    @Test func switcherPinnedFirstAndLimited() {
        let t = Date()
        var list = (0..<14).map { Self.summary("c\($0)", t.addingTimeInterval(Double(-$0) * 60)) }
        list[12].pinned = true
        let s = ChatGrouping.switcher(list, limit: 10)
        #expect(s.count == 10)
        #expect(s.first?.title == "c12")
        #expect(s[1].title == "c0")
        #expect(ChatGrouping.lastChat(list)?.title == "c0")
        #expect(ChatGrouping.lastChat([]) == nil)
    }

    @Test func titleCleanup() {
        #expect(AutoTitle.clean("\"Status Check.\"") == "Status Check")
        #expect(AutoTitle.clean("Title: Weekend Trip Ideas") == "Weekend Trip Ideas")
        #expect(AutoTitle.clean("**Title:** USB Ports on the Mac\nHope this helps!") == "USB Ports on the Mac")
        #expect(AutoTitle.clean("<think>hmm, maybe…</think>\n\nSourdough Starter Tips") == "Sourdough Starter Tips")
        #expect(AutoTitle.clean("   \n  ") == nil)
        #expect(AutoTitle.clean("\"\"") == nil)
        let long = AutoTitle.clean("one two three four five six seven eight nine ten eleven")
        #expect(long == "one two three four five six seven eight")
        #expect((AutoTitle.clean(String(repeating: "abcdefghij", count: 10)) ?? "").count <= 60)
    }

    @Test func titleRequestUsesFirstExchange() throws {
        let c = ChatFilesTests.sample()
        let m = try #require(AutoTitle.messages(for: c))
        #expect(m.count == 3)
        #expect(m[0].role == "user" && m[0].content.hasPrefix("What ports?"))
        #expect(m[1].role == "assistant")
        #expect(m[2].content == AutoTitle.instruction)
        #expect(AutoTitle.messages(for: Conversation()) == nil)
        let body = String(decoding: ChatRequest.body(model: "m", messages: m, keepAlive: -1, stream: false,
                                                     options: ["num_predict": 32]), as: UTF8.self)
        #expect(body.contains("\"stream\":false"))
        #expect(body.contains("\"num_predict\":32"))
        #expect(body.contains("\"keep_alive\":-1"))
    }

    @Test func trashShortcutLeavesTypingAlone() {
        #expect(TrashShortcut.handles(editingText: false, fieldIsEmpty: true))
        #expect(TrashShortcut.handles(editingText: true, fieldIsEmpty: true))
        #expect(!TrashShortcut.handles(editingText: true, fieldIsEmpty: false))
    }

    @Test func newSettingsDefaultsAndOldSettingsFiles() throws {
        let d = ChatSettings()
        #expect(d.autoTitles)
        #expect(!d.reopenLastChat)
        let old = try JSONDecoder().decode(ChatSettings.self, from: Data(#"{"saveChats":true}"#.utf8))
        #expect(old.autoTitles && !old.reopenLastChat)
    }

    static func tempLibrary() throws -> ChatLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cg-org-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ChatLibrary(folder: dir)
    }

    static func png() -> Data {
        // A tiny valid PNG header is enough for the library's PNG check and copying.
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    }

    @Test func pinRenameAndModelTitleInLibrary() throws {
        let lib = try Self.tempLibrary()
        defer { try? FileManager.default.removeItem(at: lib.folder) }
        let c = ChatFilesTests.sample()
        try lib.save(c, format: .markdown)
        try lib.setPinned(c.id, true, format: .markdown)
        #expect(lib.list().first?.pinned == true)
        #expect(try String(contentsOf: lib.existing(c.id)[0], encoding: .utf8).contains("pinned: true"))
        let applied = try lib.applyModelTitle(c.id, "Port Questions", format: .markdown)
        #expect(applied)
        #expect(lib.list().first?.title == "Port Questions")
        #expect(lib.list().first?.titleSource == .model)
        try lib.rename(c.id, to: "Mine", format: .markdown)
        let late = try lib.applyModelTitle(c.id, "Overwrite?", format: .markdown)
        #expect(!late)
        #expect(lib.list().first?.title == "Mine")
        #expect(lib.list().first?.titleSource == .user)
        #expect(lib.list().first?.pinned == true)
        try lib.setPinned(c.id, false, format: .markdown)
        #expect(lib.list().first?.pinned == false)
        #expect(try !String(contentsOf: lib.existing(c.id)[0], encoding: .utf8).contains("pinned:"))
    }

    @Test func duplicateCopiesImages() throws {
        let lib = try Self.tempLibrary()
        defer { try? FileManager.default.removeItem(at: lib.folder) }
        var c = ChatFilesTests.sample()
        c.messages[0].images = [Self.png()]
        c.pinned = true
        let (_, saved) = try lib.save(c, format: .json)
        let copy = try #require(try lib.duplicate(c.id, format: .markdown, now: Date()))
        #expect(copy.id != c.id)
        #expect(copy.title == c.title + " copy")
        #expect(!copy.pinned)
        #expect(copy.titleSource == .user)
        #expect(copy.messages.map(\.text) == c.messages.map(\.text))
        let orig = saved.messages[0].imageFiles, dup = copy.messages[0].imageFiles
        #expect(orig.count == 1 && dup.count == 1 && orig != dup)
        #expect(dup[0].contains(copy.id.uuidString.lowercased()))
        #expect(FileManager.default.contents(atPath: lib.folder.appendingPathComponent(dup[0]).path) == Self.png())
        #expect(lib.list().count == 2)
        // The copy keeps the original's file format.
        #expect(lib.existing(copy.id).first?.pathExtension == "json")
    }

    @Test func cleanMarkdownExport() throws {
        let lib = try Self.tempLibrary()
        defer { try? FileManager.default.removeItem(at: lib.folder) }
        var c = ChatFilesTests.sample()
        c.messages[0].images = [Self.png()]
        try lib.save(c, format: .markdown)
        let outDir = lib.folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let dest = outDir.appendingPathComponent("My Export.md")
        try lib.exportMarkdown(c.id, to: dest, copyImages: true)
        let md = try String(contentsOf: dest, encoding: .utf8)
        #expect(md.hasPrefix("# Spec sheet: ports -- on the back\n"))
        #expect(!md.contains("chatgauge-message"))
        #expect(!md.contains("chatgauge: 1"))
        #expect(md.contains("**You**"))
        #expect(md.contains("Two USB-A."))
        #expect(md.contains("![Image 1](My%20Export%20images/"))
        let imgs = try FileManager.default.contentsOfDirectory(atPath: outDir.appendingPathComponent("My Export images").path)
        #expect(imgs.count == 1)
        let dest2 = outDir.appendingPathComponent("Plain.md")
        try lib.exportMarkdown(c.id, to: dest2, copyImages: false)
        let md2 = try String(contentsOf: dest2, encoding: .utf8)
        #expect(md2.contains("](file://"))
        #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("Plain images").path))
    }
}

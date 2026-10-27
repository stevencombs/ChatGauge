import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct DropAndPinTests {
    @Test func testImageFilterKeepsImagesOnly() {
        let urls = ["/t/a.png", "/t/b.JPG", "/t/c.heic", "/t/d.txt", "/t/e.pdf", "/t/f.gif", "/t/folder/"]
            .map { URL(fileURLWithPath: $0, isDirectory: $0.hasSuffix("/")) }
        #expect(DroppedFiles.images(urls).map(\.lastPathComponent) == ["a.png", "b.JPG", "c.heic", "f.gif"])
    }

    @Test func testImageFilterDropsDuplicatesAndWebURLs() {
        let a = URL(fileURLWithPath: "/t/a.png")
        let urls = [a, URL(fileURLWithPath: "/t/./a.png"), URL(string: "https://example.com/x.png")!]
        #expect(DroppedFiles.images(urls) == [a])
    }

    @Test func testPinPolicy() {
        let off = PopoverPolicy(pinned: false), on = PopoverPolicy(pinned: true)
        #expect(off.transient); #expect(off.closesOnOutsideClick); #expect(off.attachInChatWindow)
        #expect(!on.transient); #expect(!on.closesOnOutsideClick); #expect(!on.attachInChatWindow)
    }

    @Test func testPinSettingDefaultsOffForOldFiles() throws {
        let s = try JSONDecoder().decode(ChatSettings.self, from: Data("{}".utf8))
        #expect(!s.pinPopover)
    }

    @Test func testPinSettingRoundTrips() throws {
        var s = ChatSettings(); s.pinPopover = true
        let back = try JSONDecoder().decode(ChatSettings.self, from: JSONEncoder().encode(s))
        #expect(back.pinPopover)
    }
}

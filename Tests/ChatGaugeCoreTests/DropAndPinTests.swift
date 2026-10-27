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
        #expect(off.semitransient); #expect(off.closesOnOutsideClick); #expect(off.attachInChatWindow)
        #expect(!on.semitransient); #expect(!on.closesOnOutsideClick); #expect(!on.attachInChatWindow)
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

    @Test func plainOutsideClickClosesOnRelease() {
        var t = OutsideClickTracker()
        let r1 = t.handle(.down, x: 100, y: 100); #expect(!r1)
        let r2 = t.handle(.dragged, x: 102, y: 101); #expect(!r2)   // sloppy click, under the slop
        let r3 = t.handle(.up, x: 102, y: 101); #expect(r3)
    }

    @Test func pressAndDragDoesNotClose() {
        var t = OutsideClickTracker()
        let r4 = t.handle(.down, x: 100, y: 100); #expect(!r4)
        let r5 = t.handle(.dragged, x: 140, y: 90); #expect(!r5)
        #expect(t.isDragging)
        let r6 = t.handle(.up, x: 300, y: 10); #expect(!r6)
        // The next plain click closes again.
        let r7 = t.handle(.down, x: 5, y: 5); #expect(!r7)
        let r8 = t.handle(.up, x: 5, y: 5); #expect(r8)
    }

    @Test func releaseWithoutSeenPressIsIgnored() {
        // The popover opened mid-drag (drag entered the icon): the drag's mouse-up must not close it.
        var t = OutsideClickTracker()
        let r9 = t.handle(.dragged, x: 50, y: 50); #expect(!r9)
        let r10 = t.handle(.up, x: 50, y: 50); #expect(!r10)
    }

    @Test func rightClickClosesAtOnce() {
        var t = OutsideClickTracker()
        let r11 = t.handle(.rightDown); #expect(r11)
    }

    @Test func dragOpenedPopoverClosesOnlyWithoutDrop() {
        let start = Date()
        #expect(DragOpenedPopover.shouldClose(openedByDrag: true, dropAt: nil, dragStart: start, attachmentsBefore: 0, attachmentsNow: 0))
        #expect(!DragOpenedPopover.shouldClose(openedByDrag: true, dropAt: start.addingTimeInterval(1), dragStart: start, attachmentsBefore: 0, attachmentsNow: 0))
        #expect(!DragOpenedPopover.shouldClose(openedByDrag: true, dropAt: nil, dragStart: start, attachmentsBefore: 0, attachmentsNow: 1))
        #expect(DragOpenedPopover.shouldClose(openedByDrag: true, dropAt: start.addingTimeInterval(-5), dragStart: start, attachmentsBefore: 1, attachmentsNow: 1))
        #expect(!DragOpenedPopover.shouldClose(openedByDrag: false, dropAt: nil, dragStart: start, attachmentsBefore: 0, attachmentsNow: 0))
    }
}

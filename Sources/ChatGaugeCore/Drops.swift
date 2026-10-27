import Foundation
import UniformTypeIdentifiers

/// Which dropped or picked files ChatGauge can attach.
public enum DroppedFiles {
    /// File URLs whose type is an image (by extension), in order, without duplicates.
    public static func images(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { u in
            guard u.isFileURL, !u.hasDirectoryPath,
                  let t = UTType(filenameExtension: u.pathExtension), t.conforms(to: .image),
                  seen.insert(u.standardizedFileURL.path).inserted else { return false }
            return true
        }
    }
}

/// How the menu bar popover behaves.
/// Unpinned (default): semi-transient, so switching to Finder doesn't close it; a plain click in another app closes it
/// (OutsideClickTracker), but pressing and dragging a file does not. Esc, the icon and the hotkey close it too.
/// Pinned: stays open across any clicks elsewhere until Esc, the icon or the hotkey.
public struct PopoverPolicy: Equatable, Sendable {
    public var pinned: Bool
    public init(pinned: Bool) { self.pinned = pinned }
    public var closesOnOutsideClick: Bool { !pinned }
    /// AppKit behavior: semi-transient unpinned, application-defined pinned. Never transient: a transient popover
    /// closes the moment another app becomes active, i.e. as soon as you click Finder to pick up a file.
    public var semitransient: Bool { !pinned }
    /// Attach from the popover opens the chat window and shows the file picker there as a sheet.
    public var attachInChatWindow: Bool { !pinned }
}

/// Whether a drag that opened the popover (by entering the menu bar icon) should close it when the drag ends.
public enum DragOpenedPopover {
    public static func shouldClose(openedByDrag: Bool, dropAt: Date?, dragStart: Date, attachmentsBefore: Int, attachmentsNow: Int) -> Bool {
        guard openedByDrag else { return false }
        if let dropAt, dropAt >= dragStart { return false }
        return attachmentsNow <= attachmentsBefore
    }
}

/// Decides when a click in another app should close the popover. A plain click closes it (on release); pressing and
/// dragging (e.g. picking up a file in Finder to drop on ChatGauge) does not. Right-clicks close at once.
public struct OutsideClickTracker: Sendable {
    public enum Event: Sendable { case down, dragged, up, rightDown }
    /// Movement (points) before a press counts as a drag rather than a sloppy click.
    public static let dragSlop: Double = 4
    private var downAt: (x: Double, y: Double)?
    private var dragging = false
    public init() {}

    /// Returns true when the popover should close.
    public mutating func handle(_ event: Event, x: Double = 0, y: Double = 0) -> Bool {
        switch event {
        case .rightDown:
            reset(); return true
        case .down:
            downAt = (x, y); dragging = false; return false
        case .dragged:
            if let d = downAt, !dragging, abs(x - d.x) > Self.dragSlop || abs(y - d.y) > Self.dragSlop { dragging = true }
            return false
        case .up:
            defer { reset() }
            return downAt != nil && !dragging
        }
    }
    public var isDragging: Bool { dragging }
    private mutating func reset() { downAt = nil; dragging = false }
}

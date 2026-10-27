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

/// How the menu bar popover behaves. Unpinned it is transient (closes when you click elsewhere, like ClipGauge);
/// pinned it stays open across clicks in other apps until you click the menu bar icon again.
public struct PopoverPolicy: Equatable, Sendable {
    public var pinned: Bool
    public init(pinned: Bool) { self.pinned = pinned }
    public var closesOnOutsideClick: Bool { !pinned }
    public var transient: Bool { !pinned }
    /// Attach from the popover opens the chat window and shows the file picker there, because a modal panel takes
    /// focus and would close a transient popover. A pinned popover stays put, so the picker can run from it.
    public var attachInChatWindow: Bool { !pinned }
}

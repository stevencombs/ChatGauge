import AppKit
import UniformTypeIdentifiers

/// An image waiting in the composer.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data          // JPEG sent to the model
    let preview: NSImage
    let name: String

    static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }

    /// Downscales to at most `maxSide` px on the long side and re-encodes as JPEG (keeps requests small).
    static func make(from image: NSImage, name: String = "Image", maxSide: CGFloat = 1536) -> Attachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return Attachment(data: jpeg, preview: NSImage(data: jpeg) ?? image, name: name)
    }

    static func make(fromFile url: URL) -> Attachment? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return make(from: img, name: url.lastPathComponent)
    }

    /// Images on the pasteboard (files first, then raw image data).
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [Attachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                                        .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap(make(fromFile:))
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            return imgs.compactMap { make(from: $0, name: "Pasted image") }
        }
        return []
    }

    static func pasteboardHasImage(_ pb: NSPasteboard = .general) -> Bool {
        let types = pb.types ?? []
        if types.contains(.fileURL) {
            return !(fromPasteboardURLs(pb).isEmpty)
        }
        return types.contains(.png) || types.contains(.tiff) || types.contains(NSPasteboard.PasteboardType("public.jpeg"))
    }

    private static func fromPasteboardURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                            .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL]) ?? []
    }
}

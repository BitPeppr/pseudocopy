import Foundation

// PLAN.md §3: clipboard.swift — pasteboard recipes (§4.1).
import AppKit
import UniformTypeIdentifiers

/// Writes a file to the general pasteboard using the representation that
/// matches its type (§2.2).
///
/// - Parameters:
///   - kind: how the file should be represented.
///   - url: the file to clip.
///   - embedLimit: maximum size for which the raw bytes are embedded.
func putOnClipboard(kind: FileKind, url: URL, embedLimit: Int) throws {
    let pasteboard = NSPasteboard.general

    switch kind {
    case .text:
        // Text that is not valid UTF-8 falls through to the generic handling.
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let data = text.data(using: .utf8) else {
            try putOnClipboard(kind: .other, url: url, embedLimit: embedLimit)
            return
        }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))

    case .image, .pdf:
        let raw = try Data(contentsOf: url)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        pasteboard.clearContents()
        pasteboard.setData(raw, forType: NSPasteboard.PasteboardType(uti))

    case .other:
        let raw = try Data(contentsOf: url)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? raw.count

        pasteboard.clearContents()
        // File reference first, so that the raw data below is added to (and
        // not cleared away by) the same pasteboard.
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setPropertyList([url.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        if size <= embedLimit {
            pasteboard.setData(raw, forType: NSPasteboard.PasteboardType(uti))
        }
    }
}

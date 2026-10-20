import Foundation

// PLAN.md §3: clipboard.swift — pasteboard recipes (§4.1).
import AppKit
import UniformTypeIdentifiers

/// Errors raised while writing to the pasteboard.
enum ClipboardError: Error, CustomStringConvertible {
    /// The pasteboard refused a representation.
    case writeFailed(String)

    var description: String {
        switch self {
        case .writeFailed(let what):
            return "pasteboard write failed (\(what))"
        }
    }
}

/// Hard cap for materialising an image or PDF payload. Such a file is copied
/// into the pasteboard byte for byte, so there has to be a limit — a
/// multi gigabyte "PDF" would otherwise take the process down with it.
let materialiseLimitBytes = 256 << 20

/// Writes a file to the general pasteboard using the representation that
/// matches its type (§2.2).
///
/// - Parameters:
///   - kind: how the file should be represented.
///   - url: the file to clip.
///   - embedLimit: maximum size for which the raw bytes are embedded.
/// - Returns: the kind that was actually written — text files that are not
///   valid UTF-8 fall through to `.other`.
/// - Throws: `ClipboardError` when the pasteboard refuses a representation.
@discardableResult
func putOnClipboard(kind: FileKind, url: URL, embedLimit: Int) throws -> FileKind {
    try writeToPasteboard(kind: kind, url: url, embedLimit: embedLimit, clearing: true)
}

/// The actual write. `clearing` is false when several files are put on the
/// pasteboard one after the other: the pasteboard is emptied once, then every
/// file adds its own representation.
@discardableResult
func writeToPasteboard(kind: FileKind, url: URL, embedLimit: Int, clearing: Bool) throws -> FileKind {
    let pasteboard = NSPasteboard.general

    switch kind {
    case .text:
        // The bytes are written unchanged (§2.2), but they have to be valid
        // UTF-8 — otherwise this falls through to the generic handling.
        let raw = try Data(contentsOf: url)
        guard String(data: raw, encoding: .utf8) != nil else {
            return try writeToPasteboard(kind: .other, url: url, embedLimit: embedLimit, clearing: clearing)
        }
        if clearing { pasteboard.clearContents() }
        guard pasteboard.setData(raw, forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) else {
            throw ClipboardError.writeFailed("public.utf8-plain-text")
        }
        return .text

    case .image, .pdf:
        let size = fileSize(of: url)
        guard size <= materialiseLimitBytes else {
            throw ClipboardError.writeFailed("\(url.lastPathComponent) is \(size) bytes, over the \(materialiseLimitBytes) byte limit")
        }
        let raw = try Data(contentsOf: url)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        if clearing { pasteboard.clearContents() }
        guard pasteboard.setData(raw, forType: NSPasteboard.PasteboardType(uti)) else {
            throw ClipboardError.writeFailed(uti)
        }
        return kind

    case .other:
        let size = fileSize(of: url)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier

        if clearing { pasteboard.clearContents() }
        // The file reference comes first, so that the raw data below is added
        // to (and not cleared away by) the same pasteboard.
        guard pasteboard.writeObjects([url as NSURL]) else {
            throw ClipboardError.writeFailed("public.file-url")
        }
        guard pasteboard.setPropertyList([url.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) else {
            throw ClipboardError.writeFailed("NSFilenamesPboardType")
        }
        if size <= embedLimit {
            // Only now is reading the bytes justified: a file over the limit
            // is never embedded, so it never has to be loaded at all.
            let raw = try Data(contentsOf: url)
            guard pasteboard.setData(raw, forType: NSPasteboard.PasteboardType(uti)) else {
                throw ClipboardError.writeFailed(uti)
            }
        }
        return .other
    }
}

/// The size of a file in bytes, or 0 when it cannot be determined.
func fileSize(of url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

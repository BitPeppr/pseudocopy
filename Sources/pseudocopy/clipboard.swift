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
/// into the pasteboard byte for byte, so there has to be a limit — a multi
/// gigabyte "PDF" would otherwise take the process down with it.
let materialiseLimitBytes = 256 << 20

/// Hard cap for a text payload. Text costs about three times its size in
/// memory (the bytes, the decoded string and the pasteboard's own copy), so
/// a huge log file would cost three times its size in RAM.
let textEmbedLimitBytes = 16 << 20

/// One file and the representation it should get on the pasteboard.
struct ClipPayload {
    /// The kind that is actually written.
    var kind: FileKind
    var url: URL
    /// The UTI of the embedded bytes, if there are any.
    var uti: String?
    /// The embedded bytes.
    var data: Data?
}

/// Writes files to the general pasteboard using the representation that
/// matches their type (§2.2).
///
/// - Parameters:
///   - kinds: the kind each file should get.
///   - urls: the files, in the same order as `kinds`.
///   - embedLimit: maximum size for which the raw bytes are embedded.
/// - Returns: the kind that was actually written for every file — text files
///   that are not valid UTF-8 fall through to `.other`.
/// - Throws: `ClipboardError` when the pasteboard refuses a representation.
@discardableResult
func putOnClipboard(kind: FileKind, url: URL, embedLimit: Int) throws -> FileKind {
    try putFilesOnClipboard(kinds: [kind], urls: [url], embedLimit: embedLimit)[0]
}

/// Writes several files in one pasteboard transaction.
///
/// A pasteboard holds one value per type, so only the first file of a kind
/// contributes its bytes — but every file is offered as a file reference, so
/// a paste into the Finder copies all of them.
@discardableResult
func putFilesOnClipboard(kinds: [FileKind], urls: [URL], embedLimit: Int) throws -> [FileKind] {
    guard !urls.isEmpty else { return [] }

    // Everything is read and prepared *before* the pasteboard is touched: a
    // file that cannot be read must not leave the user with an empty
    // clipboard.
    var payloads: [ClipPayload] = []
    for (index, url) in urls.enumerated() {
        payloads.append(try payload(for: kinds[index], url: url, embedLimit: embedLimit))
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    guard pasteboard.writeObjects(payloads.map { $0.url as NSURL }) else {
        throw ClipboardError.writeFailed("public.file-url")
    }
    guard pasteboard.setPropertyList(payloads.map { $0.url.path }, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) else {
        throw ClipboardError.writeFailed("NSFilenamesPboardType")
    }

    var written = Set<String>()
    for payload in payloads {
        guard let uti = payload.uti, let data = payload.data else { continue }
        // One value per type: the first file of a kind wins.
        guard !written.contains(uti) else { continue }
        written.insert(uti)
        guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType(uti)) else {
            throw ClipboardError.writeFailed(uti)
        }
    }

    return payloads.map { $0.kind }
}

/// Builds the representation for one file, reading its bytes if they are
/// small enough to be embedded.
private func payload(for kind: FileKind, url: URL, embedLimit: Int) throws -> ClipPayload {
    let size = fileSize(of: url)

    switch kind {
    case .text:
        // A text file that is too big to embed is offered as a file
        // reference instead — otherwise it would cost three times its size in
        // memory.
        guard size <= textEmbedLimitBytes else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        let raw = try Data(contentsOf: url)
        // The bytes are written unchanged (§2.2), but they have to be valid
        // UTF-8 — otherwise this falls through to the generic handling.
        guard String(data: raw, encoding: .utf8) != nil else {
            return try payload(for: .other, url: url, embedLimit: embedLimit)
        }
        return ClipPayload(kind: .text, url: url, uti: "public.utf8-plain-text", data: raw)

    case .image, .pdf:
        guard size <= materialiseLimitBytes else {
            // Too big to materialise: the file reference is the best that can
            // be offered.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        let raw = try Data(contentsOf: url)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        return ClipPayload(kind: kind, url: url, uti: uti, data: raw)

    case .other:
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        guard size <= embedLimit else {
            // A file over the limit is never embedded, so it never has to be
            // read into memory at all.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        let raw = try Data(contentsOf: url)
        return ClipPayload(kind: .other, url: url, uti: uti, data: raw)
    }
}

/// The size of a file in bytes, or 0 when it cannot be determined.
///
/// A fresh URL is used on purpose: the resource values of a URL that was
/// used before are cached, and a stale size would make the limit checks
/// decide on old numbers.
func fileSize(of url: URL) -> Int {
    let fresh = URL(fileURLWithPath: url.path)
    return (try? fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

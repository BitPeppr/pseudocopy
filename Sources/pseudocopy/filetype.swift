import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// PLAN.md §2.2: "smart by type" classification. The extension lists are a
// fallback; whenever the bytes can be identified, the content decides. The
// AppKit-free core in fs.swift calls in here, so the pasteboard frameworks
// stay out of the filesystem code.

/// What a file's content says it is, and what follows from it.
struct FileInspection {
    /// The kind that should be used for the pasteboard.
    var kind: FileKind
    /// The UTI the embedded bytes are written under. `nil` for text, which is
    /// always written as UTF-8.
    var uti: String?
    /// Page count of a PDF, when the document could be parsed.
    var pageCount: Int?
}

/// The header of every PDF document.
private let pdfMagic = Data("%PDF-".utf8)

/// How many bytes are read to identify a file. The PDF header is right at the
/// start; the rest leaves room for the UTF-8 heuristic.
private let sniffLimit = 64 << 10

/// The PDF UTI. `UTType.pdf.identifier` is the same string; the literal keeps
/// the comparison next to the other ImageIO type identifiers.
private let pdfType = "com.adobe.pdf"

/// ImageIO can rasterise PDFs and EPS as well; those are documents, not
/// images, and must not be classified as one (only page 1 would ever survive).
private let epsType = "com.adobe.encapsulated-postscript"

/// Identifies a file by its content, falling back to its extension.
///
/// The order matters:
/// 1. the PDF header is checked first, because ImageIO opens PDFs too and
///    would silently reduce a multi-page document to its first page;
/// 2. ImageIO then decides whether the bytes are a decodable image and which
///    UTI they really are — a PNG named `.jpg` is a PNG;
/// 3. the extension lists decide the rest, with a UTF-8 heuristic for files
///    whose extension says nothing (Dockerfile, LICENSE, Makefile).
func inspectFile(_ url: URL) -> FileInspection {
    let ext = url.pathExtension.lowercased()
    guard let prefix = readPrefix(url) else {
        // The file cannot be read right now. Classification falls back to the
        // name; the payload read will fail as well and the cycle retries it.
        return FileInspection(kind: extensionKind(ext), uti: uti(for: url), pageCount: nil)
    }

    // The header is only accepted at offset 0. Searching the first kilobyte
    // (as a PDF reader may) would classify a text file that merely mentions
    // "%PDF-" as a document, and calling CoreGraphics on such a file writes an
    // error to the agent's log.
    if prefix.starts(with: pdfMagic) {
        let pages = CGPDFDocument(url as CFURL)?.numberOfPages
        return FileInspection(kind: .pdf, uti: pdfType, pageCount: pages)
    }

    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       let type = CGImageSourceGetType(source) as String?,
       type != pdfType, type != epsType {
        return FileInspection(kind: .image, uti: type, pageCount: nil)
    }

    if ExtensionSets.text.contains(ext) {
        return FileInspection(kind: .text, uti: nil, pageCount: nil)
    }
    if ExtensionSets.image.contains(ext) {
        // The name says image but the bytes could not be decoded (a truncated
        // or unusual file). Offer the raw bytes under the name's type, which
        // is what an image-aware app expects.
        return FileInspection(kind: .image, uti: uti(for: url), pageCount: nil)
    }
    if ExtensionSets.pdf.contains(ext) {
        // A PDF without a header at offset 0: damaged, or generated with junk
        // in front. It is still offered as a document, but there is no page
        // count to warn about.
        return FileInspection(kind: .pdf, uti: pdfType, pageCount: nil)
    }
    if isUndeterminedExtension(ext), looksLikeText(prefix) {
        return FileInspection(kind: .text, uti: nil, pageCount: nil)
    }
    return FileInspection(kind: .other, uti: uti(for: url), pageCount: nil)
}

/// The kind that the extension alone suggests (the pre-content behaviour).
private func extensionKind(_ ext: String) -> FileKind {
    if ExtensionSets.text.contains(ext) { return .text }
    if ExtensionSets.image.contains(ext) { return .image }
    if ExtensionSets.pdf.contains(ext) { return .pdf }
    return .other
}

/// True when the extension does not identify a known type, so the bytes may
/// decide. A known but non-text type (`.rtf`, `.svg`) keeps its own handling:
/// pasting RTF or SVG source as plain text would be worse than a file
/// reference.
private func isUndeterminedExtension(_ ext: String) -> Bool {
    guard !ext.isEmpty else { return true }
    guard let type = UTType(filenameExtension: ext) else { return true }
    return type.isDynamic
}

/// True when the bytes look like UTF-8 text.
///
/// A prefix that was cut in the middle of a multi-byte character is still
/// text, so up to three trailing bytes are dropped before giving up.
private func looksLikeText(_ data: Data) -> Bool {
    guard !data.isEmpty, !data.contains(0) else { return false }
    for trimmed in 0...min(3, data.count) {
        if String(data: data.dropLast(trimmed), encoding: .utf8) != nil {
            return true
        }
    }
    return false
}

/// Reads the head of a file, or nil when it cannot be opened.
private func readPrefix(_ url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    do {
        return try handle.read(upToCount: sniffLimit) ?? Data()
    } catch {
        return nil
    }
}

/// The UTI a file's bytes are written under, from its extension.
///
/// Used for the *Other* representation and as the fallback when the content
/// cannot be identified.
func uti(for url: URL) -> String {
    UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
}

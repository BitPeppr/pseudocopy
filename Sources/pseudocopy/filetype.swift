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
    /// Page count of a PDF or a multi-page TIFF, when it could be read.
    var pageCount: Int?
}

/// The header of every PDF document.
private let pdfMagic = Data("%PDF-".utf8)

/// The UTF-8 byte-order mark. Stripped explicitly: newer Foundation versions
/// drop it while decoding UTF-8, older ones keep it as U+FEFF. The pasted text
/// must be the same on every supported macOS version.
private let utf8BOM = Data([0xEF, 0xBB, 0xBF])

/// How many bytes are read to identify a file. The PDF header is right at the
/// start; the rest leaves room for the text heuristic.
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
/// 3. text is decided by the explicit extension list, by the plain-text UTI
///    that macOS itself assigns to the extension, and — for an extension that
///    says nothing — by the bytes being text.
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
        return FileInspection(kind: .image, uti: type, pageCount: multiPageCount(source, type: type))
    }

    if ExtensionSets.text.contains(ext) || isPlainTextExtension(ext) {
        return FileInspection(kind: .text, uti: nil, pageCount: nil)
    }
    if ExtensionSets.image.contains(ext) {
        // The name says image but ImageIO could not decode it (a truncated,
        // mislabelled or damaged file). Advertising the name's image type
        // would hand broken bytes to an image-aware app; offer the file (and
        // generic data) instead.
        return FileInspection(kind: .other, uti: UTType.data.identifier, pageCount: nil)
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

/// True when macOS assigns a plain-text type to the extension even though it
/// is not in the explicit list (Fortran, Pascal, Ada, Make, ...).
///
/// The conformance check deliberately asks for `public.plain-text`, not
/// `public.text`: `public.rtf` and `public.html` conform to `text`, and
/// `public.svg-image` conforms to both `text` and `image`; none of them is
/// plain text. This is what keeps RTF markup and SVG source off the clipboard
/// as text.
private func isPlainTextExtension(_ ext: String) -> Bool {
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else {
        return false
    }
    return type.conforms(to: .plainText)
}

/// Decodes the text of a file, or nil when the bytes are not text.
///
/// UTF-8 is used as-is (a leading UTF-8 BOM is dropped by the decoder and is
/// not re-emitted). A UTF-16 BOM selects UTF-16, which is transcoded to UTF-8:
/// the pasteboard carries UTF-8 text, and a Windows-exported `.txt` or `.csv`
/// would otherwise arrive as a file instead of as its text.
///
/// Encodings without a BOM (Latin-1, Shift-JIS, ...) are deliberately not
/// guessed: macOS's detector reads invalid UTF-8 as Cyrillic with confidence,
/// and pasting mojibake is worse than offering the file.
func decodeText(_ raw: Data) -> String? {
    if raw.isEmpty { return "" }
    if hasUTF16BOM(raw) {
        guard let text = String(data: raw, encoding: .utf16), isTextual(text) else {
            return nil
        }
        return text
    }
    // A NUL byte means binary. UTF-16 without a BOM is not guessed either.
    guard !raw.contains(0) else { return nil }
    let body = raw.starts(with: utf8BOM) ? raw.dropFirst(utf8BOM.count) : raw[...]
    return String(data: body, encoding: .utf8)
}

/// True when the data starts with a UTF-16 byte-order mark (LE or BE).
private func hasUTF16BOM(_ data: Data) -> Bool {
    guard data.count >= 2 else { return false }
    let first = data[data.startIndex]
    let second = data[data.index(after: data.startIndex)]
    return (first == 0xFF && second == 0xFE) || (first == 0xFE && second == 0xFF)
}

/// True when a decoded string contains no binary control characters.
///
/// Tab, newline, carriage return and form feed are the controls a text file
/// legitimately contains. This check is used for BOM-marked UTF-16 and for the
/// extensionless heuristic; plain UTF-8 is only checked for NUL bytes, which
/// keeps ANSI-coloured logs and similar text pasteable.
private func isTextual(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let value = scalar.value
        if value == 0 || value == 0x7F { return false }
        if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D && value != 0x0C {
            return false
        }
    }
    return true
}

/// True when the bytes look like text.
///
/// A prefix that was cut in the middle of a multi-byte character is still
/// text, so up to three trailing bytes are dropped before giving up. A
/// BOM-marked UTF-16 prefix (a `.strings` file, for example) is text as well.
private func looksLikeText(_ data: Data) -> Bool {
    guard !data.isEmpty else { return false }
    if hasUTF16BOM(data) {
        for trimmed in 0...min(2, data.count) {
            if let text = String(data: data.dropLast(trimmed), encoding: .utf16),
               isTextual(text) {
                return true
            }
        }
        return false
    }
    guard !data.contains(0) else { return false }
    for trimmed in 0...min(3, data.count) {
        if String(data: data.dropLast(trimmed), encoding: .utf8) != nil {
            return true
        }
    }
    return false
}

/// The page count of a multi-page TIFF, when every page has the same
/// dimensions.
///
/// A TIFF may carry a thumbnail as a second IFD; a thumbnail is much smaller
/// than the main image, so requiring equal dimensions keeps an ordinary
/// single-image TIFF from being announced as a document. An animated TIFF or a
/// scanned document passes the check, which is what the file reference and the
/// warning are for. Only TIFF is treated this way: multi-frame GIF and HEIC
/// files are animations, not documents.
private func multiPageCount(_ source: CGImageSource, type: String) -> Int? {
    guard type == UTType.tiff.identifier else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count > 1 else { return nil }
    guard let first = pixelSize(source, at: 0) else { return nil }
    // A thumbnail is normally the second IFD, so checking the first few pages
    // is enough; the cap keeps a pathological thousand-page TIFF from making
    // the cycle walk every IFD.
    for index in 1..<min(count, 64) where pixelSize(source, at: index) != first {
        return nil
    }
    return count
}

/// The pixel dimensions of one image in an image source.
private func pixelSize(_ source: CGImageSource, at index: Int) -> CGSize? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        return nil
    }
    return CGSize(width: width, height: height)
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
/// cannot be identified. A dynamic UTI (`dyn.…`) is unique to an unknown
/// extension and no app can ask for it, so it is reported as `public.data`
/// instead.
func uti(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    guard let type = UTType(filenameExtension: ext), !type.isDynamic else {
        return UTType.data.identifier
    }
    return type.identifier
}

/// The type for bytes whose declared text extension turned out not to be text.
///
/// A plain-text UTI would promise UTF-8 that is not there and would collide
/// with a real text file in the same batch. A known non-text UTI (a binary
/// `.plist` is still `com.apple.property-list`) is kept, because the bytes
/// really may be that document type.
func binaryUTI(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext), !type.isDynamic, type.conforms(to: .text) {
        return UTType.data.identifier
    }
    return uti(for: url)
}

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

/// The size limits of the pasteboard payloads.
///
/// They exist to keep the pasteboard (and the machine) alive: a text file is
/// copied into memory three times over, an image or PDF byte for byte. The
/// user may lower them; a hard ceiling keeps them from being removed.
struct ClipLimits {
    /// Largest text file that is embedded as text.
    var text: Int
    /// Largest generic file whose bytes are embedded.
    var embed: Int
    /// Largest image or PDF that is materialised.
    var materialise: Int

    static let `default` = ClipLimits(
        text: Constants.textLimitBytes,
        embed: Constants.embedLimitBytes,
        materialise: Constants.materialiseLimitBytes
    )
}

/// One file and the representation it should get on the pasteboard.
struct ClipPayload {
    /// The kind that is actually written.
    var kind: FileKind
    var url: URL
    /// The UTI of the embedded bytes, if there are any.
    var uti: String?
    /// The embedded bytes.
    var data: Data?
    /// Page count of a PDF or a multi-page TIFF, when it could be read.
    var pageCount: Int?
}

/// The outcome of preparing a batch of files.
struct ClipBatch {
    /// The kind written for every input; `nil` when the file could not be read.
    var kinds: [FileKind?]
    /// Input indexes that could not be prepared, with the reason.
    var failures: [(index: Int, error: Error)]
}

/// Writes several files in one pasteboard transaction.
///
/// Every file is read and prepared *before* the pasteboard is touched, so an
/// unreadable file leaves the previous clipboard intact. Only a single value
/// per pasteboard type can exist: the first file of each type contributes its
/// bytes.
@discardableResult
func putFilesOnClipboard(urls: [URL], limits: ClipLimits) throws -> [FileKind] {
    guard !urls.isEmpty else { return [] }
    let prepared = prepareClipBatch(urls: urls, limits: limits)
    if let failure = prepared.failures.first {
        throw failure.error
    }
    try writeClipPayloads(prepared.payloads)
    return prepared.payloads.map { $0.kind }
}

/// Prepares and writes as much of a batch as possible.
///
/// A file that cannot be read does not stop the others: the readable files are
/// written in one transaction and the failures are reported per input index.
/// The caller must not mark failed files as handled.
func putFilesOnClipboardBestEffort(urls: [URL], limits: ClipLimits) throws -> ClipBatch {
    guard !urls.isEmpty else { return ClipBatch(kinds: [], failures: []) }
    let prepared = prepareClipBatch(urls: urls, limits: limits)
    if !prepared.payloads.isEmpty {
        try writeClipPayloads(prepared.payloads)
    }
    return ClipBatch(kinds: prepared.kinds, failures: prepared.failures)
}

// MARK: - Preparation

private struct PreparedBatch {
    var payloads: [ClipPayload]
    var kinds: [FileKind?]
    var failures: [(index: Int, error: Error)]
}

/// Reads every file that needs bytes on the pasteboard.
///
/// Each file is identified from its content once (see `inspectFile`), and only
/// the first file of each pasteboard type is materialised. A pasteboard holds
/// one value per type, so reading a second text file (or a second PNG) would
/// waste time and memory without changing what can be pasted.
private func prepareClipBatch(urls: [URL], limits: ClipLimits) -> PreparedBatch {
    var payloads: [ClipPayload] = []
    var actual: [FileKind?] = Array(repeating: nil, count: urls.count)
    var failures: [(Int, Error)] = []
    var embeddedTypes = Set<String>()
    var embeddedText = false

    for index in urls.indices {
        let inspection = inspectFile(urls[index])
        let embed: Bool
        switch inspection.kind {
        case .text:
            embed = !embeddedText
        case .image, .pdf, .other:
            // The representation is identified by its UTI, not its name: a
            // PNG named `.jpg` and a real PNG share one pasteboard type.
            embed = !embeddedTypes.contains(inspection.uti ?? inspection.kind.rawValue)
        }

        do {
            let payload = try payload(for: inspection, url: urls[index], limits: limits, embed: embed)
            if payload.data != nil {
                if payload.kind == .text {
                    embeddedText = true
                } else if let uti = payload.uti {
                    embeddedTypes.insert(uti)
                }
            }
            actual[index] = payload.kind
            payloads.append(payload)
        } catch {
            failures.append((index, error))
        }
    }
    return PreparedBatch(payloads: payloads, kinds: actual, failures: failures)
}

/// Builds the representation for one file.
///
/// `embed` is false for files whose type is already represented: they only
/// need the file reference, so their bytes are never read.
private func payload(for inspection: FileInspection, url: URL, limits: ClipLimits,
                     embed: Bool) throws -> ClipPayload {
    guard embed else {
        return ClipPayload(kind: inspection.kind, url: url, uti: nil, data: nil, pageCount: nil)
    }
    guard let size = fileSize(of: url) else {
        // A file whose size cannot be read is not safe to read into memory:
        // retry on the next cycle instead of bypassing the limits.
        throw ClipboardError.writeFailed("could not read the file size")
    }

    switch inspection.kind {
    case .text:
        // A text file that is too big to embed is offered as a file
        // reference instead — otherwise it would cost three times its size in
        // memory.
        guard size <= limits.text else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        guard let raw = try readCapped(url, limit: limits.text) else {
            // The file grew between the stat and the read. Do not blow the
            // memory budget: offer the file reference instead.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        // The text is normalized to UTF-8: a UTF-8 BOM is dropped and a
        // BOM-marked UTF-16 file is transcoded. Bytes that are not text at all
        // fall through to the generic representation.
        guard let text = decodeText(raw) else {
            return ClipPayload(kind: .other, url: url, uti: binaryUTI(for: url),
                               data: raw, pageCount: nil)
        }
        let encoded = Data(text.utf8)
        // UTF-16 expands when it becomes UTF-8; a file that no longer fits the
        // text budget is offered as a file reference instead.
        guard encoded.count <= limits.text else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        return ClipPayload(kind: .text, url: url, uti: UTType.utf8PlainText.identifier,
                           data: encoded, pageCount: nil)

    case .image, .pdf:
        // An empty file has no content to paste; the file reference is the
        // only useful representation.
        guard size > 0 else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        guard size <= limits.materialise else {
            // Too big to materialise: the file reference is the best that can
            // be offered.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        guard let data = try readCapped(url, limit: limits.materialise) else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        // `inspection.uti` is the type the bytes really are. The extension is
        // only a fallback for a PDF whose header could not be read.
        return ClipPayload(kind: inspection.kind, url: url,
                           uti: inspection.uti ?? uti(for: url), data: data,
                           pageCount: inspection.pageCount)

    case .other:
        // A zero-byte file has no bytes to offer under any type.
        guard size > 0 else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        guard size <= limits.embed else {
            // A file over the limit is never embedded, so it never has to be
            // read into memory at all.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        guard let data = try readCapped(url, limit: limits.embed) else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil, pageCount: nil)
        }
        return ClipPayload(kind: .other, url: url, uti: inspection.uti ?? uti(for: url),
                           data: data, pageCount: nil)
    }
}

/// Reads a file, but never more than `limit` bytes.
///
/// The size check in `payload(for:)` is only a snapshot; a file that grows
/// between the stat and the read would otherwise bypass the memory limit.
/// Returns nil when the file is larger than the limit.
private func readCapped(_ url: URL, limit: Int) throws -> Data? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    return data.count > limit ? nil : data
}

// MARK: - Writing

/// Writes prepared payloads in a single pasteboard transaction.
///
/// A single text or image only carries its own representation (§2.2). A PDF —
/// and a TIFF with several equal-sized pages — also carries a file reference:
/// the document data is complete, but macOS coerces it to a single image (the
/// first page/frame), so any app that cannot take the document data would
/// silently lose the other pages. The file reference lets those apps (and the
/// Finder) get the whole document. File references are also added for a
/// generic ("Other") file — which has no previewable content — and for a
/// multi-file batch, where they are the only way to offer every file. A
/// pasteboard holds one value per type, so only the first file of each type
/// contributes bytes.
private func writeClipPayloads(_ payloads: [ClipPayload]) throws {
    guard !payloads.isEmpty else { return }

    let includeFileReferences = payloads.count > 1
        || payloads.contains { $0.kind == .other || $0.kind == .pdf || ($0.pageCount ?? 0) > 1 }

    // Everything is prepared on independent `NSPasteboardItem`s first. The
    // system pasteboard is cleared only after every item has been built, so a
    // read or representation failure cannot destroy the previous clipboard.
    // AppKit synthesises the legacy `NSFilenamesPboardType` from the file URLs
    // itself; setting it on an `NSPasteboardItem` is rejected as an invalid
    // UTI, so it is deliberately not set here.
    var items: [NSPasteboardItem] = []
    var writtenTypes = Set<String>()
    for payload in payloads {
        let item = NSPasteboardItem()
        if includeFileReferences {
            guard item.setString(payload.url.absoluteString, forType: .fileURL) else {
                throw ClipboardError.writeFailed("public.file-url")
            }
        }
        if let uti = payload.uti, let data = payload.data {
            // Text is offered under both the legacy and the modern identifier:
            // NSTextView pastes the former, apps built on `UTType.plainText`
            // ask for the latter and would otherwise get an empty pasteboard.
            let types = payload.kind == .text ? [uti, UTType.plainText.identifier] : [uti]
            for type in types where !writtenTypes.contains(type) {
                writtenTypes.insert(type)
                guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else {
                    throw ClipboardError.writeFailed(type)
                }
            }
        }
        items.append(item)
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects(items) else {
        throw ClipboardError.writeFailed("pasteboard transaction")
    }

    // A multi-page document is complete on the pasteboard, but an app that
    // only accepts images still receives the rasterised first page. Say so
    // instead of letting the other pages disappear silently — for a PDF and
    // for a TIFF with several equal-sized pages.
    for payload in payloads {
        guard let pages = payload.pageCount, pages > 1 else { continue }
        let kind = payload.kind == .pdf ? "pdf" : "image"
        Logger.log(.info, kind,
                   "\(displayPath(payload.url)) has \(pages) pages — an app that only accepts images receives the first page")
    }
}

/// The size of a file in bytes, or nil when it cannot be determined.
///
/// A fresh URL is used on purpose: the resource values of a URL that was
/// used before are cached, and a stale size would make the limit checks
/// decide on old numbers.
func fileSize(of url: URL) -> Int? {
    let fresh = URL(fileURLWithPath: url.path)
    do {
        return try fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize
    } catch {
        return nil
    }
}

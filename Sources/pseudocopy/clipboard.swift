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
}

/// The outcome of preparing a batch of files.
struct ClipBatch {
    /// The kind written for every input; `nil` when the file could not be read.
    var kinds: [FileKind?]
    /// Input indexes that could not be prepared, with the reason.
    var failures: [(index: Int, error: Error)]
}

/// Writes one file to the general pasteboard using the representation that
/// matches its type (§2.2).
@discardableResult
func putOnClipboard(kind: FileKind, url: URL, limits: ClipLimits) throws -> FileKind {
    try putFilesOnClipboard(kinds: [kind], urls: [url], limits: limits)[0]
}

/// Writes several files in one pasteboard transaction.
///
/// Every file is read and prepared *before* the pasteboard is touched, so an
/// unreadable file leaves the previous clipboard intact. Only a single value
/// per pasteboard type can exist: the first file of each type contributes its
/// bytes.
@discardableResult
func putFilesOnClipboard(kinds: [FileKind], urls: [URL], limits: ClipLimits) throws -> [FileKind] {
    guard !urls.isEmpty else { return [] }
    let prepared = prepareClipBatch(kinds: kinds, urls: urls, limits: limits)
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
func putFilesOnClipboardBestEffort(kinds: [FileKind], urls: [URL], limits: ClipLimits) throws -> ClipBatch {
    guard !urls.isEmpty else { return ClipBatch(kinds: [], failures: []) }
    let prepared = prepareClipBatch(kinds: kinds, urls: urls, limits: limits)
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
/// Only the first file of each pasteboard type is materialised. A pasteboard
/// holds one value per type, so reading a second text file (or a second PNG)
/// would waste time and memory without changing what can be pasted.
private func prepareClipBatch(kinds: [FileKind], urls: [URL], limits: ClipLimits) -> PreparedBatch {
    precondition(kinds.count == urls.count)
    var payloads: [ClipPayload] = []
    var actual: [FileKind?] = Array(repeating: nil, count: urls.count)
    var failures: [(Int, Error)] = []
    var embeddedTypes = Set<String>()
    var embeddedText = false

    for index in urls.indices {
        let kind = kinds[index]
        let embed: Bool
        switch kind {
        case .text:
            embed = !embeddedText
        case .image, .pdf, .other:
            embed = !embeddedTypes.contains(uti(for: urls[index]))
        }

        do {
            let payload = try payload(for: kind, url: urls[index], limits: limits, embed: embed)
            if let uti = payload.uti, payload.data != nil {
                if payload.kind == .text {
                    embeddedText = true
                } else {
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
private func payload(for kind: FileKind, url: URL, limits: ClipLimits, embed: Bool) throws -> ClipPayload {
    guard embed else {
        return ClipPayload(kind: kind, url: url, uti: nil, data: nil)
    }
    guard let size = fileSize(of: url) else {
        // A file whose size cannot be read is not safe to read into memory:
        // retry on the next cycle instead of bypassing the limits.
        throw ClipboardError.writeFailed("could not read the size of \(url.lastPathComponent)")
    }

    switch kind {
    case .text:
        // A text file that is too big to embed is offered as a file
        // reference instead — otherwise it would cost three times its size in
        // memory.
        guard size <= limits.text else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        guard let raw = try readCapped(url, limit: limits.text) else {
            // The file grew between the stat and the read. Do not blow the
            // memory budget: offer the file reference instead.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        // The bytes are written unchanged (§2.2), but they have to be valid
        // UTF-8 — otherwise this falls through to the generic handling.
        guard String(data: raw, encoding: .utf8) != nil else {
            return ClipPayload(kind: .other, url: url, uti: uti(for: url), data: raw)
        }
        return ClipPayload(kind: .text, url: url, uti: "public.utf8-plain-text", data: raw)

    case .image, .pdf:
        guard size <= limits.materialise else {
            // Too big to materialise: the file reference is the best that can
            // be offered.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        guard let data = try readCapped(url, limit: limits.materialise) else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        return ClipPayload(kind: kind, url: url, uti: uti(for: url), data: data)

    case .other:
        guard size <= limits.embed else {
            // A file over the limit is never embedded, so it never has to be
            // read into memory at all.
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        guard let data = try readCapped(url, limit: limits.embed) else {
            return ClipPayload(kind: .other, url: url, uti: nil, data: nil)
        }
        return ClipPayload(kind: .other, url: url, uti: uti(for: url), data: data)
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

/// The UTI a file's bytes are written under.
private func uti(for url: URL) -> String {
    UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
}

// MARK: - Writing

/// Writes prepared payloads in a single pasteboard transaction.
///
/// A single text, image or PDF only carries its own representation (§2.2).
/// File references are added for a generic ("Other") file — which has no
/// previewable content — and for a multi-file batch, where they are the only
/// way to offer every file to the Finder. A pasteboard holds one value per
/// type, so only the first file of each type contributes bytes.
private func writeClipPayloads(_ payloads: [ClipPayload]) throws {
    guard !payloads.isEmpty else { return }

    let includeFileReferences = payloads.count > 1 || payloads.contains { $0.kind == .other }

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
        if let uti = payload.uti, let data = payload.data, !writtenTypes.contains(uti) {
            writtenTypes.insert(uti)
            guard item.setData(data, forType: NSPasteboard.PasteboardType(uti)) else {
                throw ClipboardError.writeFailed(uti)
            }
        }
        items.append(item)
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects(items) else {
        throw ClipboardError.writeFailed("pasteboard transaction")
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

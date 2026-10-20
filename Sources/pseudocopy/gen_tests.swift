import Foundation

// PLAN.md §3: gen_tests.swift — sample file generator (§6, Phase 8).

/// A 1×1 pixel PNG — the smallest valid PNG.
private let samplePNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

/// Writes the sample file set used for manual and scripted testing:
/// `sample.txt`, `sample.png`, `sample.jpg`, `sample.gif`, `sample.tiff`,
/// `sample.pdf`, `sample.bin` and a `sample.still-downloading.crdownload`
/// decoy that must be ignored.
func generateTestFiles(_ paths: [String]) throws {
    guard let target = paths.first else {
        throw CLIError.usage("gen-tests needs a target directory")
    }
    let dir = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // --- text ------------------------------------------------------------
    let textURL = dir.appendingPathComponent("sample.txt")
    try Data("pseudocopy test\n".utf8).write(to: textURL)
    print("wrote \(textURL.path)")

    // --- png -------------------------------------------------------------
    let pngURL = dir.appendingPathComponent("sample.png")
    guard let png = Data(base64Encoded: samplePNGBase64) else {
        throw CLIError.usage("could not decode the embedded PNG")
    }
    try png.write(to: pngURL)
    print("wrote \(pngURL.path)")

    // --- jpg / gif / tiff (re-encoded from the PNG with sips) ------------
    for (name, format) in [("sample.jpg", "jpeg"), ("sample.gif", "gif"), ("sample.tiff", "tiff")] {
        let destination = dir.appendingPathComponent(name)
        do {
            try convertImage(from: pngURL, to: destination, format: format)
            print("wrote \(destination.path)")
        } catch {
            Logger.log(.error, "gen-tests", "\(name): \(error.localizedDescription)")
        }
    }

    // --- pdf -------------------------------------------------------------
    let pdfURL = dir.appendingPathComponent("sample.pdf")
    try minimalPDF().write(to: pdfURL)
    print("wrote \(pdfURL.path)")

    // --- binary ----------------------------------------------------------
    let binURL = dir.appendingPathComponent("sample.bin")
    var generator = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255, using: &generator)
    }
    try Data(bytes).write(to: binURL)
    print("wrote \(binURL.path)")

    // --- partial download decoy -------------------------------------------
    let partialURL = dir.appendingPathComponent("sample.still-downloading.crdownload")
    try Data("partial download in progress\n".utf8).write(to: partialURL)
    print("wrote \(partialURL.path)")
}

/// Re-encodes an image with `sips`.
private func convertImage(from source: URL, to destination: URL, format: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-s", "format", format, source.path, "--out", destination.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let output = String(data: data, encoding: .utf8) ?? "sips failed"
        throw CLIError.usage("sips could not convert \(source.lastPathComponent): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

/// A minimal single page PDF with a correct cross reference table.
private func minimalPDF() -> Data {
    let stream = "BT /F1 18 Tf 20 100 Td (pseudocopy) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]

    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }

    let xrefOffset = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n"
    pdf += "0000000000 65535 f \n"
    for offset in offsets {
        pdf += String(format: "%010d 00000 n \n", offset)
    }
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
    return Data(pdf.utf8)
}

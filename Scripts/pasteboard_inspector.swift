import AppKit
import Foundation

// A tiny pasteboard probe for Scripts/smoke.sh.
//
// AppKit has no command-line equivalent of `pbpaste` for the representation
// set: `pbpaste` prints the text representation and nothing else. The smoke
// test compiles this file and uses it to assert what is *really* on the
// clipboard after a clip.
//
// Commands:
//   types                 one pasteboard type per line
//   has <type> [<size>]   exit 0 when the type is present (and has that size)
//   size <type>           print the byte count
//   string <type>         print the bytes decoded as UTF-8
//   file-urls             one file path per line
//   save <path>           write the whole clipboard to a binary plist
//   restore <path>        put that snapshot back

let pasteboard = NSPasteboard.general
let arguments = CommandLine.arguments

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func requireArgument(_ index: Int, _ what: String) -> String {
    guard arguments.count > index else { die("missing \(what)") }
    return arguments[index]
}

func data(for name: String) -> Data? {
    pasteboard.data(forType: NSPasteboard.PasteboardType(name))
}

switch arguments.count > 1 ? arguments[1] : "types" {
case "types":
    for type in pasteboard.types ?? [] {
        print(type.rawValue)
    }

case "has":
    let name = requireArgument(2, "type")
    guard let contents = data(for: name) else { exit(1) }
    if arguments.count > 3 {
        guard let expected = Int(arguments[3]), contents.count == expected else { exit(1) }
    }

case "size":
    guard let contents = data(for: requireArgument(2, "type")) else { exit(1) }
    print(contents.count)

case "string":
    guard let contents = data(for: requireArgument(2, "type")),
          let text = String(data: contents, encoding: .utf8) else { exit(1) }
    print(text, terminator: "")

case "file-urls":
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    for url in objects {
        print(url.path)
    }
    if objects.isEmpty { exit(1) }

case "save":
    let path = requireArgument(2, "path")
    var contents: [String: Data] = [:]
    for type in pasteboard.types ?? [] {
        if let contentsForType = data(for: type.rawValue) {
            contents[type.rawValue] = contentsForType
        }
    }
    let format = PropertyListSerialization.PropertyListFormat.binary
    guard let encoded = try? PropertyListSerialization.data(
        fromPropertyList: contents, format: format, options: 0
    ) else {
        die("could not encode the clipboard")
    }
    do {
        try encoded.write(to: URL(fileURLWithPath: path))
    } catch {
        die("could not write \(path): \(error.localizedDescription)")
    }

case "restore":
    let path = requireArgument(2, "path")
    var format = PropertyListSerialization.PropertyListFormat.binary
    guard let encoded = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let contents = try? PropertyListSerialization.propertyList(
            from: encoded, options: [], format: &format
          ) as? [String: Data] else {
        die("could not read \(path)")
    }
    // Legacy type names (e.g. "Apple HTML pasteboard type") are not valid
    // UTIs and are rejected by AppKit; the rest of the snapshot still
    // restores.
    pasteboard.clearContents()
    if !contents.isEmpty {
        let item = NSPasteboardItem()
        for (type, contentsForType) in contents {
            _ = item.setData(contentsForType, forType: NSPasteboard.PasteboardType(type))
        }
        if !pasteboard.writeObjects([item]) {
            die("could not write the snapshot")
        }
    }

default:
    die("unknown command '\(arguments[1])'")
}

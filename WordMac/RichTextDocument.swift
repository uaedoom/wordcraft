import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx")!
    static let dotx = UTType("org.openxmlformats.wordprocessingml.template") ?? UTType(filenameExtension: "dotx")!
    /// WordMac document package: content.rtf + layout.json.
    static let wordMac = UTType(exportedAs: "com.gamemagic.wordmac.document", conformingTo: .package)
}

/// Document model. The NSTextStorage is shared with the page engine, so it is the single source of truth.
final class RichTextDocument: ReferenceFileDocument {
    struct Snap { var rtf: Data; var archive: Data?; var meta: Data; var assets: [String: Data]; var docx: Data? = nil }
    typealias Snapshot = Snap

    static var readableContentTypes: [UTType] { [.wordMac, .docx, .dotx, .rtf, .plainText, .html] }
    /// Other formats open as imports (Save As prompts for a new WordCraft file); File ▸ Export As writes them.
    static var writableContentTypes: [UTType] { [.wordMac] }

    let storage: NSTextStorage
    var meta = DocMeta()
    let assets = AssetStore()

    init() {
        storage = NSTextStorage()
        if let p = PendingDocument.payload {
            PendingDocument.payload = nil
            meta = p.meta
            assets.data = p.assets
            storage.setAttributedString(p.attributed)
            AttachmentBuilder.restore(storage, assets: assets)
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["WORDMAC_DEMO"] != nil {
            storage.setAttributedString(DemoContent.make())
        }
        #endif
    }

    struct Loaded { var attributed: NSAttributedString; var meta = DocMeta(); var assets: [String: Data] = [:] }

    static func load(_ file: FileWrapper) throws -> Loaded {
        var out: Loaded?
        if file.isDirectory {
            let kids = file.fileWrappers ?? [:]
            var meta = DocMeta()
            if let json = kids["meta.json"]?.regularFileContents, let m = try? JSONDecoder().decode(DocMeta.self, from: json) {
                meta = m
            } else if let json = kids["layout.json"]?.regularFileContents, let l = try? JSONDecoder().decode(LayoutSettings.self, from: json) {
                meta.layout = l
            }
            var assets: [String: Data] = [:]
            if let dir = kids["assets"]?.fileWrappers {
                for (id, w) in dir { if let d = w.regularFileContents { assets[id] = d } }
            }
            var attributed: NSAttributedString?
            if let data = kids["content.archive"]?.regularFileContents, let u = try? NSKeyedUnarchiver(forReadingFrom: data) {
                u.requiresSecureCoding = false
                attributed = u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString
                u.finishDecoding()
            }
            if attributed == nil, let rtf = kids["content.rtf"]?.regularFileContents {
                attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            }
            if let attributed { out = Loaded(attributed: attributed, meta: meta, assets: assets) }
        } else if let data = file.regularFileContents {
            if data.starts(with: [0x50, 0x4B]) {                                   // zip → Word document
                guard let r = DocxReader.read(data) else { throw CocoaError(.fileReadCorruptFile) }
                out = Loaded(attributed: r.attributed, meta: r.meta, assets: r.assets)
            } else if data.starts(with: Array("{\\rtf".utf8)) {
                out = Loaded(attributed: try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
            } else if let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased(), head.contains("<html") || head.contains("<!doctype html") || head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                out = Loaded(attributed: try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil))
            } else if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                var m = DocMeta()
                m.styles = DocMeta().styles
                let attrs = m.style("normal")?.attributes(preserving: nil) ?? [:]
                out = Loaded(attributed: NSAttributedString(string: text.replacingOccurrences(of: "\r\n", with: "\n"), attributes: attrs), meta: m)
            }
        }
        guard let out else { throw CocoaError(.fileReadCorruptFile) }
        return out
    }

    required init(configuration: ReadConfiguration) throws {
        let l = try Self.load(configuration.file)
        meta = l.meta
        assets.data = l.assets
        storage = NSTextStorage(attributedString: l.attributed)
        AttachmentBuilder.restore(storage, assets: assets)
    }

    func snapshot(contentType: UTType) throws -> Snap {
        if contentType == .docx {
            var snap = Snap(rtf: Data(), archive: nil, meta: Data(), assets: [:])
            snap.docx = DocxWriter(storage: storage, meta: meta, assets: assets).write()
            return snap
        }
        let plain = AttachmentBuilder.stripped(storage)
        let range = NSRange(location: 0, length: plain.length)
        let rtf = try plain.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let archive = try? NSKeyedArchiver.archivedData(withRootObject: plain, requiringSecureCoding: false)
        // drop objects whose anchor character was deleted
        var anchors = Set<String>()
        storage.enumerateAttribute(.wcObject, in: NSRange(location: 0, length: storage.length), options: []) { v, _, _ in
            if let id = v as? String { anchors.insert(id) }
        }
        var m = meta
        m.objects = m.objects.filter { anchors.contains($0.key) }
        return Snap(rtf: rtf, archive: archive, meta: try JSONEncoder().encode(m), assets: assets.data)
    }

    static func wrapper(_ snapshot: Snap) -> FileWrapper {
        var kids: [String: FileWrapper] = [
            "content.rtf": FileWrapper(regularFileWithContents: snapshot.rtf),
            "meta.json": FileWrapper(regularFileWithContents: snapshot.meta),
        ]
        if let a = snapshot.archive { kids["content.archive"] = FileWrapper(regularFileWithContents: a) }
        if !snapshot.assets.isEmpty {
            kids["assets"] = FileWrapper(directoryWithFileWrappers: snapshot.assets.mapValues { FileWrapper(regularFileWithContents: $0) })
        }
        return FileWrapper(directoryWithFileWrappers: kids)
    }

    func fileWrapper(snapshot: Snap, configuration: WriteConfiguration) throws -> FileWrapper {
        // Files opened as plain RTF are saved back as RTF (styles and page setup are not stored in that format).
        if configuration.contentType == .docx, let d = snapshot.docx {
            return FileWrapper(regularFileWithContents: d)
        }
        if configuration.contentType == .rtf {
            return FileWrapper(regularFileWithContents: snapshot.rtf)
        }
        return Self.wrapper(snapshot)
    }
}

#if DEBUG
enum DemoContent {
    static func make() -> NSAttributedString {
        let base = EditorController.defaultFont
        let out = NSMutableAttributedString()
        func add(_ s: String, size: CGFloat = 12, bold: Bool = false, italic: Bool = false, extra: [NSAttributedString.Key: Any] = [:]) {
            var f = NSFontManager.shared.convert(base, toSize: size)
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            var a: [NSAttributedString.Key: Any] = [.font: f]
            a.merge(extra) { $1 }
            out.append(NSAttributedString(string: s, attributes: a))
        }
        add("Quarterly Report\n", size: 28)
        add("Heading One\n", size: 20, bold: true)
        add("This is a ", size: 12)
        add("bold", bold: true)
        add(", ", size: 12)
        add("italic", italic: true)
        add(" and ", size: 12)
        add("underlined", extra: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        add(" sample paragraph used to check rendering. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.\n", size: 12)
        add("Second paragraph with a highlight.\n", extra: [.backgroundColor: NSColor.yellow])
        add("Item one\nItem two\nItem three\n")
        for i in 0..<max(0, (Int(ProcessInfo.processInfo.environment["WORDMAC_DEMO"] ?? "") ?? 1) - 1) {
            add("Section \(i + 1)\n", size: 16, bold: true)
            add("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.\n")
        }
        return out
    }
}
#endif

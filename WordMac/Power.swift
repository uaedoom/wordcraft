import AppKit

extension NSAttributedString.Key {
    /// Mail-merge field name on a «Field» placeholder (or its substituted value).
    static let wcMerge = NSAttributedString.Key("wc.merge")
    static let wcMergeValue = NSAttributedString.Key("wc.mergeValue")
    /// "tag|page" on a generated citation.
    static let wcCite = NSAttributedString.Key("wc.cite")
    /// Marks the generated bibliography block.
    static let wcBib = NSAttributedString.Key("wc.bib")
    static let wcBookmark = NSAttributedString.Key("wc.bookmark")
    /// JSON {name, what} on a generated cross-reference.
    static let wcXref = NSAttributedString.Key("wc.xref")
    /// Caption label ("Figure", "Table") on the "Figure 3" text of a caption.
    static let wcCaption = NSAttributedString.Key("wc.caption")
    /// "main|sub" index entry on the marked text.
    static let wcIndex = NSAttributedString.Key("wc.index")
    static let wcIndexBlock = NSAttributedString.Key("wc.indexBlock")
    /// JSON ControlProps on a content control's text.
    static let wcControl = NSAttributedString.Key("wc.control")
}

struct Source: Codable, Equatable, Identifiable {
    var id: String                 // citation tag, e.g. "Smith2020"
    var kind = "book"              // book, article, website, report
    var authors = ""               // "Smith, John; Doe, Jane"
    var title = ""
    var year = ""
    var publisher = ""
    var city = ""
    var container = ""             // journal / website / book title
    var volume = ""
    var issue = ""
    var pages = ""
    var url = ""
    var accessed = ""
}

struct MergeData: Codable, Equatable {
    var columns: [String] = []
    var rows: [[String]] = []

    /// Parses CSV/TSV with quoted fields.
    static func parse(_ text: String) -> MergeData {
        let first = text.prefix(while: { $0 != "\n" })
        let delim: Character = first.filter { $0 == "\t" }.count > first.filter { $0 == "," }.count ? "\t" : (first.filter { $0 == ";" }.count > first.filter { $0 == "," }.count ? ";" : ",")
        var rows: [[String]] = [], row: [String] = [], field = "", inQuotes = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false } }
                else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == delim { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        rows.removeAll { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let head = rows.first else { return MergeData() }
        let cols = head.map { $0.trimmingCharacters(in: .whitespaces) }
        let body = rows.dropFirst().map { r in (0..<cols.count).map { $0 < r.count ? r[$0] : "" } }
        return MergeData(columns: cols, rows: Array(body))
    }
}

struct ControlProps: Codable, Equatable, Identifiable {
    var id: String
    var kind: String               // text, dropdown, date, checkbox
    var title = ""
    var placeholder = "Click here to enter text"
    var options: [String] = []

    var json: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
    static func decode(_ v: Any?) -> ControlProps? {
        guard let s = v as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ControlProps.self, from: d)
    }
}

struct XrefProps: Codable, Equatable {
    var name: String
    var what: String               // text, page
    var json: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
    static func decode(_ v: Any?) -> XrefProps? {
        guard let s = v as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(XrefProps.self, from: d)
    }
}

/// Content for the next document SwiftUI creates, so templates and merge results open as new untitled documents.
enum PendingDocument {
    static var payload: (attributed: NSAttributedString, meta: DocMeta, assets: [String: Data])?
}

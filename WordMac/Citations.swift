import AppKit

enum CitationStyle: String, CaseIterable, Identifiable {
    case apa, mla, chicago, ieee
    var id: String { rawValue }
    var title: String {
        switch self { case .apa: "APA (7th)"; case .mla: "MLA (9th)"; case .chicago: "Chicago (author-date)"; case .ieee: "IEEE" }
    }
    var bibliographyTitle: String {
        switch self { case .apa, .ieee: "References"; case .mla: "Works Cited"; case .chicago: "Bibliography" }
    }
}

/// Formats in-text citations and bibliography entries.
enum CitationFormatter {
    struct Name { var last: String; var first: String }

    static func names(_ s: Source) -> [Name] {
        s.authors.split(separator: ";").map { part in
            let p = part.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return Name(last: p.first ?? "", first: p.count > 1 ? p[1] : "")
        }.filter { !$0.last.isEmpty }
    }

    private static func initials(_ first: String) -> String {
        first.split(whereSeparator: { $0 == " " || $0 == "-" }).compactMap { $0.first.map { "\(String($0).uppercased())." } }.joined(separator: " ")
    }

    static func inText(_ s: Source, style: CitationStyle, page: String, number: Int) -> String {
        let n = names(s)
        let lastNames = n.map(\.last)
        func who(and: String) -> String {
            switch lastNames.count {
            case 0: return s.title.split(separator: ":").first.map { "\"\($0)\"" } ?? s.title
            case 1: return lastNames[0]
            case 2: return "\(lastNames[0]) \(and) \(lastNames[1])"
            default: return "\(lastNames[0]) et al."
            }
        }
        switch style {
        case .apa: return "(\(who(and: "&")), \(s.year.isEmpty ? "n.d." : s.year)\(page.isEmpty ? "" : ", p. \(page)"))"
        case .mla: return "(\(who(and: "and"))\(page.isEmpty ? "" : " \(page)"))"
        case .chicago: return "(\(who(and: "and")) \(s.year.isEmpty ? "n.d." : s.year)\(page.isEmpty ? "" : ", \(page)"))"
        case .ieee: return "[\(number)]"
        }
    }

    /// Bibliography entry with italics for titles. `number` is used by IEEE.
    static func entry(_ s: Source, style: CitationStyle, number: Int, font: NSFont) -> NSAttributedString {
        var parts: [(String, Bool)] = []
        let n = names(s)
        func add(_ t: String, _ italic: Bool = false) { if !t.isEmpty { parts.append((t, italic)) } }
        func endDot(_ t: String) -> String { t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") ? t : t + "." }
        let year = s.year.isEmpty ? "n.d." : s.year
        let isArticle = s.kind == "article"
        let isWeb = s.kind == "website"

        switch style {
        case .apa:
            let a: String
            switch n.count {
            case 0: a = ""
            case 1: a = "\(n[0].last), \(initials(n[0].first))"
            default:
                let list = n.prefix(20).map { "\($0.last), \(initials($0.first))" }
                a = list.dropLast().joined(separator: ", ") + ", & " + list.last!
            }
            if !a.isEmpty { add(endDot(a) + " ") }
            add("(\(year)). ")
            if isArticle {
                add(endDot(s.title) + " "); add(s.container, true)
                if !s.volume.isEmpty { add(", "); add(s.volume, true); if !s.issue.isEmpty { add("(\(s.issue))") } }
                if !s.pages.isEmpty { add(", \(s.pages)") }
                add(".")
            } else {
                add(endDot(s.title), true)
                if isWeb { if !s.container.isEmpty { add(" " + endDot(s.container)) } }
                else if !s.publisher.isEmpty { add(" " + endDot(s.publisher)) }
            }
            if !s.url.isEmpty { add(" " + s.url) }
        case .mla:
            let a: String
            switch n.count {
            case 0: a = ""
            case 1: a = "\(n[0].last), \(n[0].first)"
            case 2: a = "\(n[0].last), \(n[0].first), and \(n[1].first) \(n[1].last)"
            default: a = "\(n[0].last), \(n[0].first), et al"
            }
            if !a.isEmpty { add(endDot(a) + " ") }
            if isArticle {
                add("\"\(endDot(s.title))\" "); add(s.container, true)
                if !s.volume.isEmpty { add(", vol. \(s.volume)") }
                if !s.issue.isEmpty { add(", no. \(s.issue)") }
                add(", \(year)")
                if !s.pages.isEmpty { add(", pp. \(s.pages)") }
                add(".")
            } else {
                add(endDot(s.title), true)
                if isWeb, !s.container.isEmpty { add(" \(s.container),") }
                else if !s.publisher.isEmpty { add(" \(s.publisher),") }
                add(" \(year).")
            }
            if !s.url.isEmpty { add(" " + s.url + ".") }
        case .chicago:
            let a: String
            switch n.count {
            case 0: a = ""
            case 1: a = "\(n[0].last), \(n[0].first)"
            case 2: a = "\(n[0].last), \(n[0].first), and \(n[1].first) \(n[1].last)"
            default: a = "\(n[0].last), \(n[0].first), et al"
            }
            if !a.isEmpty { add(endDot(a) + " ") }
            add("\(year). ")
            if isArticle {
                add("\"\(endDot(s.title))\" "); add(s.container, true)
                if !s.volume.isEmpty { add(" \(s.volume)"); if !s.issue.isEmpty { add(" (\(s.issue))") } }
                if !s.pages.isEmpty { add(": \(s.pages)") }
                add(".")
            } else {
                add(endDot(s.title), true)
                if !s.publisher.isEmpty { add(" " + (s.city.isEmpty ? "" : "\(s.city): ") + endDot(s.publisher)) }
            }
            if !s.url.isEmpty { add(" " + s.url + ".") }
        case .ieee:
            add("[\(number)] ")
            let a = n.map { "\(initials($0.first)) \($0.last)" }
            switch a.count {
            case 0: break
            case 1: add(a[0] + ", ")
            case 2: add(a.joined(separator: " and ") + ", ")
            default: add(a.dropLast().joined(separator: ", ") + ", and " + a.last! + ", ")
            }
            if isArticle {
                add("\"\(s.title),\" "); add(s.container, true)
                if !s.volume.isEmpty { add(", vol. \(s.volume)") }
                if !s.issue.isEmpty { add(", no. \(s.issue)") }
                if !s.pages.isEmpty { add(", pp. \(s.pages)") }
                add(", \(year).")
            } else {
                add(s.title, true)
                add(". ")
                if !s.publisher.isEmpty { add((s.city.isEmpty ? "" : "\(s.city): ") + s.publisher + ", ") }
                add("\(year).")
            }
            if !s.url.isEmpty { add(" [Online]. Available: " + s.url) }
        }

        let out = NSMutableAttributedString()
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for (t, it) in parts { out.append(NSAttributedString(string: t, attributes: [.font: it ? italicFont : font])) }
        return out
    }
}

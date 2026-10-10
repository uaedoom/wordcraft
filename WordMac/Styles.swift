import AppKit

extension NSAttributedString.Key {
    /// Paragraph style id (String) set on every character of a styled paragraph.
    static let wcStyle = NSAttributedString.Key("wc.style")
    /// Section break marker; value is the id of the section's stored page setup.
    static let wcSection = NSAttributedString.Key("wc.section")
    static let wcFootnote = NSAttributedString.Key("wc.footnote")
    static let wcEndnote = NSAttributedString.Key("wc.endnote")
    static let wcTOC = NSAttributedString.Key("wc.toc")
    static let wcEndnotes = NSAttributedString.Key("wc.endnotes")
}

struct StyleDef: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var family = "Helvetica Neue"
    var size: CGFloat = 12
    var bold = false
    var italic = false
    var underline = false
    var color: [CGFloat] = [0, 0, 0]
    var alignment = 4            // NSTextAlignment raw: 0 left, 1 right, 2 center, 3 justified, 4 natural (start)
    var spaceBefore: CGFloat = 0
    var spaceAfter: CGFloat = 6
    var lineMultiple: CGFloat = 1.15
    var leftIndent: CGFloat = 0
    var rightIndent: CGFloat = 0
    var firstLine: CGFloat = 0
    var outline = 0              // 0 = body text, 1...6 = heading level
    var next = "normal"
    var gallery = true
    var builtin = false

    var nsColor: NSColor {
        get { NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 1) }
        set {
            let c = newValue.usingColorSpace(.sRGB) ?? .black
            color = [c.redComponent, c.greenComponent, c.blueComponent]
        }
    }

    func font() -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size)
            ?? NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
    }

    /// List paragraphs keep their list indents when a style is applied.
    func attributes(preserving existing: NSParagraphStyle?) -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.alignment = NSTextAlignment(rawValue: alignment) ?? .left
        ps.paragraphSpacingBefore = spaceBefore
        ps.paragraphSpacing = spaceAfter
        ps.lineHeightMultiple = lineMultiple
        ps.headIndent = leftIndent
        ps.firstLineHeadIndent = leftIndent + firstLine
        ps.tailIndent = rightIndent > 0 ? -rightIndent : 0
        if let existing, !existing.textLists.isEmpty {
            ps.textLists = existing.textLists
            ps.headIndent = existing.headIndent
            ps.firstLineHeadIndent = existing.firstLineHeadIndent
            ps.tabStops = existing.tabStops
        }
        return [.font: font(), .foregroundColor: nsColor, .paragraphStyle: ps,
                .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0,
                .wcStyle: id]
    }

    static func make(_ id: String, _ name: String, size: CGFloat = 12, bold: Bool = false, italic: Bool = false,
                     color: [CGFloat] = [0, 0, 0], before: CGFloat = 0, after: CGFloat = 6, outline: Int = 0,
                     next: String = "normal", left: CGFloat = 0, right: CGFloat = 0, gallery: Bool = true) -> StyleDef {
        var s = StyleDef(id: id, name: name)
        s.size = size; s.bold = bold; s.italic = italic; s.color = color
        s.spaceBefore = before; s.spaceAfter = after; s.outline = outline; s.next = next
        s.leftIndent = left; s.rightIndent = right; s.gallery = gallery; s.builtin = true
        return s
    }

    static let blue: [CGFloat] = [0.12, 0.27, 0.5]
    static let gray: [CGFloat] = [0.4, 0.4, 0.4]

    static var defaults: [StyleDef] {
        var list = baseDefaults
        let d = UserDefaults.standard
        if let i = list.firstIndex(where: { $0.id == "normal" }) {
            if let f = d.string(forKey: "wc.defaultFont"), !f.isEmpty { list[i].family = f }
            let sz = d.double(forKey: "wc.defaultSize")
            if sz >= 6 { list[i].size = CGFloat(sz) }
        }
        return list
    }

    private static var baseDefaults: [StyleDef] {
        [
            make("normal", "Normal", next: "normal"),
            make("title", "Title", size: 28, after: 8),
            make("subtitle", "Subtitle", size: 15, italic: true, color: gray, after: 8),
            make("h1", "Heading 1", size: 20, bold: true, color: blue, before: 14, after: 4, outline: 1),
            make("h2", "Heading 2", size: 16, bold: true, color: blue, before: 10, after: 4, outline: 2),
            make("h3", "Heading 3", size: 14, bold: true, color: blue, before: 8, after: 4, outline: 3),
            make("h4", "Heading 4", size: 12, bold: true, italic: true, color: blue, before: 6, after: 3, outline: 4),
            make("h5", "Heading 5", size: 12, color: blue, before: 6, after: 3, outline: 5),
            make("h6", "Heading 6", size: 11, bold: true, color: gray, before: 6, after: 3, outline: 6),
            make("quote", "Quote", italic: true, color: gray, left: 36, right: 36),
            make("tocHeading", "TOC Heading", size: 16, bold: true, color: blue, after: 8, gallery: false),
            make("toc1", "TOC 1", after: 3, gallery: false),
            make("toc2", "TOC 2", after: 3, left: 18, gallery: false),
            make("toc3", "TOC 3", after: 3, left: 36, gallery: false),
            make("caption", "Caption", size: 10, bold: true, color: [0.25, 0.25, 0.25], after: 8),
            make("endnotesHeading", "Endnotes Heading", size: 14, bold: true, before: 18, after: 6, gallery: false),
            make("endnote", "Endnote Text", size: 10, after: 2, gallery: false),
        ]
    }
}

/// Everything about a document that is not the text itself. Saved as meta.json.
struct DocMeta: Codable, Equatable {
    var layout = LayoutSettings()
    var sectionLayouts: [String: LayoutSettings] = [:]
    var styles = StyleDef.defaults
    var notes: [String: String] = [:]
    var objects: [String: FloatingObject] = [:]
    var comments: [String: CommentRec] = [:]
    var protection = Protection()
    var trackChanges = false
    var sources: [Source] = []
    var citationStyle = UserDefaults.standard.string(forKey: "wc.citationStyle") ?? "apa"
    var mergeData: MergeData?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent(LayoutSettings.self, forKey: .layout) ?? LayoutSettings()
        sectionLayouts = try c.decodeIfPresent([String: LayoutSettings].self, forKey: .sectionLayouts) ?? [:]
        styles = try c.decodeIfPresent([StyleDef].self, forKey: .styles) ?? StyleDef.defaults
        notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        objects = try c.decodeIfPresent([String: FloatingObject].self, forKey: .objects) ?? [:]
        comments = try c.decodeIfPresent([String: CommentRec].self, forKey: .comments) ?? [:]
        protection = try c.decodeIfPresent(Protection.self, forKey: .protection) ?? Protection()
        trackChanges = try c.decodeIfPresent(Bool.self, forKey: .trackChanges) ?? false
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        citationStyle = try c.decodeIfPresent(String.self, forKey: .citationStyle) ?? "apa"
        mergeData = try c.decodeIfPresent(MergeData.self, forKey: .mergeData)
    }

    func settings(for key: String?) -> LayoutSettings {
        key.flatMap { sectionLayouts[$0] } ?? layout
    }

    mutating func set(_ l: LayoutSettings, for key: String?) {
        if let key { sectionLayouts[key] = l } else { layout = l }
    }

    func style(_ id: String) -> StyleDef? { styles.first { $0.id == id } }
}

extension LayoutSettings {
    func sameGeometry(as o: LayoutSettings) -> Bool {
        pageWidth == o.pageWidth && pageHeight == o.pageHeight && landscape == o.landscape
            && top == o.top && bottom == o.bottom && left == o.left && right == o.right
            && columns == o.columns && columnSpacing == o.columnSpacing
    }
}


extension String {
    /// True when the first strong letter is from a right-to-left script (Arabic, Hebrew, Syriac, Thaana).
    var startsRightToLeft: Bool {
        for u in unicodeScalars {
            let v = u.value
            if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) { return true }
            if u.properties.isAlphabetic { return false }
        }
        return false
    }
}

import AppKit

/// Writes the document as an Office Open XML (.docx) package.
final class DocxWriter {
    private let storage: NSTextStorage
    private let meta: DocMeta
    private let assets: AssetStore

    private var rels: [(id: String, type: String, target: String, external: Bool)] = []
    private var media: [String: Data] = [:]
    private var assetRel: [String: String] = [:]
    private var linkRel: [String: String] = [:]
    private var relCounter = 10
    private var drawingID = 1
    private var mediaCounter = 1
    private var footnotes: [(id: Int, text: String)] = []
    private var endnotes: [(id: Int, text: String)] = []
    private var extraParts: [(path: String, type: String, xml: String)] = []
    private var numberedNums: [Int] = []
    private var nextNumID = 3
    private var listState: (numbered: Bool, numID: Int)?
    private var headerCount = 0, footerCount = 0
    private var sectionBreaks: [(loc: Int, id: String)] = []
    private var revID = 100
    private var openComment: String?
    private var openBookmark: String?
    private var bookmarkIDs: [String: Int] = [:]
    private var emittedBookmarks: Set<String> = []
    private var commentIDs: [String: Int] = [:]
    private var commentOrder: [String] = []
    private let isoFormatter = ISO8601DateFormatter()

    init(storage: NSTextStorage, meta: DocMeta, assets: AssetStore) {
        self.storage = storage
        self.meta = meta
        self.assets = assets
    }

    static let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\" xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\" mc:Ignorable=\"w14\""

    private func tw(_ pt: CGFloat) -> Int { Int((pt * 20).rounded()) }
    private func emu(_ pt: CGFloat) -> Int { Int((pt * 12700).rounded()) }

    private func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
    }

    static func styleID(_ id: String) -> String {
        let map = ["normal": "Normal", "title": "Title", "subtitle": "Subtitle", "quote": "Quote", "tocHeading": "TOCHeading",
                   "toc1": "TOC1", "toc2": "TOC2", "toc3": "TOC3", "caption": "Caption", "h1": "Heading1", "h2": "Heading2", "h3": "Heading3",
                   "h4": "Heading4", "h5": "Heading5", "h6": "Heading6", "endnotesHeading": "EndnotesHeading", "endnote": "EndnoteBlockText"]
        if let m = map[id] { return m }
        return "S" + id.filter { $0.isLetter || $0.isNumber }
    }

    private func styleName(_ d: StyleDef) -> String {
        switch d.id {
        case "h1", "h2", "h3", "h4", "h5", "h6": return "heading " + d.id.dropFirst()
        case "toc1", "toc2", "toc3": return "toc " + d.id.dropFirst(3)
        case "tocHeading": return "TOC Heading"
        case "caption": return "caption"
        default: return d.name
        }
    }

    // MARK: Relationships

    private func addRel(type: String, target: String, external: Bool = false) -> String {
        relCounter += 1
        let id = "rId\(relCounter)"
        rels.append((id, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/" + type, target, external))
        return id
    }

    private func linkRelID(_ url: String) -> String {
        if let r = linkRel[url] { return r }
        let r = addRel(type: "hyperlink", target: url, external: true)
        linkRel[url] = r
        return r
    }

    private func imageRelID(_ asset: String) -> String? {
        if let r = assetRel[asset] { return r }
        guard var data = assets.data[asset] else { return nil }
        var ext = "png"
        if data.starts(with: [0xFF, 0xD8]) { ext = "jpeg" }
        else if data.starts(with: [0x47, 0x49, 0x46]) { ext = "gif" }
        else if !data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            guard let img = NSImage(data: data), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            data = png
        }
        let path = "media/image\(mediaCounter).\(ext)"
        mediaCounter += 1
        media["word/" + path] = data
        let r = addRel(type: "image", target: path)
        assetRel[asset] = r
        return r
    }

    // MARK: Package

    func write() -> Data {
        var s: [(loc: Int, id: String)] = []
        storage.enumerateAttribute(.wcSection, in: NSRange(location: 0, length: storage.length), options: []) { v, r, _ in
            if let id = v as? String { s.append((r.upperBound - 1, id)) }
        }
        sectionBreaks = s
        let body = bodyXML()
        let finalSect = sectPrXML(meta.layout)
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(Self.ns)><w:body>\(body)\(finalSect)</w:body></w:document>"

        var entries: [Zip.Entry] = []
        func add(_ name: String, _ xml: String) { entries.append(Zip.Entry(name: name, data: Data(xml.utf8))) }
        let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

        var overrides = """
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        """
        add("word/document.xml", document)
        add("word/styles.xml", stylesXML())
        add("word/numbering.xml", numberingXML())
        add("word/settings.xml", settingsXML())
        if !footnotes.isEmpty {
            add("word/footnotes.xml", notesXML(footnotes, kind: "footnote"))
            overrides += "<Override PartName=\"/word/footnotes.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml\"/>"
        }
        if !commentOrder.isEmpty {
            add("word/comments.xml", commentsXML())
            overrides += "<Override PartName=\"/word/comments.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml\"/>"
        }
        if !endnotes.isEmpty {
            add("word/endnotes.xml", notesXML(endnotes, kind: "endnote"))
            overrides += "<Override PartName=\"/word/endnotes.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml\"/>"
        }
        for p in extraParts {
            add(p.path, p.xml)
            overrides += "<Override PartName=\"/\(p.path)\" ContentType=\"\(p.type)\"/>"
        }
        for (path, data) in media.sorted(by: { $0.key < $1.key }) { entries.append(Zip.Entry(name: path, data: data)) }

        // fixed relationships
        var relXML = xmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        relXML += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        relXML += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
        relXML += "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>"
        if !footnotes.isEmpty { relXML += "<Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes\" Target=\"footnotes.xml\"/>" }
        if !endnotes.isEmpty { relXML += "<Relationship Id=\"rId5\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes\" Target=\"endnotes.xml\"/>" }
        if !commentOrder.isEmpty { relXML += "<Relationship Id=\"rId6\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments\" Target=\"comments.xml\"/>" }
        for r in rels {
            relXML += "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(xmlEscape(r.target))\"" + (r.external ? " TargetMode=\"External\"" : "") + "/>"
        }
        relXML += "</Relationships>"
        add("word/_rels/document.xml.rels", relXML)
        add("_rels/.rels", xmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>")
        let now = ISO8601DateFormatter().string(from: Date())
        add("docProps/core.xml", xmlHead + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:creator>WordCraft</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified></cp:coreProperties>")
        add("docProps/app.xml", xmlHead + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>WordCraft</Application></Properties>")
        let types = xmlHead + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Default Extension=\"gif\" ContentType=\"image/gif\"/>\(overrides)</Types>"
        entries.insert(Zip.Entry(name: "[Content_Types].xml", data: Data(types.utf8)), at: 0)
        return Zip.write(entries)
    }

    // MARK: Parts

    private func settingsXML() -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:settings \(Self.ns)>"
        if meta.trackChanges || meta.protection.mode == .trackedChanges { s += "<w:trackRevisions/>" }
        let pr = meta.protection
        if pr.mode != .none {
            let edit = pr.mode == .readOnly ? "readOnly" : (pr.mode == .comments ? "comments" : (pr.mode == .forms ? "forms" : "trackedChanges"))
            s += "<w:documentProtection w:edit=\"\(edit)\" w:enforcement=\"1\""
            if let h = pr.hash, let salt = pr.salt {
                s += " w:cryptProviderType=\"rsaAES\" w:cryptAlgorithmClass=\"hash\" w:cryptAlgorithmType=\"typeAny\" w:cryptAlgorithmSid=\"14\" w:cryptSpinCount=\"\(pr.spin)\" w:hash=\"\(h)\" w:salt=\"\(salt)\""
            }
            s += "/>"
        }
        s += "<w:defaultTabStop w:val=\"720\"/>"
        if !footnotes.isEmpty { s += "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>" }
        if !endnotes.isEmpty { s += "<w:endnotePr><w:endnote w:id=\"-1\"/><w:endnote w:id=\"0\"/></w:endnotePr>" }
        s += "<w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat>"
        return s + "</w:settings>"
    }

    private func numberingXML() -> String {
        func lvl(_ fmt: String, _ text: String) -> String {
            var s = ""
            for i in 0..<9 {
                let left = 720 * (i + 1)
                let t = fmt == "bullet" ? (i % 2 == 0 ? "•" : "o") : "%\(i + 1)."
                s += "<w:lvl w:ilvl=\"\(i)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(t)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr>"
                if fmt == "bullet" { s += "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/></w:rPr>" }
                s += "</w:lvl>"
            }
            return s
        }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering \(Self.ns)>"
        s += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(lvl("bullet", "•"))</w:abstractNum>"
        s += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(lvl("decimal", "%1."))</w:abstractNum>"
        s += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/></w:num>"
        for n in numberedNums {
            s += "<w:num w:numId=\"\(n)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        return s + "</w:numbering>"
    }

    private func notesXML(_ notes: [(id: Int, text: String)], kind: String) -> String {
        let root = kind == "footnote" ? "footnotes" : "endnotes"
        let refStyle = kind == "footnote" ? "FootnoteReference" : "EndnoteReference"
        let textStyle = kind == "footnote" ? "FootnoteText" : "EndnoteText"
        let refEl = kind == "footnote" ? "footnoteRef" : "endnoteRef"
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:\(root) \(Self.ns)>"
        s += "<w:\(kind) w:type=\"separator\" w:id=\"-1\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:separator/></w:r></w:p></w:\(kind)>"
        s += "<w:\(kind) w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:\(kind)>"
        for n in notes {
            s += "<w:\(kind) w:id=\"\(n.id)\"><w:p><w:pPr><w:pStyle w:val=\"\(textStyle)\"/></w:pPr><w:r><w:rPr><w:rStyle w:val=\"\(refStyle)\"/></w:rPr><w:\(refEl)/></w:r><w:r><w:t xml:space=\"preserve\"> \(xmlEscape(n.text))</w:t></w:r></w:p></w:\(kind)>"
        }
        return s + "</w:\(root)>"
    }

    private func commentsXML() -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:comments \(Self.ns)>"
        for (i, id) in commentOrder.enumerated() {
            guard let c = meta.comments[id] else { continue }
            let date = isoFormatter.string(from: Date(timeIntervalSince1970: c.date))
            s += "<w:comment w:id=\"\(i)\" w:author=\"\(xmlEscape(c.author))\" w:date=\"\(date)\" w:initials=\"\(xmlEscape(c.initials))\">"
            s += "<w:p><w:pPr><w:pStyle w:val=\"CommentText\"/></w:pPr><w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:annotationRef/></w:r><w:r><w:t xml:space=\"preserve\">\(xmlEscape(c.text))</w:t></w:r></w:p>"
            for r in c.replies {
                s += "<w:p><w:pPr><w:pStyle w:val=\"CommentText\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(xmlEscape(r.author)): \(xmlEscape(r.text))</w:t></w:r></w:p>"
            }
            s += "</w:comment>"
        }
        return s + "</w:comments>"
    }

    private func stylesXML() -> String {
        let normal = meta.style("normal") ?? StyleDef.make("normal", "Normal")
        func rPr(_ d: StyleDef) -> String {
            var s = "<w:rFonts w:ascii=\"\(xmlEscape(d.family))\" w:hAnsi=\"\(xmlEscape(d.family))\" w:cs=\"\(xmlEscape(d.family))\"/>"
            if d.bold { s += "<w:b/><w:bCs/>" }
            if d.italic { s += "<w:i/><w:iCs/>" }
            s += "<w:color w:val=\"\(hex(d.nsColor))\"/><w:sz w:val=\"\(Int(d.size * 2))\"/><w:szCs w:val=\"\(Int(d.size * 2))\"/>"
            if d.underline { s += "<w:u w:val=\"single\"/>" }
            return s
        }
        func pPr(_ d: StyleDef) -> String {
            var s = ""
            if d.outline > 0 { s += "<w:keepNext/>" }
            s += "<w:spacing w:before=\"\(tw(d.spaceBefore))\" w:after=\"\(tw(d.spaceAfter))\" w:line=\"\(Int(d.lineMultiple * 240))\" w:lineRule=\"auto\"/>"
            if d.leftIndent != 0 || d.rightIndent != 0 || d.firstLine != 0 {
                s += "<w:ind w:left=\"\(tw(d.leftIndent))\" w:right=\"\(tw(d.rightIndent))\" w:firstLine=\"\(tw(max(0, d.firstLine)))\"/>"
            }
            let jc = ["left", "right", "center", "both"]
            if d.alignment != 0 && d.alignment < 4 { s += "<w:jc w:val=\"\(jc[d.alignment])\"/>" }
            if d.outline > 0 { s += "<w:outlineLvl w:val=\"\(d.outline - 1)\"/>" }
            return s
        }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles \(Self.ns)>"
        s += "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"\(xmlEscape(normal.family))\" w:hAnsi=\"\(xmlEscape(normal.family))\" w:cs=\"\(xmlEscape(normal.family))\"/><w:sz w:val=\"\(Int(normal.size * 2))\"/><w:szCs w:val=\"\(Int(normal.size * 2))\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"\(tw(normal.spaceAfter))\" w:line=\"\(Int(normal.lineMultiple * 240))\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
        for d in meta.styles where d.id != "endnote" && d.id != "endnotesHeading" {
            let id = Self.styleID(d.id)
            s += "<w:style w:type=\"paragraph\"\(d.id == "normal" ? " w:default=\"1\"" : "") w:styleId=\"\(id)\"><w:name w:val=\"\(xmlEscape(styleName(d)))\"/>"
            if d.id != "normal" { s += "<w:basedOn w:val=\"Normal\"/>" }
            if let n = meta.style(d.next) { s += "<w:next w:val=\"\(Self.styleID(n.id))\"/>" }
            s += "<w:qFormat/><w:pPr>\(pPr(d))</w:pPr><w:rPr>\(rPr(d))</w:rPr></w:style>"
        }
        s += "<w:style w:type=\"paragraph\" w:styleId=\"Header\"><w:name w:val=\"header\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:style>"
        s += "<w:style w:type=\"paragraph\" w:styleId=\"Footer\"><w:name w:val=\"footer\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:style>"
        s += "<w:style w:type=\"paragraph\" w:styleId=\"FootnoteText\"><w:name w:val=\"footnote text\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:sz w:val=\"18\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"paragraph\" w:styleId=\"EndnoteText\"><w:name w:val=\"endnote text\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:sz w:val=\"18\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"paragraph\" w:styleId=\"CommentText\"><w:name w:val=\"annotation text\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:sz w:val=\"20\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"character\" w:styleId=\"CommentReference\"><w:name w:val=\"annotation reference\"/><w:rPr><w:sz w:val=\"16\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"character\" w:styleId=\"FootnoteReference\"><w:name w:val=\"footnote reference\"/><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"character\" w:styleId=\"EndnoteReference\"><w:name w:val=\"endnote reference\"/><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0D4DCC\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
        return s + "</w:styles>"
    }

    // MARK: Sections, headers and footers

    private func settings(forTableAt loc: Int) -> LayoutSettings {
        if let b = sectionBreaks.first(where: { $0.loc >= loc }) { return meta.settings(for: b.id) }
        return meta.layout
    }

    private func headerFooterPart(_ hf: HeaderFooter, settings s: LayoutSettings, header: Bool) -> String {
        let width = s.effectiveSize.width - s.left - s.right
        func pieces(_ text: String) -> String {
            var out = "", rest = text[...]
            let run = { (t: String) in "<w:r><w:rPr><w:sz w:val=\"20\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(t))</w:t></w:r>" }
            while !rest.isEmpty {
                if let r = rest.range(of: "{pages}") ?? rest.range(of: "{page}") {
                    let before = String(rest[rest.startIndex..<r.lowerBound])
                    if !before.isEmpty { out += run(before) }
                    let instr = rest[r] == "{pages}" ? " NUMPAGES " : " PAGE "
                    // choose whichever token appears first
                    let first = [rest.range(of: "{pages}"), rest.range(of: "{page}")].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }!
                    let isPages = rest[first] == "{pages}"
                    _ = instr
                    out += "<w:fldSimple w:instr=\"\(isPages ? " NUMPAGES " : " PAGE ")\"><w:r><w:rPr><w:sz w:val=\"20\"/></w:rPr><w:t>1</w:t></w:r></w:fldSimple>"
                    if first.lowerBound != r.lowerBound { out = String(out.dropLast(0)) }
                    rest = rest[first.upperBound...]
                    continue
                }
                out += run(String(rest)); break
            }
            return out
        }
        let root = header ? "hdr" : "ftr"
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:\(root) \(Self.ns)><w:p><w:pPr><w:pStyle w:val=\"\(header ? "Header" : "Footer")\"/><w:tabs><w:tab w:val=\"center\" w:pos=\"\(tw(width / 2))\"/><w:tab w:val=\"right\" w:pos=\"\(tw(width))\"/></w:tabs></w:pPr>"
        xml += pieces(hf.left) + "<w:r><w:tab/></w:r>" + pieces(hf.center) + "<w:r><w:tab/></w:r>" + pieces(hf.right)
        return xml + "</w:p></w:\(root)>"
    }

    private func sectPrXML(_ s: LayoutSettings) -> String {
        var x = "<w:sectPr>"
        if !s.header.isEmpty {
            headerCount += 1
            let path = "word/header\(headerCount).xml"
            extraParts.append((path, "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml", headerFooterPart(s.header, settings: s, header: true)))
            x += "<w:headerReference w:type=\"default\" r:id=\"\(addRel(type: "header", target: "header\(headerCount).xml"))\"/>"
        }
        if !s.footer.isEmpty {
            footerCount += 1
            let path = "word/footer\(footerCount).xml"
            extraParts.append((path, "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml", headerFooterPart(s.footer, settings: s, header: false)))
            x += "<w:footerReference w:type=\"default\" r:id=\"\(addRel(type: "footer", target: "footer\(footerCount).xml"))\"/>"
        }
        let size = s.effectiveSize
        x += "<w:type w:val=\"nextPage\"/><w:pgSz w:w=\"\(tw(size.width))\" w:h=\"\(tw(size.height))\"\(s.landscape ? " w:orient=\"landscape\"" : "")/>"
        x += "<w:pgMar w:top=\"\(tw(s.top))\" w:right=\"\(tw(s.right))\" w:bottom=\"\(tw(s.bottom))\" w:left=\"\(tw(s.left))\" w:header=\"\(tw(s.headerDistance))\" w:footer=\"\(tw(s.footerDistance))\" w:gutter=\"0\"/>"
        x += "<w:cols w:num=\"\(max(1, s.columns))\" w:space=\"\(tw(s.columnSpacing))\"/></w:sectPr>"
        return x
    }

    // MARK: Body

    private func bodyXML() -> String {
        var pieces: [String] = []
        let ns = storage.string as NSString
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if storage.attribute(.wcEndnotes, at: pr.location, effectiveRange: nil) != nil { loc = NSMaxRange(pr); continue }
            if let ps = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle,
               !ps.textBlocks.isEmpty, let grid = TableGrid.find(in: storage, at: pr.location) {
                listState = nil
                closeCommentIn(&pieces)
                pieces.append(tableXML(grid, at: pr.location))
                loc = max(NSMaxRange(grid.range), loc + 1)
                continue
            }
            paragraphPieces(storage, pr, &pieces, allowSections: true)
            loc = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
        closeCommentIn(&pieces)
        if pieces.isEmpty { pieces.append("<w:p/>") }
        if pieces.last!.hasPrefix("<w:tbl>") { pieces.append("<w:p/>") }
        return pieces.joined()
    }

    /// Ends a comment range that is still open by appending its markers to the last paragraph.
    private func closeCommentIn(_ pieces: inout [String]) {
        guard let c = openComment, let n = commentIDs[c], var last = pieces.last, last.hasSuffix("</w:p>") else { openComment = nil; return }
        last.removeLast(6)
        last += "<w:commentRangeEnd w:id=\"\(n)\"/><w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:commentReference w:id=\"\(n)\"/></w:r></w:p>"
        pieces[pieces.count - 1] = last
        openComment = nil
    }

    private func attachSection(_ sect: String, to pieces: inout [String]) {
        guard var last = pieces.last, last.hasPrefix("<w:p>") else { pieces.append("<w:p><w:pPr>\(sect)</w:pPr></w:p>"); return }
        if let r = last.range(of: "</w:pPr>") {
            last.replaceSubrange(r, with: sect + "</w:pPr>")
        } else {
            last = "<w:p><w:pPr>\(sect)</w:pPr>" + last.dropFirst(5)
        }
        pieces[pieces.count - 1] = last
    }

    private func pPrXML(_ ps: NSParagraphStyle?, _ def: StyleDef, list: (numbered: Bool, numID: Int)?, rtl: Bool = false) -> String {
        var s = "<w:pStyle w:val=\"\(Self.styleID(def.id))\"/>"
        if let l = list { s += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(l.numID)\"/></w:numPr>" }
        if let ps, list == nil, !ps.tabStops.isEmpty {
            s += "<w:tabs>"
            for t in ps.tabStops {
                let kind = t.alignment == .right ? "right" : (t.alignment == .center ? "center" : "left")
                s += "<w:tab w:val=\"\(kind)\" w:pos=\"\(tw(t.location))\"/>"
            }
            s += "</w:tabs>"
        }
        if rtl { s += "<w:bidi/>" }
        guard let ps else { return s }
        let line = ps.lineHeightMultiple == 0 ? 1 : ps.lineHeightMultiple
        if abs(ps.paragraphSpacingBefore - def.spaceBefore) > 0.1 || abs(ps.paragraphSpacing - def.spaceAfter) > 0.1 || abs(line - def.lineMultiple) > 0.01 {
            s += "<w:spacing w:before=\"\(tw(ps.paragraphSpacingBefore))\" w:after=\"\(tw(ps.paragraphSpacing))\" w:line=\"\(Int(line * 240))\" w:lineRule=\"auto\"/>"
        }
        if list != nil {
            let marker = ps.tabStops.first?.location ?? (ps.headIndent - 18)
            s += "<w:ind w:left=\"\(tw(ps.headIndent))\" w:hanging=\"\(tw(max(0, ps.headIndent - marker)))\"/>"
        } else {
            let left = ps.headIndent, first = ps.firstLineHeadIndent - ps.headIndent, right = ps.tailIndent < 0 ? -ps.tailIndent : 0
            if abs(left - def.leftIndent) > 0.1 || abs(first - def.firstLine) > 0.1 || abs(right - def.rightIndent) > 0.1 {
                s += "<w:ind w:left=\"\(tw(left))\" w:right=\"\(tw(right))\""
                s += first < 0 ? " w:hanging=\"\(tw(-first))\"/>" : " w:firstLine=\"\(tw(first))\"/>"
            }
        }
        // natural = start edge; explicit left/right swap in right-to-left paragraphs (OOXML uses start/end there)
        let al: Int = { switch ps.alignment { case .right: return rtl ? 0 : 1; case .center: return 2; case .justified: return 3; case .left: return rtl ? 1 : 0; default: return 0 } }()
        let defAl = def.alignment == 4 ? 0 : def.alignment
        if al != defAl { s += "<w:jc w:val=\"\(["left", "right", "center", "both"][al])\"/>" }
        return s
    }

    private func rPrXML(_ a: [NSAttributedString.Key: Any], _ def: StyleDef, rtl: Bool = false) -> String {
        var s = ""
        let isLink = a[.link] != nil
        if isLink { s += "<w:rStyle w:val=\"Hyperlink\"/>" }
        let font = a[.font] as? NSFont
        if let f = font {
            let fam = f.familyName ?? f.fontName
            if fam != def.family { s += "<w:rFonts w:ascii=\"\(xmlEscape(fam))\" w:hAnsi=\"\(xmlEscape(fam))\" w:cs=\"\(xmlEscape(fam))\"/>" }
            let t = NSFontManager.shared.traits(of: f)
            let b = t.contains(.boldFontMask), i = t.contains(.italicFontMask)
            if b != def.bold { s += b ? "<w:b/><w:bCs/>" : "<w:b w:val=\"0\"/><w:bCs w:val=\"0\"/>" }
            if i != def.italic { s += i ? "<w:i/><w:iCs/>" : "<w:i w:val=\"0\"/><w:iCs w:val=\"0\"/>" }
        }
        if ((a[.strikethroughStyle] as? Int) ?? 0) != 0 { s += "<w:strike/>" }
        if !isLink, let c = a[.foregroundColor] as? NSColor, hex(c) != hex(def.nsColor) { s += "<w:color w:val=\"\(hex(c))\"/>" }
        if let f = font, abs(f.pointSize - def.size) > 0.01 {
            s += "<w:sz w:val=\"\(Int((f.pointSize * 2).rounded()))\"/><w:szCs w:val=\"\(Int((f.pointSize * 2).rounded()))\"/>"
        }
        let u = ((a[.underlineStyle] as? Int) ?? 0) != 0
        if !isLink && u != def.underline { s += u ? "<w:u w:val=\"single\"/>" : "<w:u w:val=\"none\"/>" }
        if let bg = a[.backgroundColor] as? NSColor { s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex(bg))\"/>" }
        let sup = (a[.superscript] as? Int) ?? 0
        if sup > 0 { s += "<w:vertAlign w:val=\"superscript\"/>" } else if sup < 0 { s += "<w:vertAlign w:val=\"subscript\"/>" }
        if rtl { s += "<w:rtl/>" }
        return s.isEmpty ? "" : "<w:rPr>\(s)</w:rPr>"
    }

    private func textRuns(_ text: String, rPr: String, deleted: Bool = false) -> String {
        var out = "", buf = ""
        let tag = deleted ? "w:delText" : "w:t"
        func flush() { if !buf.isEmpty { out += "<w:r>\(rPr)<\(tag) xml:space=\"preserve\">\(xmlEscape(buf))</\(tag)></w:r>"; buf = "" } }
        for ch in text {
            switch ch {
            case "\t": flush(); out += "<w:r>\(rPr)<w:tab/></w:r>"
            case "\u{2028}": flush(); out += "<w:r>\(rPr)<w:br/></w:r>"
            case "\u{000C}": flush(); out += "<w:r>\(rPr)<w:br w:type=\"page\"/></w:r>"
            case "\u{200B}": continue
            default: buf.append(ch)
            }
        }
        flush()
        return out
    }

    private func paragraphPieces(_ attr: NSAttributedString, _ pr: NSRange, _ pieces: inout [String], allowSections: Bool = false) {
        let ns = attr.string as NSString
        guard attr.length > 0 else { pieces.append("<w:p/>"); return }
        let attrs0 = attr.attributes(at: min(pr.location, attr.length - 1), effectiveRange: nil)
        let def = meta.style((attrs0[.wcStyle] as? String) ?? "normal") ?? meta.style("normal") ?? StyleDef.make("normal", "Normal")
        let ps = attrs0[.paragraphStyle] as? NSParagraphStyle
        var content = pr
        if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }

        var list: (numbered: Bool, numID: Int)?
        if let l = ps?.textLists.first {
            let numbered = ["decimal", "alpha", "roman"].contains { l.markerFormat.rawValue.contains($0) }
            if let st = listState, st.numbered == numbered { list = st }
            else if numbered { numberedNums.append(nextNumID); list = (true, nextNumID); nextNumID += 1 }
            else { list = (false, 1) }
            listState = list
            if content.length > 0, ns.character(at: content.location) == 9 {      // drop the "\t•\t" marker text
                let para = ns.substring(with: content) as NSString
                let second = para.range(of: "\t", options: [], range: NSRange(location: 1, length: max(0, para.length - 1)))
                if second.location != NSNotFound { content.location += second.location + 1; content.length -= second.location + 1 }
            }
        } else { listState = nil }

        let dir = ps?.baseWritingDirection ?? .natural
        let rtl = dir == .rightToLeft || (dir == .natural && ns.substring(with: content).startsRightToLeft)
        let pPr = pPrXML(ps, def, list: list, rtl: rtl)
        var runs = "", linkURL: String?, linkRuns = ""
        var split = false
        func flushLink() {
            if let l = linkURL { runs += "<w:hyperlink r:id=\"\(linkRelID(l))\" w:history=\"1\">\(linkRuns)</w:hyperlink>"; linkURL = nil; linkRuns = "" }
        }
        func add(_ x: String, link l: String? = nil) {
            if l != linkURL { flushLink(); linkURL = l }
            if linkURL != nil { linkRuns += x } else { runs += x }
        }
        func commentID(_ id: String) -> Int {
            if let n = commentIDs[id] { return n }
            commentIDs[id] = commentOrder.count
            commentOrder.append(id)
            return commentIDs[id]!
        }
        func endComment(link l: String?) {
            guard let c = openComment else { return }
            let n = commentID(c)
            add("<w:commentRangeEnd w:id=\"\(n)\"/><w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:commentReference w:id=\"\(n)\"/></w:r>", link: l)
            openComment = nil
        }
        func wrapRevision(_ x: String, _ a: [NSAttributedString.Key: Any]) -> String {
            guard let rev = RevisionInfo.decode(a[.wcRevision]), !x.isEmpty else { return x }
            revID += 1
            let tag = rev.kind == .insert ? "w:ins" : "w:del"
            return "<\(tag) w:id=\"\(revID)\" w:author=\"\(xmlEscape(rev.author))\" w:date=\"\(isoFormatter.string(from: rev.date))\">\(x)</\(tag)>"
        }
        func closeParagraph(sect: String?) {
            if let ob = openBookmark, let n = bookmarkIDs[ob] { add("<w:bookmarkEnd w:id=\"\(n)\"/>", link: linkURL); openBookmark = nil }
            flushLink()
            if let sect, runs.isEmpty { attachSection(sect, to: &pieces) }
            else { pieces.append("<w:p><w:pPr>\(pPr)\(sect ?? "")</w:pPr>\(runs)</w:p>") }
            runs = ""
        }

        if content.length > 0 {
            attr.enumerateAttributes(in: content, options: []) { a, r, _ in
                let text = ns.substring(with: r)
                if allowSections {
                    let bk = a[.wcBookmark] as? String
                    if bk != openBookmark {
                        if let ob = openBookmark, let n = bookmarkIDs[ob] { add("<w:bookmarkEnd w:id=\"\(n)\"/>", link: linkURL) }
                        openBookmark = nil
                        if let bk, !emittedBookmarks.contains(bk) {
                            emittedBookmarks.insert(bk)
                            let n = bookmarkIDs.count + 1
                            bookmarkIDs[bk] = n
                            add("<w:bookmarkStart w:id=\"\(n)\" w:name=\"\(xmlEscape(bk))\"/>", link: linkURL)
                            openBookmark = bk
                        }
                    }
                    let cid = a[.wcComment] as? String
                    if cid != openComment {
                        endComment(link: linkURL)
                        if let cid, meta.comments[cid] != nil {
                            openComment = cid
                            add("<w:commentRangeStart w:id=\"\(commentID(cid))\"/>", link: linkURL)
                        }
                    }
                }
                if a[.wcSection] != nil {
                    // section breaks only exist at body level; inside cells and text boxes they are dropped
                    if allowSections, let id = a[.wcSection] as? String {
                        closeParagraph(sect: sectPrXML(meta.settings(for: id)))
                        split = true
                    }
                } else if let id = a[.wcObject] as? String {
                    if let o = meta.objects[id] { add(objectRun(o)) }
                } else if a[.wcFootnote] != nil || a[.wcEndnote] != nil {
                    let isFoot = a[.wcFootnote] != nil
                    let nid = (a[.wcFootnote] ?? a[.wcEndnote]) as? String ?? ""
                    let note = meta.notes[nid] ?? ""
                    for _ in text {
                        if isFoot { footnotes.append((footnotes.count + 1, note)) } else { endnotes.append((endnotes.count + 1, note)) }
                        let id = isFoot ? footnotes.count : endnotes.count
                        add("<w:r><w:rPr><w:rStyle w:val=\"\(isFoot ? "FootnoteReference" : "EndnoteReference")\"/></w:rPr><w:\(isFoot ? "footnoteReference" : "endnoteReference") w:id=\"\(id)\"/></w:r>")
                    }
                } else if let p = EquationProps.decode(a[.wcEquation]) {
                    flushLink()
                    add(OMML.xml(fromSource: p.source))
                } else if let p = ImageProps.decode(a[.wcImage]) {
                    add(wrapRevision(inlineImage(p), a), link: nil)
                } else {
                    var link: String?
                    if let l = a[.link] { link = (l as? URL)?.absoluteString ?? (l as? String) }
                    let isDel = RevisionInfo.decode(a[.wcRevision])?.kind == .delete
                    let rPr = rPrXML(a, def, rtl: rtl)
                    var x: String
                    if let label = a[.wcCaption] as? String, text.hasPrefix(label + " ") {
                        let num = String(text.dropFirst(label.count + 1))
                        x = wrapRevision(textRuns(label + " ", rPr: rPr), a)
                            + "<w:fldSimple w:instr=\"\(xmlEscape(" SEQ \(label) \\* ARABIC "))\">\(wrapRevision(textRuns(num, rPr: rPr), a))</w:fldSimple>"
                    } else {
                        x = wrapRevision(textRuns(text, rPr: rPr, deleted: isDel), a)
                    }
                    if let xr = XrefProps.decode(a[.wcXref]) {
                        x = "<w:fldSimple w:instr=\"\(xmlEscape(" \(xr.what == "page" ? "PAGEREF" : "REF") \(xr.name) \\h "))\">\(x)</w:fldSimple>"
                    } else if let m = a[.wcMerge] as? String {
                        x = "<w:fldSimple w:instr=\"\(xmlEscape(" MERGEFIELD \(m) "))\">\(x)</w:fldSimple>"
                    } else if let c = a[.wcCite] as? String {
                        let tag = c.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? c
                        x = "<w:fldSimple w:instr=\"\(xmlEscape(" CITATION \(tag) \\l 1033 "))\">\(x)</w:fldSimple>"
                    }
                    if let cp = ControlProps.decode(a[.wcControl]) { x = sdtXML(cp, current: text, content: x) }
                    if let ix = a[.wcIndex] as? String {
                        let entry = ix.replacingOccurrences(of: "|", with: ":")
                        let hid = "<w:rPr><w:vanish/></w:rPr>"
                        x += "<w:r>\(hid)<w:fldChar w:fldCharType=\"begin\"/></w:r><w:r>\(hid)<w:instrText xml:space=\"preserve\"> XE \"\(xmlEscape(entry))\" </w:instrText></w:r><w:r>\(hid)<w:fldChar w:fldCharType=\"end\"/></w:r>"
                    }
                    add(x, link: link)
                }
            }
        }
        if split && runs.isEmpty && linkRuns.isEmpty { return }
        closeParagraph(sect: nil)
    }

    // MARK: Content controls

    private func sdtXML(_ p: ControlProps, current: String, content: String) -> String {
        var pr = "<w:alias w:val=\"\(xmlEscape(p.title))\"/><w:tag w:val=\"\(xmlEscape(p.id))\"/>"
        if current == p.placeholder && p.kind != "checkbox" { pr += "<w:showingPlcHdr/>" }
        switch p.kind {
        case "dropdown":
            pr += "<w:dropDownList>" + p.options.map { "<w:listItem w:displayText=\"\(xmlEscape($0))\" w:value=\"\(xmlEscape($0))\"/>" }.joined() + "</w:dropDownList>"
        case "date":
            pr += "<w:date><w:dateFormat w:val=\"MMM d, yyyy\"/><w:lid w:val=\"en-US\"/><w:storeMappedDataAs w:val=\"dateTime\"/><w:calendar w:val=\"gregorian\"/></w:date>"
        case "checkbox":
            pr += "<w14:checkbox><w14:checked w14:val=\"\(current == "☒" ? 1 : 0)\"/><w14:checkedState w14:val=\"2612\" w14:font=\"MS Gothic\"/><w14:uncheckedState w14:val=\"2610\" w14:font=\"MS Gothic\"/></w14:checkbox>"
        default: pr += "<w:text/>"
        }
        return "<w:sdt><w:sdtPr>\(pr)</w:sdtPr><w:sdtContent>\(content)</w:sdtContent></w:sdt>"
    }

    // MARK: Tables

    private func tableXML(_ g: TableGrid, at loc: Int) -> String {
        let s = settings(forTableAt: loc)
        let total = tw(s.effectiveSize.width - s.left - s.right)
        let pct = g.colPercents
        let colTw = pct.map { Int(CGFloat(total) * $0 / 100) }
        var x = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableNormal\"/><w:tblW w:w=\"\(total)\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"80\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
        for w in colTw { x += "<w:gridCol w:w=\"\(w)\"/>" }
        x += "</w:tblGrid>"
        func border(_ name: String, _ w: CGFloat, _ c: NSColor) -> String {
            w <= 0 ? "<w:\(name) w:val=\"nil\"/>" : "<w:\(name) w:val=\"single\" w:sz=\"\(max(2, Int(w * 8)))\" w:space=\"0\" w:color=\"\(hex(c))\"/>"
        }
        for r in 0..<g.rows {
            x += "<w:tr>"
            var c = 0
            while c < g.cols {
                guard let i = g.cell(covering: r, c) else {
                    x += "<w:tc><w:tcPr><w:tcW w:w=\"\(colTw[c])\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"; c += 1; continue
                }
                let cell = g.cells[i]
                guard cell.col == c else { c += 1; continue }
                let width = (c..<min(g.cols, c + cell.colSpan)).reduce(0) { $0 + colTw[$1] }
                var pr = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                if cell.colSpan > 1 { pr += "<w:gridSpan w:val=\"\(cell.colSpan)\"/>" }
                if cell.rowSpan > 1 { pr += cell.row == r ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }
                pr += "<w:tcBorders>" + border("top", cell.borders[1], cell.borderColor) + border("left", cell.borders[0], cell.borderColor)
                    + border("bottom", cell.borders[3], cell.borderColor) + border("right", cell.borders[2], cell.borderColor) + "</w:tcBorders>"
                if let sh = cell.shading { pr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex(sh))\"/>" }
                var paras: [String] = []
                if cell.row == r {
                    let ns = cell.content.string as NSString
                    var loc = 0
                    while loc < ns.length {
                        let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                        paragraphPieces(cell.content, p, &paras)
                        loc = NSMaxRange(p)
                        if p.length == 0 { break }
                    }
                }
                listState = nil
                x += "<w:tc><w:tcPr>\(pr)</w:tcPr>\(paras.isEmpty ? "<w:p/>" : paras.joined())</w:tc>"
                c += cell.colSpan
            }
            x += "</w:tr>"
        }
        return x + "</w:tbl>"
    }

    // MARK: Drawings

    private func nextDocPr(alt: String = "") -> String { drawingID += 1; return "<wp:docPr id=\"\(drawingID)\" name=\"Object \(drawingID)\"\(alt.isEmpty ? "" : " descr=\"\(xmlEscape(alt))\"")/>" }

    private func picXML(asset: String, w: CGFloat, h: CGFloat, crop: [CGFloat]) -> String? {
        guard let rid = imageRelID(asset) else { return nil }
        let src = crop.contains { $0 > 0 }
            ? "<a:srcRect l=\"\(Int(crop[0] * 100000))\" t=\"\(Int(crop[1] * 100000))\" r=\"\(Int(crop[2] * 100000))\" b=\"\(Int(crop[3] * 100000))\"/>" : ""
        return "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(drawingID)\" name=\"Picture \(drawingID)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rid)\"/>\(src)<a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(emu(w))\" cy=\"\(emu(h))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>"
    }

    private func inlineImage(_ p: ImageProps) -> String {
        let pr = nextDocPr(alt: p.alt)
        guard let pic = picXML(asset: p.asset, w: p.width, h: p.height, crop: p.crop) else { return "" }
        return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(emu(p.width))\" cy=\"\(emu(p.height))\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>\(pr)<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>\(pic)</wp:inline></w:drawing></w:r>"
    }

    private func color(_ c: [CGFloat]?) -> String? {
        guard let c = FloatingObject.color(c) else { return nil }
        return hex(c)
    }

    private func shapeXML(_ o: FloatingObject) -> String {
        let preset: String = {
            if o.kind == .textbox { return o.shape == .rounded ? "roundRect" : "rect" }
            switch o.shape {
            case .rect: return "rect"
            case .rounded: return "roundRect"
            case .ellipse: return "ellipse"
            case .triangle: return "triangle"
            case .diamond: return "diamond"
            case .line, .arrow: return "line"
            case .star: return "star5"
            }
        }()
        var fill = "<a:noFill/>"
        if let f = color(o.fill) {
            let alpha = (o.fill?[3] ?? 1) < 1 ? "<a:alpha val=\"\(Int((o.fill?[3] ?? 1) * 100000))\"/>" : ""
            fill = "<a:solidFill><a:srgbClr val=\"\(f)\">\(alpha)</a:srgbClr></a:solidFill>"
        }
        var line = "<a:ln><a:noFill/></a:ln>"
        if let st = color(o.stroke), o.strokeWidth > 0 {
            line = "<a:ln w=\"\(emu(o.strokeWidth))\"><a:solidFill><a:srgbClr val=\"\(st)\"/></a:solidFill>" + (o.shape == .arrow ? "<a:tailEnd type=\"triangle\"/>" : "") + "</a:ln>"
        }
        var tx = ""
        if o.kind == .textbox {
            var paras: [String] = []
            if let d = o.rtf, let a = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), a.length > 0 {
                let ns = a.string as NSString
                var loc = 0
                while loc < ns.length {
                    let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                    paragraphPieces(a, p, &paras)
                    loc = NSMaxRange(p)
                    if p.length == 0 { break }
                }
            }
            tx = "<wps:txbx><w:txbxContent>\(paras.isEmpty ? "<w:p/>" : paras.joined())</w:txbxContent></wps:txbx>"
        }
        return "<a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\"><wps:wsp><wps:cNvSpPr\(o.kind == .textbox ? " txBox=\"1\"" : "")/><wps:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(emu(o.w))\" cy=\"\(emu(o.h))\"/></a:xfrm><a:prstGeom prst=\"\(preset)\"><a:avLst/></a:prstGeom>\(fill)\(line)</wps:spPr>\(tx)<wps:bodyPr rot=\"0\" vert=\"horz\" wrap=\"square\" lIns=\"45720\" tIns=\"45720\" rIns=\"45720\" bIns=\"45720\" anchor=\"t\" anchorCtr=\"0\"><a:noAutofit/></wps:bodyPr></wps:wsp></a:graphicData></a:graphic>"
    }

    private func objectRun(_ o: FloatingObject) -> String {
        let pr = nextDocPr(alt: o.image?.alt ?? o.alt)
        let graphic: String
        if o.kind == .image, let p = o.image, let g = picXML(asset: p.asset, w: o.w, h: o.h, crop: p.crop) { graphic = g }
        else if o.kind != .image { graphic = shapeXML(o) }
        else { return "" }
        let wrap: String = {
            switch o.wrap {
            case .square: return "<wp:wrapSquare wrapText=\"bothSides\"/>"
            case .topBottom: return "<wp:wrapTopAndBottom/>"
            default: return "<wp:wrapNone/>"
            }
        }()
        return "<w:r><w:drawing><wp:anchor distT=\"0\" distB=\"0\" distL=\"114300\" distR=\"114300\" simplePos=\"0\" relativeHeight=\"\(max(1, o.z + 1) * 1024)\" behindDoc=\"\(o.wrap == .behind ? 1 : 0)\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"1\"><wp:simplePos x=\"0\" y=\"0\"/><wp:positionH relativeFrom=\"page\"><wp:posOffset>\(emu(o.x))</wp:posOffset></wp:positionH><wp:positionV relativeFrom=\"page\"><wp:posOffset>\(emu(o.y))</wp:posOffset></wp:positionV><wp:extent cx=\"\(emu(o.w))\" cy=\"\(emu(o.h))\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>\(wrap)\(pr)<wp:cNvGraphicFramePr/>\(graphic)</wp:anchor></w:drawing></w:r>"
    }
}

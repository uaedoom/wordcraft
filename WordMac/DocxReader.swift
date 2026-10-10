import AppKit

/// Reads an Office Open XML (.docx / .dotx) package into the document model.
final class DocxReader {
    struct Result {
        var attributed: NSAttributedString
        var meta: DocMeta
        var assets: [String: Data]
    }

    // MARK: Property bags

    struct RP {
        var family: String?, size: CGFloat?
        var bold: Bool?, italic: Bool?, underline: Bool?, strike: Bool?
        var color: NSColor?, shade: NSColor?, highlight: NSColor?
        var vert: Int?, caps: Bool?, hidden: Bool?
        mutating func merge(_ o: RP) {
            if let v = o.family { family = v }; if let v = o.size { size = v }
            if let v = o.bold { bold = v }; if let v = o.italic { italic = v }
            if let v = o.underline { underline = v }; if let v = o.strike { strike = v }
            if let v = o.color { color = v }; if let v = o.shade { shade = v }; if let v = o.highlight { highlight = v }
            if let v = o.vert { vert = v }; if let v = o.caps { caps = v }; if let v = o.hidden { hidden = v }
        }
    }

    struct PP {
        var align: Int?
        var left: CGFloat?, right: CGFloat?, firstLine: CGFloat?
        var before: CGFloat?, after: CGFloat?, line: CGFloat?
        var outline: Int?
        var numID: Int?, ilvl: Int?
        var pageBreakBefore: Bool?
        var bidi: Bool?
        var tabs: [NSTextTab]?
        mutating func merge(_ o: PP) {
            if let v = o.align { align = v }; if let v = o.left { left = v }; if let v = o.right { right = v }
            if let v = o.firstLine { firstLine = v }; if let v = o.before { before = v }; if let v = o.after { after = v }
            if let v = o.line { line = v }; if let v = o.outline { outline = v }
            if let v = o.numID { numID = v }; if let v = o.ilvl { ilvl = v }
            if let v = o.pageBreakBefore { pageBreakBefore = v }; if let v = o.tabs { tabs = v }; if let v = o.bidi { bidi = v }
        }
    }

    struct RawStyle {
        var id: String, name: String, type: String
        var basedOn: String?, next: String?
        var pPr: XNode?, rPr: XNode?, tblPr: XNode?, tcPr: XNode?
        var isDefault = false, qFormat = false
        var cond: [String: XNode] = [:]
    }

    struct NumLevel { var fmt: String; var text: String; var left: CGFloat; var hanging: CGFloat }

    // MARK: State

    private let parts: [String: Data]
    private var docDir = "word/"
    private var docRels: [String: (type: String, target: String, external: Bool)] = [:]
    private var theme: (major: String, minor: String) = ("Helvetica Neue", "Helvetica Neue")
    private var styles: [String: RawStyle] = [:]
    private var defaultParaStyle = "Normal"
    private var docRP = RP()
    private var docPP = PP()
    private var styleMap: [String: String] = [:]
    private var rpCache: [String: RP] = [:], ppCache: [String: PP] = [:]
    private var abstractNums: [Int: [Int: NumLevel]] = [:]
    private var nums: [Int: Int] = [:]
    private var counters: [String: Int] = [:]
    private var fontCache: [String: NSFont] = [:]
    private var footnoteText: [Int: String] = [:], endnoteText: [Int: String] = [:]
    private var meta = DocMeta()
    private let assets = AssetStore()
    private let out = NSMutableAttributedString()
    private var sink: NSMutableAttributedString!
    private var fields: [(instr: String, inResult: Bool, start: Int)] = []
    private var openBookmarks: [(id: Int, name: String)] = []
    private var tablePP: PP?
    private var footnoteCounter = 0
    private var comments: [Int: CommentRec] = [:]
    private var openComments: [Int] = []
    private let isoFormatter = ISO8601DateFormatter()
    private var pendingBorders: [Int: [String: (width: CGFloat, color: NSColor)]] = [:]
    private var sectionList: [LayoutSettings] = []
    private var sectionIndex = 0
    private var pendingSection: String?
    private var endnoteOrder: [String] = []

    private init(parts: [String: Data]) { self.parts = parts }

    // MARK: Entry point

    static func read(_ data: Data) -> Result? {
        guard let parts = Zip.read(data) else { return nil }
        let r = DocxReader(parts: parts)
        return r.run()
    }

    private func xml(_ path: String) -> XNode? { parts[path].flatMap { XNode.parse($0) } }

    private func resolve(_ target: String) -> String {
        var t = target
        if t.hasPrefix("/") { return String(t.dropFirst()) }
        var comps = docDir.split(separator: "/").map(String.init)
        for c in t.split(separator: "/") {
            if c == ".." { _ = comps.popLast() } else if c != "." { comps.append(String(c)) }
        }
        t = comps.joined(separator: "/")
        return t
    }

    private func run() -> Result? {
        guard let rootRels = xml("_rels/.rels") else { return nil }
        var mainPath = "word/document.xml"
        for r in rootRels.kids("Relationship") where (r.attr("Type") ?? "").hasSuffix("/officeDocument") {
            mainPath = (r.attr("Target") ?? mainPath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        docDir = (mainPath as NSString).deletingLastPathComponent + "/"
        guard let doc = xml(mainPath), let body = doc.child("w:body") else { return nil }
        let relsPath = docDir + "_rels/" + (mainPath as NSString).lastPathComponent + ".rels"
        if let r = xml(relsPath) {
            for rel in r.kids("Relationship") {
                guard let id = rel.attr("Id"), let t = rel.attr("Target") else { continue }
                docRels[id] = ((rel.attr("Type") ?? "").components(separatedBy: "/").last ?? "", t, rel.attr("TargetMode") == "External")
            }
        }
        loadTheme()
        loadStyles()
        loadNumbering()
        loadNotes()
        loadComments()
        loadSettings()
        prescanSections(body)
        let startSection = sectionList.first ?? LayoutSettings()
        _ = startSection

        sink = out
        processBlocks(body.children, inCell: false)
        buildEndnotesBlock()
        if out.length == 0 { out.append(NSAttributedString(string: "\n")) }

        meta.layout = sectionList.last ?? LayoutSettings()
        let full = NSRange(location: 0, length: out.length)
        _ = full
        return Result(attributed: out, meta: meta, assets: assets.data)
    }

    // MARK: Theme, styles, numbering

    private func loadTheme() {
        guard let target = docRels.values.first(where: { $0.type == "theme" })?.target, let t = xml(resolve(target)) else { return }
        func face(_ n: String) -> String? { t.descendants(n).first?.child("a:latin")?.attr("typeface") }
        if let m = face("a:majorFont") { theme.major = m }
        if let m = face("a:minorFont") { theme.minor = m }
    }

    private func pt(_ s: String?) -> CGFloat? { s.flatMap { Double($0) }.map { CGFloat($0) / 20 } }

    private func parseColor(_ s: String?) -> NSColor? {
        guard let s, s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    private func on(_ n: XNode?) -> Bool? {
        guard let n else { return nil }
        let v = (n.val ?? "true").lowercased()
        return !(v == "0" || v == "false" || v == "off" || v == "none")
    }

    private static let highlights: [String: NSColor] = [
        "yellow": .yellow, "green": .green, "cyan": .cyan, "magenta": .magenta, "blue": .blue, "red": .red,
        "darkBlue": NSColor(calibratedRed: 0, green: 0, blue: 0.55, alpha: 1), "darkCyan": NSColor(calibratedRed: 0, green: 0.55, blue: 0.55, alpha: 1),
        "darkGreen": NSColor(calibratedRed: 0, green: 0.4, blue: 0, alpha: 1), "darkMagenta": NSColor(calibratedRed: 0.55, green: 0, blue: 0.55, alpha: 1),
        "darkRed": NSColor(calibratedRed: 0.55, green: 0, blue: 0, alpha: 1), "darkYellow": NSColor(calibratedRed: 0.55, green: 0.55, blue: 0, alpha: 1),
        "darkGray": .darkGray, "lightGray": .lightGray, "black": .black, "white": .white]

    private func parseRP(_ rPr: XNode?) -> RP {
        var p = RP()
        guard let rPr else { return p }
        if let f = rPr.child("w:rFonts") {
            if let t = f.attr("w:asciiTheme") ?? f.attr("w:hAnsiTheme") {
                p.family = t.hasPrefix("major") ? theme.major : theme.minor
            } else if let a = f.attr("w:ascii") ?? f.attr("w:hAnsi") { p.family = a }
        }
        if let s = rPr.child("w:sz")?.val, let v = Double(s) { p.size = CGFloat(v) / 2 }
        p.bold = on(rPr.child("w:b")); p.italic = on(rPr.child("w:i"))
        if let u = rPr.child("w:u") { p.underline = (u.val ?? "single") != "none" }
        p.strike = on(rPr.child("w:strike")) ?? on(rPr.child("w:dstrike"))
        if let c = rPr.child("w:color") { p.color = parseColor(c.val) ?? (c.val == "auto" ? .black : nil) }
        if let h = rPr.child("w:highlight")?.val, h != "none" { p.highlight = Self.highlights[h] }
        if let sh = rPr.child("w:shd"), let f = sh.attr("w:fill"), f != "auto" { p.shade = parseColor(f) }
        if let v = rPr.child("w:vertAlign")?.val { p.vert = v == "superscript" ? 1 : (v == "subscript" ? -1 : 0) }
        p.caps = on(rPr.child("w:caps")); p.hidden = on(rPr.child("w:vanish"))
        return p
    }

    private func parsePP(_ pPr: XNode?) -> PP {
        var p = PP()
        guard let pPr else { return p }
        if let j = pPr.child("w:jc")?.val { p.align = ["left": 0, "start": 0, "right": 1, "end": 1, "center": 2, "both": 3, "distribute": 3][j] }
        if let i = pPr.child("w:ind") {
            p.left = pt(i.attr("w:left") ?? i.attr("w:start")); p.right = pt(i.attr("w:right") ?? i.attr("w:end"))
            if let h = pt(i.attr("w:hanging")) { p.firstLine = -h } else if let f = pt(i.attr("w:firstLine")) { p.firstLine = f }
        }
        if let s = pPr.child("w:spacing") {
            p.before = pt(s.attr("w:before")); p.after = pt(s.attr("w:after"))
            if let l = s.attr("w:line"), let v = Double(l) {
                let rule = s.attr("w:lineRule") ?? "auto"
                p.line = rule == "auto" ? CGFloat(v) / 240 : CGFloat(v) / 20 / 14      // exact/atLeast: approximate as a multiple
            }
        }
        if let o = pPr.child("w:outlineLvl")?.val, let v = Int(o), v < 9 { p.outline = v + 1 }
        if let n = pPr.child("w:numPr") {
            p.numID = n.child("w:numId")?.val.flatMap { Int($0) }
            p.ilvl = n.child("w:ilvl")?.val.flatMap { Int($0) } ?? 0
        }
        p.pageBreakBefore = on(pPr.child("w:pageBreakBefore"))
        p.bidi = on(pPr.child("w:bidi"))
        if let t = pPr.child("w:tabs") {
            var stops: [NSTextTab] = []
            for tab in t.kids("w:tab") {
                guard let pos = pt(tab.attr("w:pos")), let v = tab.val, v != "clear" else { continue }
                stops.append(NSTextTab(textAlignment: v == "right" || v == "end" ? .right : (v == "center" ? .center : .left), location: pos))
            }
            p.tabs = stops
        }
        return p
    }

    private func loadStyles() {
        guard let target = docRels.values.first(where: { $0.type == "styles" })?.target, let root = xml(resolve(target)) else { return }
        if let d = root.child("w:docDefaults") {
            docRP = parseRP(d.child("w:rPrDefault")?.child("w:rPr"))
            docPP = parsePP(d.child("w:pPrDefault")?.child("w:pPr"))
        }
        for s in root.kids("w:style") {
            guard let id = s.attr("w:styleId") else { continue }
            var r = RawStyle(id: id, name: s.child("w:name")?.val ?? id, type: s.attr("w:type") ?? "paragraph")
            r.basedOn = s.child("w:basedOn")?.val; r.next = s.child("w:next")?.val
            r.pPr = s.child("w:pPr"); r.rPr = s.child("w:rPr"); r.tblPr = s.child("w:tblPr"); r.tcPr = s.child("w:tcPr")
            r.isDefault = s.attr("w:default") == "1" || s.attr("w:default") == "true"
            r.qFormat = s.child("w:qFormat") != nil
            for sp in s.kids("w:tblStylePr") { if let t = sp.attr("w:type") { r.cond[t] = sp } }
            styles[id] = r
            if r.type == "paragraph" && r.isDefault { defaultParaStyle = id }
        }
        // map to our built-in ids
        let builtins: [String: String] = ["normal": "normal", "title": "title", "subtitle": "subtitle", "quote": "quote",
                                          "toc heading": "tocHeading", "caption": "caption", "toc 1": "toc1", "toc 2": "toc2", "toc 3": "toc3"]
        for (id, s) in styles where s.type == "paragraph" {
            let n = s.name.lowercased()
            if let b = builtins[n] { styleMap[id] = b }
            else if n.hasPrefix("heading "), let lvl = Int(n.dropFirst(8)), (1...6).contains(lvl) { styleMap[id] = "h\(lvl)" }
            else { styleMap[id] = "docx-" + id }
        }
        // build StyleDefs
        var defs: [StyleDef] = StyleDef.defaults
        for (id, s) in styles where s.type == "paragraph" {
            guard let ours = styleMap[id] else { continue }
            let rp = effectiveRP(id), pp = effectivePP(id)
            var d = defs.first { $0.id == ours } ?? StyleDef(id: ours, name: s.name)
            d.name = defs.contains(where: { $0.id == ours }) ? d.name : s.name
            d.family = rp.family ?? theme.minor
            d.size = rp.size ?? 10
            d.bold = rp.bold ?? false; d.italic = rp.italic ?? false; d.underline = rp.underline ?? false
            d.nsColor = rp.color ?? .black
            d.alignment = pp.align ?? 0
            d.spaceBefore = pp.before ?? 0; d.spaceAfter = pp.after ?? 0
            d.lineMultiple = pp.line ?? 1
            d.leftIndent = pp.left ?? 0; d.rightIndent = pp.right ?? 0; d.firstLine = pp.firstLine ?? 0
            d.outline = ours.hasPrefix("h") && ours.count == 2 ? Int(ours.dropFirst()) ?? 0 : (pp.outline ?? 0)
            d.next = s.next.flatMap { styleMap[$0] } ?? ours
            d.builtin = !ours.hasPrefix("docx-")
            d.gallery = s.qFormat && !["toc1", "toc2", "toc3", "tocHeading"].contains(ours)
            if let i = defs.firstIndex(where: { $0.id == ours }) { defs[i] = d } else { defs.append(d) }
        }
        meta.styles = defs
    }

    private func chain(_ id: String) -> [RawStyle] {
        var out: [RawStyle] = [], cur: String? = id, seen = Set<String>()
        while let c = cur, let s = styles[c], seen.insert(c).inserted { out.insert(s, at: 0); cur = s.basedOn }
        return out
    }

    private func effectiveRP(_ id: String) -> RP {
        if let c = rpCache[id] { return c }
        var p = docRP
        for s in chain(id) { p.merge(parseRP(s.rPr)) }
        rpCache[id] = p
        return p
    }

    private func effectivePP(_ id: String) -> PP {
        if let c = ppCache[id] { return c }
        var p = docPP
        for s in chain(id) { p.merge(parsePP(s.pPr)) }
        ppCache[id] = p
        return p
    }

    private func loadNumbering() {
        guard let target = docRels.values.first(where: { $0.type == "numbering" })?.target, let root = xml(resolve(target)) else { return }
        for a in root.kids("w:abstractNum") {
            guard let id = a.attr("w:abstractNumId").flatMap({ Int($0) }) else { continue }
            var levels: [Int: NumLevel] = [:]
            for l in a.kids("w:lvl") {
                guard let il = l.attr("w:ilvl").flatMap({ Int($0) }) else { continue }
                let ind = l.child("w:pPr")?.child("w:ind")
                levels[il] = NumLevel(fmt: l.child("w:numFmt")?.val ?? "decimal", text: l.child("w:lvlText")?.val ?? "%1.",
                                      left: pt(ind?.attr("w:left") ?? ind?.attr("w:start")) ?? CGFloat(36 * (il + 1)),
                                      hanging: pt(ind?.attr("w:hanging")) ?? 18)
            }
            abstractNums[id] = levels
        }
        for n in root.kids("w:num") {
            if let id = n.attr("w:numId").flatMap({ Int($0) }), let a = n.child("w:abstractNumId")?.val.flatMap({ Int($0) }) { nums[id] = a }
        }
    }

    private func loadNotes() {
        for (type, store) in [("footnotes", 0), ("endnotes", 1)] {
            guard let target = docRels.values.first(where: { $0.type == type })?.target, let root = xml(resolve(target)) else { continue }
            for n in root.kids(store == 0 ? "w:footnote" : "w:endnote") {
                guard let id = n.attr("w:id").flatMap({ Int($0) }), id > 0, n.attr("w:type") == nil else { continue }
                var text = ""
                for p in n.descendants("w:p") {
                    let t = p.descendants("w:t").map { $0.text }.joined()
                    if !t.isEmpty { text += (text.isEmpty ? "" : " ") + t.trimmingCharacters(in: .whitespaces) }
                }
                if store == 0 { footnoteText[id] = text } else { endnoteText[id] = text }
            }
        }
    }

    private func date(_ s: String?) -> Double {
        guard let s, let d = isoFormatter.date(from: s) else { return Date().timeIntervalSince1970 }
        return d.timeIntervalSince1970
    }

    private func loadComments() {
        guard let target = docRels.values.first(where: { $0.type == "comments" })?.target, let root = xml(resolve(target)) else { return }
        for c in root.kids("w:comment") {
            guard let id = c.attr("w:id").flatMap({ Int($0) }) else { continue }
            let paras = c.kids("w:p").map { p in p.descendants("w:t").map { $0.text }.joined() }
            let author = c.attr("w:author") ?? "Author"
            comments[id] = CommentRec(author: author, initials: c.attr("w:initials") ?? String(author.prefix(1)),
                                      date: date(c.attr("w:date")), text: paras.joined(separator: "\n"))
        }
    }

    private func loadSettings() {
        guard let target = docRels.values.first(where: { $0.type == "settings" })?.target, let root = xml(resolve(target)) else { return }
        meta.trackChanges = root.child("w:trackRevisions") != nil
        if let p = root.child("w:documentProtection"), ["1", "true"].contains(p.attr("w:enforcement") ?? "0") {
            var prot = Protection()
            switch p.attr("w:edit") {
            case "readOnly": prot.mode = .readOnly
            case "comments": prot.mode = .comments
            case "trackedChanges": prot.mode = .trackedChanges
            case "forms": prot.mode = .forms
            default: break
            }
            // only Word's SHA-512 scheme can be checked here; other schemes import without a password
            if let h = p.attr("w:hash") ?? p.attr("w:hashValue"), let salt = p.attr("w:salt") ?? p.attr("w:saltValue"),
               (p.attr("w:cryptAlgorithmSid") == "14" || p.attr("w:algorithmName") == "SHA-512") {
                prot.hash = h; prot.salt = salt
                prot.spin = p.attr("w:cryptSpinCount").flatMap { Int($0) } ?? p.attr("w:spinCount").flatMap { Int($0) } ?? 100000
            }
            meta.protection = prot
            if prot.mode == .trackedChanges { meta.trackChanges = true }
        }
    }

    // MARK: Sections

    private func sectionSettings(_ s: XNode) -> LayoutSettings {
        var l = LayoutSettings()
        if let sz = s.child("w:pgSz"), let w = pt(sz.attr("w:w")), let h = pt(sz.attr("w:h")) {
            l.pageWidth = min(w, h); l.pageHeight = max(w, h)
            l.landscape = sz.attr("w:orient") == "landscape" || w > h
        }
        if let m = s.child("w:pgMar") {
            l.top = max(0, pt(m.attr("w:top")) ?? 72); l.bottom = max(0, pt(m.attr("w:bottom")) ?? 72)
            l.left = pt(m.attr("w:left")) ?? 72; l.right = pt(m.attr("w:right")) ?? 72
            l.headerDistance = pt(m.attr("w:header")) ?? 36; l.footerDistance = pt(m.attr("w:footer")) ?? 36
        }
        if let c = s.child("w:cols") {
            l.columns = max(1, min(4, c.attr("w:num").flatMap { Int($0) } ?? 1))
            l.columnSpacing = pt(c.attr("w:space")) ?? 36
        }
        for ref in s.kids("w:headerReference") + s.kids("w:footerReference") where (ref.attr("w:type") ?? "default") == "default" {
            guard let rid = ref.attr("r:id"), let t = docRels[rid]?.target, let part = xml(resolve(t)) else { continue }
            let hf = headerFooter(part)
            if ref.name == "w:headerReference" { l.header = hf } else { l.footer = hf }
        }
        return l
    }

    private func headerFooter(_ root: XNode) -> HeaderFooter {
        var segments: [String] = [""]
        var align = 0
        var seenFirst = false
        for p in root.kids("w:p") {
            var segs: [String] = [""]
            var instrStack: [String] = []
            var inInstr = false
            func walk(_ n: XNode) {
                for c in n.children {
                    switch c.name {
                    case "w:r":
                        for e in c.children {
                            switch e.name {
                            case "w:t": if !inInstr { segs[segs.count - 1] += e.text }
                            case "w:tab", "w:ptab": segs.append("")
                            case "w:fldChar":
                                let t = e.attr("w:fldCharType")
                                if t == "begin" { instrStack.append(""); inInstr = true }
                                else if t == "separate" { inInstr = false; segs[segs.count - 1] += token(instrStack.last ?? "") }
                                else if t == "end" { _ = instrStack.popLast(); inInstr = false }
                            case "w:instrText": if inInstr, !instrStack.isEmpty { instrStack[instrStack.count - 1] += e.text }
                            default: break
                            }
                        }
                    case "w:fldSimple":
                        let t = token(c.attr("w:instr") ?? "")
                        if t.isEmpty { walk(c) } else { segs[segs.count - 1] += t }
                    case "w:hyperlink", "w:ins", "w:smartTag", "w:sdt", "w:sdtContent": walk(c)
                    default: break
                    }
                }
            }
            walk(p)
            if segs.joined().trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !seenFirst {
                segments = segs.map { $0.trimmingCharacters(in: .whitespaces) }
                align = parsePP(p.child("w:pPr")).align ?? 0
                seenFirst = true
            }
        }
        var hf = HeaderFooter()
        switch segments.count {
        case 1:
            if align == 2 { hf.center = segments[0] } else if align == 1 { hf.right = segments[0] } else { hf.left = segments[0] }
        case 2: hf.left = segments[0]; hf.right = segments[1]
        default: hf.left = segments[0]; hf.center = segments[1]; hf.right = segments[2...].joined(separator: " ")
        }
        return hf
    }

    private func token(_ instr: String) -> String {
        let t = instr.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("NUMPAGES") { return "{pages}" }
        if t.hasPrefix("PAGE") && !t.hasPrefix("PAGEREF") { return "{page}" }
        return ""
    }

    /// Finds every section's page setup up front so drawings can be placed relative to the right page.
    private func prescanSections(_ body: XNode) {
        func visit(_ nodes: [XNode]) {
            for n in nodes {
                switch n.name {
                case "w:p": if let s = n.child("w:pPr")?.child("w:sectPr") { sectionList.append(sectionSettings(s)) }
                case "w:sdt": visit(n.child("w:sdtContent")?.children ?? [])
                case "w:sectPr": sectionList.append(sectionSettings(n))
                default: break
                }
            }
        }
        visit(body.children)
        if sectionList.isEmpty { sectionList = [LayoutSettings()] }
    }

    private var currentSection: LayoutSettings { sectionList[min(sectionIndex, sectionList.count - 1)] }
}

// MARK: - Body

private struct RunCtx {
    var rp: DocxReader.RP
    var link: URL?
    var pAttrs: [NSAttributedString.Key: Any]
    var rev: String?
    var control: String?
}

extension DocxReader {
    func processBlocks(_ nodes: [XNode], inCell: Bool) {
        for n in nodes {
            switch n.name {
            case "w:p": appendParagraph(n, inCell: inCell)
            case "w:tbl": if inCell { flattenTable(n) } else { appendTable(n) }
            case "w:sdt": processBlocks(n.child("w:sdtContent")?.children ?? [], inCell: inCell)
            case "w:customXml", "w:ins": processBlocks(n.children, inCell: inCell)
            case "w:commentRangeStart": if let id = n.attr("w:id").flatMap({ Int($0) }) { openComments.append(id) }
            case "w:commentRangeEnd": if let id = n.attr("w:id").flatMap({ Int($0) }) { openComments.removeAll { $0 == id } }
            case "mc:AlternateContent": processBlocks(n.child("mc:Choice")?.children ?? [], inCell: inCell)
            default: break
            }
        }
    }

    private func flattenTable(_ t: XNode) {
        for tr in t.kids("w:tr") { for tc in tr.kids("w:tc") { processBlocks(tc.children, inCell: true) } }
    }

    // MARK: Fonts and run attributes

    private func font(_ rp: RP) -> NSFont {
        let fam = rp.family ?? theme.minor
        let size = rp.size ?? 10
        let key = "\(fam)|\(size)|\(rp.bold ?? false)|\(rp.italic ?? false)"
        if let f = fontCache[key] { return f }
        var traits: NSFontTraitMask = []
        if rp.bold == true { traits.insert(.boldFontMask) }
        if rp.italic == true { traits.insert(.italicFontMask) }
        let f = NSFontManager.shared.font(withFamily: fam, traits: traits, weight: 5, size: size)
            ?? NSFontManager.shared.font(withFamily: "Helvetica Neue", traits: traits, weight: 5, size: size)
            ?? .systemFont(ofSize: size)
        fontCache[key] = f
        return f
    }

    private var inTOCField: Bool {
        fields.contains { $0.inResult && $0.instr.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("TOC") }
    }

    private var fieldLink: URL? {
        for f in fields where f.inResult {
            let t = f.instr.trimmingCharacters(in: .whitespaces)
            guard t.uppercased().hasPrefix("HYPERLINK"), !t.contains("\\l") else { continue }
            let parts = t.components(separatedBy: "\"")
            if parts.count >= 2, let u = URL(string: parts[1]), u.scheme != nil { return u }
        }
        return nil
    }

    private func attrs(_ rp: RP, _ ctx: RunCtx) -> [NSAttributedString.Key: Any] {
        var a = ctx.pAttrs
        let link = ctx.link ?? fieldLink
        a[.font] = font(rp)
        a[.foregroundColor] = link != nil ? EditorController.linkColor : (rp.color ?? NSColor.black)
        if rp.underline == true || link != nil { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if rp.strike == true { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let h = rp.highlight ?? rp.shade { a[.backgroundColor] = h }
        if let v = rp.vert, v != 0 { a[.superscript] = v }
        if let l = link { a[.link] = l }
        if inTOCField { a[.wcTOC] = 1 }
        if let r = ctx.rev { a[.wcRevision] = r }
        if let c = ctx.control { a[.wcControl] = c }
        if let b = openBookmarks.last, b.name != "_GoBack" { a[.wcBookmark] = b.name }
        if let c = openComments.last, comments[c] != nil { a[.wcComment] = "c\(c)"; meta.comments["c\(c)"] = comments[c] }
        return a
    }

    private func charStyleRP(_ id: String) -> RP {
        var p = RP()
        for s in chain(id) { p.merge(parseRP(s.rPr)) }
        return p
    }

    // MARK: Paragraphs

    func appendParagraph(_ p: XNode, inCell: Bool) {
        let pPr = p.child("w:pPr")
        let sid = pPr?.child("w:pStyle")?.val ?? defaultParaStyle
        let ours = styleMap[sid] ?? "normal"
        var pp = effectivePP(sid)
        if inCell, let t = tablePP, sid == defaultParaStyle { pp.merge(t) }
        let direct = parsePP(pPr)
        pp.merge(direct)
        let rpBase = { () -> RP in var r = effectiveRP(sid); r.merge(parseRP(pPr?.child("w:rPr"))); return r }()

        // paragraph style
        let ps = NSMutableParagraphStyle()
        let rtlPara = pp.bidi == true
        switch pp.align {
        case nil: ps.alignment = .natural
        case 0?: ps.alignment = rtlPara ? .natural : .left          // "left" means start in bidi paragraphs
        case 1?: ps.alignment = rtlPara ? .left : .right
        case 2?: ps.alignment = .center
        default: ps.alignment = .justified
        }
        if rtlPara { ps.baseWritingDirection = .rightToLeft }
        ps.paragraphSpacingBefore = pp.before ?? 0
        ps.paragraphSpacing = pp.after ?? 0
        ps.lineHeightMultiple = pp.line ?? 1
        let left = pp.left ?? 0
        ps.headIndent = left
        ps.firstLineHeadIndent = max(0, left + (pp.firstLine ?? 0))
        ps.tailIndent = -(pp.right ?? 0)
        if let t = pp.tabs, !t.isEmpty { ps.tabStops = t }

        var prefix = ""
        if let nid = pp.numID, nid != 0, let abs = nums[nid], let lvl = abstractNums[abs]?[pp.ilvl ?? 0], lvl.fmt != "none" {
            let il = pp.ilvl ?? 0
            let fmts = ["decimal": "{decimal}.", "lowerLetter": "{lower-alpha}.", "upperLetter": "{upper-alpha}.", "lowerRoman": "{lower-roman}.", "upperRoman": "{upper-roman}."]
            let format: NSTextList.MarkerFormat = lvl.fmt == "bullet" ? .disc : NSTextList.MarkerFormat(fmts[lvl.fmt] ?? "{decimal}.")
            let list = NSTextList(markerFormat: format, options: 0)
            let key = "\(nid):\(il)"
            counters[key, default: 0] += 1
            for k in counters.keys where k.hasPrefix("\(nid):") && (Int(k.split(separator: ":")[1]) ?? 0) > il { counters[k] = 0 }
            let indentLeft = direct.left ?? lvl.left
            ps.textLists = [list]
            ps.headIndent = indentLeft
            ps.firstLineHeadIndent = 0
            ps.tabStops = [NSTextTab(textAlignment: .left, location: max(4, indentLeft - lvl.hanging)), NSTextTab(textAlignment: .left, location: indentLeft)]
            prefix = "\t" + list.marker(forItemNumber: counters[key] ?? 1) + "\t"
        }

        var pAttrs: [NSAttributedString.Key: Any] = [.wcStyle: ours, .paragraphStyle: ps]
        if ours.hasPrefix("toc") { pAttrs[.wcTOC] = 1 }
        let ctx = RunCtx(rp: rpBase, link: nil, pAttrs: pAttrs, rev: nil, control: nil)
        let body = NSMutableAttributedString()
        walkInline(p.children, ctx, body)

        let markAttrs = attrs(rpBase, ctx)
        var endAttrs = markAttrs
        endAttrs.removeValue(forKey: .link)
        body.append(NSAttributedString(string: "\n", attributes: endAttrs))
        if !prefix.isEmpty { body.insert(NSAttributedString(string: prefix, attributes: endAttrs), at: 0) }
        if pp.pageBreakBefore == true { body.insert(NSAttributedString(string: "\u{000C}", attributes: endAttrs), at: 0) }
        if !inCell, let id = pendingSection {
            var a = endAttrs
            a[.wcSection] = id
            body.insert(NSAttributedString(string: "\u{000C}", attributes: a), at: 0)
            pendingSection = nil
        }
        sink.append(body)

        if !inCell, pPr?.child("w:sectPr") != nil {
            let id = String(UUID().uuidString.prefix(8))
            meta.sectionLayouts[id] = currentSection
            sectionIndex += 1
            pendingSection = id
        }
    }

    private func walkInline(_ nodes: [XNode], _ ctx: RunCtx, _ para: NSMutableAttributedString) {
        for n in nodes {
            switch n.name {
            case "w:r": appendRun(n, ctx, para)
            case "w:hyperlink":
                var c = ctx
                if let rid = n.attr("r:id"), let rel = docRels[rid], rel.external { c.link = URL(string: rel.target) }
                walkInline(n.children, c, para)
            case "w:fldSimple":
                let f = (n.attr("w:instr") ?? "", true, para.length)
                fields.append(f)
                walkInline(n.children, ctx, para)
                _ = fields.popLast()
                completeField(f, para)
            case "w:bookmarkStart":
                if let id = n.attr("w:id").flatMap({ Int($0) }), let name = n.attr("w:name") { openBookmarks.append((id, name)) }
            case "w:bookmarkEnd":
                if let id = n.attr("w:id").flatMap({ Int($0) }) { openBookmarks.removeAll { $0.id == id } }
            case "w:sdt":
                var c = ctx
                if let pr = n.child("w:sdtPr"), let cp = controlProps(pr, content: n.child("w:sdtContent")) { c.control = cp.json }
                walkInline(n.child("w:sdtContent")?.children ?? [], c, para)
            case "w:ins", "w:moveTo":
                var c = ctx
                c.rev = RevisionInfo(kind: .insert, author: n.attr("w:author") ?? "Author", date: Date(timeIntervalSince1970: date(n.attr("w:date")))).encoded
                walkInline(n.children, c, para)
            case "w:del", "w:moveFrom":
                var c = ctx
                c.rev = RevisionInfo(kind: .delete, author: n.attr("w:author") ?? "Author", date: Date(timeIntervalSince1970: date(n.attr("w:date")))).encoded
                walkInline(n.children, c, para)
            case "w:commentRangeStart": if let id = n.attr("w:id").flatMap({ Int($0) }) { openComments.append(id) }
            case "w:commentRangeEnd": if let id = n.attr("w:id").flatMap({ Int($0) }) { openComments.removeAll { $0 == id } }
            case "w:smartTag", "w:sdtContent", "w:customXml", "w:dir", "w:bdo":
                walkInline(n.children, ctx, para)
            case "m:oMath": appendEquation(n, ctx, para)
            case "m:oMathPara": for m in n.kids("m:oMath") { appendEquation(m, ctx, para) }
            case "mc:AlternateContent": walkInline(n.child("mc:Choice")?.children ?? n.child("mc:Fallback")?.children ?? [], ctx, para)
            default: break
            }
        }
    }

    private func appendRun(_ r: XNode, _ ctx: RunCtx, _ para: NSMutableAttributedString) {
        var rp = ctx.rp
        let rPr = r.child("w:rPr")
        if let rs = rPr?.child("w:rStyle")?.val { rp.merge(charStyleRP(rs)) }
        rp.merge(parseRP(rPr))
        for e in r.children { runChild(e, rp, ctx, para) }
    }

    private func runChild(_ e: XNode, _ rp: RP, _ ctx: RunCtx, _ para: NSMutableAttributedString) {
        func emit(_ text: String) {
            if fields.contains(where: { !$0.inResult }) || rp.hidden == true || text.isEmpty { return }
            para.append(NSAttributedString(string: rp.caps == true ? text.uppercased() : text, attributes: attrs(rp, ctx)))
        }
        switch e.name {
        case "w:t", "w:delText": emit(e.text)
        case "w:tab", "w:ptab": emit("\t")
        case "w:br":
            let t = e.attr("w:type") ?? "textWrapping"
            emit(t == "page" || t == "column" ? "\u{000C}" : "\u{2028}")
        case "w:cr": emit("\u{2028}")
        case "w:noBreakHyphen": emit("-")
        case "w:fldChar":
            switch e.attr("w:fldCharType") {
            case "begin": fields.append(("", false, para.length))
            case "separate": if !fields.isEmpty { fields[fields.count - 1].inResult = true; fields[fields.count - 1].start = para.length }
            case "end": if let f = fields.popLast() { completeField(f, para) }
            default: break
            }
        case "w:instrText":
            if !fields.isEmpty, !fields[fields.count - 1].inResult { fields[fields.count - 1].instr += e.text }
        case "w:drawing": appendDrawing(e, rp, ctx, para)
        case "w:footnoteReference", "w:endnoteReference":
            guard !fields.contains(where: { !$0.inResult }), let id = e.attr("w:id").flatMap({ Int($0) }) else { return }
            footnoteCounter += 1
            let nid = (e.name == "w:footnoteReference" ? "fn" : "en") + "\(footnoteCounter)"
            var a = attrs(rp, ctx)
            if e.name == "w:footnoteReference" { meta.notes[nid] = footnoteText[id] ?? ""; a[.wcFootnote] = nid }
            else { meta.notes[nid] = endnoteText[id] ?? ""; a[.wcEndnote] = nid; endnoteOrder.append(nid) }
            para.append(NSAttributedString(string: "\u{2003}", attributes: a))
        case "mc:AlternateContent":
            for c in e.child("mc:Choice")?.children ?? [] { runChild(c, rp, ctx, para) }
        default: break
        }
    }

    private func appendEquation(_ m: XNode, _ ctx: RunCtx, _ para: NSMutableAttributedString) {
        let src = m.children.map(OMML.latex).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return }
        var a = attrs(ctx.rp, ctx)
        a[.wcEquation] = EquationProps(source: src, size: ctx.rp.size ?? 11).json
        para.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
    }

    // MARK: Fields and content controls

    /// Turns finished Word fields into live WordCraft fields (merge fields, cross-references, caption numbers).
    private func completeField(_ f: (instr: String, inResult: Bool, start: Int), _ para: NSMutableAttributedString) {
        let tokens = f.instr.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let head = tokens.first?.uppercased(), tokens.count >= 2, f.start <= para.length else { return }
        let range = NSRange(location: f.start, length: para.length - f.start)
        let name = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch head {
        case "MERGEFIELD":
            guard range.length > 0 else { return }
            para.addAttributes([.wcMerge: name, .backgroundColor: NSColor(calibratedWhite: 0.86, alpha: 1)], range: range)
        case "REF", "PAGEREF":
            guard range.length > 0, !name.hasPrefix("\\") else { return }
            para.addAttribute(.wcXref, value: XrefProps(name: name, what: head == "PAGEREF" ? "page" : "text").json, range: range)
        case "SEQ":
            let prefix = name + " "
            let before = (para.string as NSString).substring(to: f.start)
            guard range.length > 0, before.hasSuffix(prefix) else { return }
            let start = f.start - (prefix as NSString).length
            para.addAttribute(.wcCaption, value: name, range: NSRange(location: start, length: para.length - start))
        default: break
        }
    }

    private func controlProps(_ pr: XNode, content: XNode?) -> ControlProps? {
        var p = ControlProps(id: pr.child("w:tag")?.val ?? String(UUID().uuidString.prefix(8)), kind: "text")
        p.title = pr.child("w:alias")?.val ?? ""
        let shown = content?.descendants("w:t").map { $0.text }.joined() ?? ""
        if let dd = pr.child("w:dropDownList") ?? pr.child("w:comboBox") {
            p.kind = "dropdown"
            p.options = dd.kids("w:listItem").compactMap { $0.attr("w:displayText") ?? $0.attr("w:value") }.filter { !$0.isEmpty }
            p.placeholder = "Choose an item"
        } else if pr.child("w:date") != nil {
            p.kind = "date"; p.placeholder = "Click to enter a date"
        } else if pr.child("w14:checkbox") != nil {
            p.kind = "checkbox"; p.placeholder = "☐"
        } else if pr.child("w:text") != nil || pr.child("w:richText") != nil {
            p.kind = "text"
        } else { return nil }
        if pr.child("w:showingPlcHdr") != nil, !shown.isEmpty { p.placeholder = shown }
        return p
    }

    // MARK: Drawings

    private func emuPt(_ s: String?) -> CGFloat { CGFloat(Double(s ?? "") ?? 0) / 12700 }

    private func appendDrawing(_ d: XNode, _ rp: RP, _ ctx: RunCtx, _ para: NSMutableAttributedString) {
        guard let holder = d.child("wp:inline") ?? d.child("wp:anchor"),
              let gd = holder.descendants("a:graphicData").first else { return }
        let isAnchor = holder.name == "wp:anchor"
        var w = emuPt(holder.child("wp:extent")?.attr("cx")), h = emuPt(holder.child("wp:extent")?.attr("cy"))
        var a = attrs(rp, ctx)

        if let pic = gd.child("pic:pic") ?? gd.descendants("pic:pic").first {
            guard let blip = pic.descendants("a:blip").first, let rid = blip.attr("r:embed"), let rel = docRels[rid],
                  let data = parts[resolve(rel.target)], NSImage(data: data) != nil else { return }
            if w <= 0 || h <= 0 { let n = NSImage(data: data)!.size; w = n.width; h = n.height }
            var crop: [CGFloat] = [0, 0, 0, 0]
            if let sr = pic.descendants("a:srcRect").first {
                crop = ["l", "t", "r", "b"].map { CGFloat(Double(sr.attr($0) ?? "0") ?? 0) / 100000 }
                if crop[0] + crop[2] > 0.9 || crop[1] + crop[3] > 0.9 { crop = [0, 0, 0, 0] }
            }
            var props = ImageProps(asset: assets.add(data), width: w, height: h, crop: crop)
            props.alt = holder.child("wp:docPr")?.attr("descr") ?? ""
            if !isAnchor {
                a[.wcImage] = props.json
                para.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
            } else {
                var o = FloatingObject(id: String(UUID().uuidString.prefix(8)), kind: .image, x: 0, y: 0, w: w, h: h)
                o.image = props; o.stroke = nil; o.strokeWidth = 0
                finishAnchor(&o, holder, a, para)
            }
        } else if let wsp = gd.descendants("wps:wsp").first, isAnchor {
            var o = FloatingObject(id: String(UUID().uuidString.prefix(8)), kind: .shape, x: 0, y: 0, w: w, h: h)
            let spPr = wsp.child("wps:spPr")
            if (w <= 0 || h <= 0), let ext = spPr?.descendants("a:ext").first { o.w = emuPt(ext.attr("cx")); o.h = emuPt(ext.attr("cy")) }
            let prst = spPr?.child("a:prstGeom")?.attr("prst") ?? "rect"
            switch prst {
            case "roundRect": o.shape = .rounded
            case "ellipse": o.shape = .ellipse
            case "triangle", "rtTriangle": o.shape = .triangle
            case "diamond": o.shape = .diamond
            case "line", "straightConnector1": o.shape = spPr?.descendants("a:tailEnd").first != nil || spPr?.descendants("a:headEnd").first != nil ? .arrow : .line
            case "star5", "star4", "star6", "star8": o.shape = .star
            default: o.shape = .rect
            }
            o.fill = nil
            if let f = spPr?.child("a:solidFill") { o.fill = FloatingObject.components(drawingColor(f)) }
            o.stroke = nil; o.strokeWidth = 0
            if let ln = spPr?.child("a:ln"), ln.child("a:noFill") == nil {
                o.strokeWidth = max(0.5, emuPt(ln.attr("w")))
                o.stroke = FloatingObject.components(ln.child("a:solidFill").flatMap(drawingColor) ?? .black)
            }
            if let tx = wsp.child("wps:txbx")?.child("w:txbxContent") {
                o.kind = .textbox
                if o.shape != .rounded { o.shape = .rect }
                let buf = NSMutableAttributedString()
                let saved = sink, savedSection = pendingSection
                sink = buf; pendingSection = nil
                processBlocks(tx.children, inCell: true)
                sink = saved; pendingSection = savedSection
                if buf.length > 1 { buf.deleteCharacters(in: NSRange(location: buf.length - 1, length: 1)) }
                o.rtf = try? buf.data(from: NSRange(location: 0, length: buf.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            }
            finishAnchor(&o, holder, a, para)
        }
    }

    private func drawingColor(_ fill: XNode) -> NSColor? {
        if let c = fill.child("a:srgbClr") { return parseColor(c.attr("val")) }
        if let s = fill.child("a:schemeClr")?.attr("val") {
            switch s {
            case "bg1", "lt1": return .white
            case "tx1", "dk1": return .black
            case "bg2", "lt2": return NSColor(white: 0.9, alpha: 1)
            case "tx2", "dk2": return NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.4, alpha: 1)
            case "accent2": return NSColor(calibratedRed: 0.93, green: 0.49, blue: 0.19, alpha: 1)
            case "accent3": return NSColor(calibratedWhite: 0.65, alpha: 1)
            case "accent4": return NSColor(calibratedRed: 1, green: 0.75, blue: 0, alpha: 1)
            case "accent5": return NSColor(calibratedRed: 0.36, green: 0.6, blue: 0.82, alpha: 1)
            case "accent6": return NSColor(calibratedRed: 0.44, green: 0.68, blue: 0.28, alpha: 1)
            default: return NSColor(calibratedRed: 0.27, green: 0.45, blue: 0.77, alpha: 1)
            }
        }
        return nil
    }

    private func finishAnchor(_ o: inout FloatingObject, _ holder: XNode, _ a: [NSAttributedString.Key: Any], _ para: NSMutableAttributedString) {
        let s = currentSection
        let size = s.effectiveSize
        func place(_ pos: XNode?, vertical: Bool) -> CGFloat {
            let rel = pos?.attr("relativeFrom") ?? "margin"
            let total = vertical ? size.height : size.width
            let marginStart = vertical ? s.top : s.left
            let marginLen = vertical ? size.height - s.top - s.bottom : size.width - s.left - s.right
            let (start, len): (CGFloat, CGFloat) = rel == "page" ? (0, total) : (marginStart, marginLen)
            let length = vertical ? o.h : o.w
            if let al = pos?.child("wp:align")?.text.trimmingCharacters(in: .whitespaces) {
                switch al {
                case "center": return start + (len - length) / 2
                case "right", "bottom", "outside": return start + len - length
                default: return start
                }
            }
            return start + emuPt(pos?.child("wp:posOffset")?.text.trimmingCharacters(in: .whitespaces))
        }
        o.x = min(max(0, place(holder.child("wp:positionH"), vertical: false)), max(0, size.width - o.w))
        o.y = min(max(0, place(holder.child("wp:positionV"), vertical: true)), max(0, size.height - o.h))
        let behind = holder.attr("behindDoc") == "1" || holder.attr("behindDoc") == "true"
        if holder.child("wp:wrapSquare") != nil || holder.child("wp:wrapTight") != nil || holder.child("wp:wrapThrough") != nil { o.wrap = .square }
        else if holder.child("wp:wrapTopAndBottom") != nil { o.wrap = .topBottom }
        else { o.wrap = behind ? .behind : .front }
        o.z = (holder.attr("relativeHeight").flatMap { Int($0) } ?? 0) / 1024
        meta.objects[o.id] = o
        var anchorAttrs = a
        anchorAttrs[.wcObject] = o.id
        para.append(NSAttributedString(string: "\u{200B}", attributes: anchorAttrs))
    }

    // MARK: Tables

    private func borderSpec(_ n: XNode?) -> (width: CGFloat, color: NSColor)? {
        guard let n else { return nil }
        let v = n.val ?? "single"
        if v == "nil" || v == "none" { return (0, .black) }
        let w = CGFloat(Double(n.attr("w:sz") ?? "4") ?? 4) / 8
        return (max(0.25, w), parseColor(n.attr("w:color")) ?? .black)
    }

    func appendTable(_ tbl: XNode) {
        let tblPr = tbl.child("w:tblPr")
        let styleID = tblPr?.child("w:tblStyle")?.val
        // borders: style chain first, then direct
        var edge: [String: (width: CGFloat, color: NSColor)] = [:]
        var stylePP = PP()
        var hasStylePP = false
        for st in styleID.map({ chain($0) }) ?? [] {
            if let b = st.tblPr?.child("w:tblBorders") {
                for k in ["top", "left", "bottom", "right", "insideH", "insideV"] { if let sp = borderSpec(b.child("w:" + k) ?? (k == "left" ? b.child("w:start") : (k == "right" ? b.child("w:end") : nil))) { edge[k] = sp } }
            }
            if let pPr = st.pPr { stylePP.merge(parsePP(pPr)); hasStylePP = true }
        }
        if let b = tblPr?.child("w:tblBorders") {
            for k in ["top", "left", "bottom", "right", "insideH", "insideV"] { if let sp = borderSpec(b.child("w:" + k) ?? (k == "left" ? b.child("w:start") : (k == "right" ? b.child("w:end") : nil))) { edge[k] = sp } }
        }
        let savedPP = tablePP
        tablePP = hasStylePP ? stylePP : nil
        defer { tablePP = savedPP }

        let gridCols = (tbl.child("w:tblGrid")?.kids("w:gridCol") ?? []).compactMap { $0.attr("w:w").flatMap { Double($0) } }
        var cells: [TableCell] = []
        var open: [Int: Int] = [:]
        var maxCol = gridCols.count
        let rows = tbl.kids("w:tr")
        var colFill: [Int] = []
        for (r, tr) in rows.enumerated() {
            var c = tr.child("w:trPr")?.child("w:gridBefore")?.val.flatMap { Int($0) } ?? 0
            for tc in tr.kids("w:tc") {
                let tcPr = tc.child("w:tcPr")
                let span = max(1, tcPr?.child("w:gridSpan")?.val.flatMap { Int($0) } ?? 1)
                if let vm = tcPr?.child("w:vMerge"), (vm.val ?? "continue") != "restart", let idx = open[c] {
                    cells[idx].rowSpan += 1
                    c += span
                    continue
                }
                for k in c..<(c + span) { open[k] = nil }
                let content = cellContent(tc)
                var cell = TableCell(row: r, col: c, content: content)
                cell.colSpan = span
                if let f = tcPr?.child("w:shd")?.attr("w:fill"), f != "auto" { cell.shading = parseColor(f) }
                // direct cell borders override the table's
                var tcb: [String: (width: CGFloat, color: NSColor)] = [:]
                if let b = tcPr?.child("w:tcBorders") {
                    for (k, names) in [("top", ["w:top"]), ("left", ["w:left", "w:start"]), ("bottom", ["w:bottom"]), ("right", ["w:right", "w:end"])] {
                        for nm in names { if let sp = borderSpec(b.child(nm)) { tcb[k] = sp } }
                    }
                }
                cell.range = NSRange(location: 0, length: 0)
                cells.append(cell)
                open[c] = (tcPr?.child("w:vMerge")) != nil ? cells.count - 1 : nil
                pendingBorders[cells.count - 1] = tcb
                c += span
            }
            maxCol = max(maxCol, c)
            colFill.append(c)
        }
        let nCols = max(1, maxCol), nRows = rows.count
        // conditional table-style formatting (header row, banding, first/last column)
        var condByType: [String: XNode] = [:]
        for st in styleID.map({ chain($0) }) ?? [] { for (t, n) in st.cond { condByType[t] = n } }
        let look = tblPr?.child("w:tblLook")
        func lookFlag(_ name: String, _ mask: Int) -> Bool {
            if let v = look?.attr("w:" + name) { return v == "1" || v == "true" }
            if let hex = look?.attr("w:val"), let m = Int(hex, radix: 16) { return m & mask != 0 }
            return name == "firstRow" || name == "firstColumn"
        }
        let useFirstRow = lookFlag("firstRow", 0x20), useLastRow = lookFlag("lastRow", 0x40)
        let useFirstCol = lookFlag("firstColumn", 0x80), useLastCol = lookFlag("lastColumn", 0x100)
        let noHBand = lookFlag("noHBand", 0x200)
        if !condByType.isEmpty {
            for i in cells.indices {
                let c = cells[i]
                var types = ["wholeTable"]
                if !noHBand {
                    let idx = c.row - (useFirstRow ? 1 : 0)
                    if idx >= 0 { types.append(idx % 2 == 0 ? "band1Horz" : "band2Horz") }
                }
                if useLastCol && c.col + c.colSpan >= nCols { types.append("lastCol") }
                if useFirstCol && c.col == 0 { types.append("firstCol") }
                if useLastRow && c.row + c.rowSpan >= nRows { types.append("lastRow") }
                if useFirstRow && c.row == 0 { types.append("firstRow") }
                var rp = RP()
                for t in types {
                    guard let n = condByType[t] else { continue }
                    rp.merge(parseRP(n.child("w:rPr")))
                    if let f = n.child("w:tcPr")?.child("w:shd")?.attr("w:fill") { cells[i].shading = f == "auto" ? nil : parseColor(f) }
                    if let b = n.child("w:tcPr")?.child("w:tcBorders") {
                        var d = pendingBorders[i] ?? [:]
                        for (k, names) in [("top", ["w:top"]), ("left", ["w:left", "w:start"]), ("bottom", ["w:bottom"]), ("right", ["w:right", "w:end"])] {
                            for nm in names { if let sp = borderSpec(b.child(nm)), d[k] == nil || t != "wholeTable" { d[k] = sp } }
                        }
                        pendingBorders[i] = d
                    }
                }
                if rp.bold != nil || rp.italic != nil || rp.color != nil {
                    let m = NSMutableAttributedString(attributedString: cells[i].content)
                    m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { v, r, _ in
                        guard var f = v as? NSFont else { return }
                        if let b = rp.bold { f = b ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : NSFontManager.shared.convert(f, toNotHaveTrait: .boldFontMask) }
                        if let it = rp.italic { f = it ? NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) : NSFontManager.shared.convert(f, toNotHaveTrait: .italicFontMask) }
                        m.addAttribute(.font, value: f, range: r)
                    }
                    if let col = rp.color { m.addAttribute(.foregroundColor, value: col, range: NSRange(location: 0, length: m.length)) }
                    cells[i].content = m
                }
            }
        }
        pendingBorders = pendingBorders.filter { $0.key < cells.count }
        for i in cells.indices {
            let c = cells[i]
            func pick(_ k: String, _ fallback: String?) -> (width: CGFloat, color: NSColor)? {
                pendingBorders[i]?[k] ?? edge[k] ?? fallback.flatMap { edge[$0] }
            }
            let l = pick("left", c.col == 0 ? nil : "insideV") ?? (c.col == 0 ? nil : edge["insideV"])
            _ = l
            let left = pendingBorders[i]?["left"] ?? (c.col == 0 ? edge["left"] : edge["insideV"])
            let right = pendingBorders[i]?["right"] ?? (c.col + c.colSpan >= nCols ? edge["right"] : edge["insideV"])
            let top = pendingBorders[i]?["top"] ?? (c.row == 0 ? edge["top"] : edge["insideH"])
            let bottom = pendingBorders[i]?["bottom"] ?? (c.row + c.rowSpan >= nRows ? edge["bottom"] : edge["insideH"])
            cells[i].borders = [left?.width ?? 0, top?.width ?? 0, right?.width ?? 0, bottom?.width ?? 0]
            cells[i].borderColor = [left, top, right, bottom].compactMap { $0 }.first { $0.width > 0 }?.color ?? NSColor(white: 0.45, alpha: 1)
        }
        pendingBorders = [:]
        var grid = TableGrid()
        grid.rows = nRows; grid.cols = nCols; grid.cells = cells
        if gridCols.count == nCols, gridCols.reduce(0, +) > 0 {
            let total = gridCols.reduce(0, +)
            grid.columnWidths = gridCols.map { CGFloat($0 / total * 100) }
        }
        if grid.cells.isEmpty { return }
        if let id = pendingSection {              // a section break right before a table needs its own paragraph
            var a: [NSAttributedString.Key: Any] = [.wcStyle: "normal", .wcSection: id]
            a[.font] = EditorController.defaultFont
            sink.append(NSAttributedString(string: "\u{000C}\n", attributes: a))
            pendingSection = nil
        }
        sink.append(grid.render().text)
    }

    private func cellContent(_ tc: XNode) -> NSAttributedString {
        let saved = sink, savedSection = pendingSection
        let buf = NSMutableAttributedString()
        sink = buf; pendingSection = nil
        processBlocks(tc.children, inCell: true)
        sink = saved; pendingSection = savedSection
        if buf.length == 0 || !buf.string.hasSuffix("\n") { buf.append(NSAttributedString(string: "\n", attributes: [.font: EditorController.defaultFont])) }
        return buf
    }

    // MARK: Endnotes

    func buildEndnotesBlock() {
        guard !endnoteOrder.isEmpty else { return }
        func line(_ text: String, _ id: String) {
            guard let d = meta.style(id) else { return }
            var a = d.attributes(preserving: nil)
            a[.wcEndnotes] = 1
            sink.append(NSAttributedString(string: text + "\n", attributes: a))
        }
        if !sink.string.hasSuffix("\n") { sink.append(NSAttributedString(string: "\n")) }
        line("Endnotes", "endnotesHeading")
        for (i, nid) in endnoteOrder.enumerated() { line("\(romanNumeral(i + 1)). \(meta.notes[nid] ?? "")", "endnote") }
    }
}

import Foundation

/// Conversion between our math tree and Office Math (OMML).
enum OMML {
    // MARK: Export

    static func xml(fromSource source: String) -> String {
        var p = MathParser(source)
        return "<m:oMath>" + xml(p.parse()) + "</m:oMath>"
    }

    private static func run(_ t: String, italic: Bool) -> String {
        let text = t.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2005}\u{2009}"))
        guard !text.isEmpty else { return "" }
        return "<m:r>" + (italic ? "" : "<m:rPr><m:sty m:val=\"p\"/></m:rPr>")
            + "<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/></w:rPr>"
            + "<m:t xml:space=\"preserve\">\(xmlEscape(text))</m:t></m:r>"
    }

    static func xml(_ n: MathNode) -> String {
        switch n {
        case .row(let items): return items.map(xml).joined()
        case .text(let t, let italic): return run(t, italic: italic)
        case .frac(let a, let b): return "<m:f><m:num>\(xml(a))</m:num><m:den>\(xml(b))</m:den></m:f>"
        case .script(let base, let sub, let sup):
            switch (sub, sup) {
            case (let s?, let p?): return "<m:sSubSup><m:e>\(xml(base))</m:e><m:sub>\(xml(s))</m:sub><m:sup>\(xml(p))</m:sup></m:sSubSup>"
            case (let s?, nil): return "<m:sSub><m:e>\(xml(base))</m:e><m:sub>\(xml(s))</m:sub></m:sSub>"
            case (nil, let p?): return "<m:sSup><m:e>\(xml(base))</m:e><m:sup>\(xml(p))</m:sup></m:sSup>"
            default: return xml(base)
            }
        case .sqrt(let body, let index):
            if let i = index { return "<m:rad><m:radPr/><m:deg>\(xml(i))</m:deg><m:e>\(xml(body))</m:e></m:rad>" }
            return "<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(xml(body))</m:e></m:rad>"
        case .nary(let sym, let sub, let sup):
            let loc = (sym == "∫" || sym == "∮" || sym == "∬") ? "subSup" : "undOvr"
            return "<m:nary><m:naryPr><m:chr m:val=\"\(sym)\"/><m:limLoc m:val=\"\(loc)\"/>"
                + (sub == nil ? "<m:subHide m:val=\"1\"/>" : "") + (sup == nil ? "<m:supHide m:val=\"1\"/>" : "")
                + "</m:naryPr><m:sub>\(sub.map(xml) ?? "")</m:sub><m:sup>\(sup.map(xml) ?? "")</m:sup><m:e/></m:nary>"
        case .fenced(let o, let body, let c):
            return "<m:d><m:dPr><m:begChr m:val=\"\(xmlEscape(o))\"/><m:endChr m:val=\"\(xmlEscape(c))\"/></m:dPr><m:e>\(xml(body))</m:e></m:d>"
        }
    }

    // MARK: Import (OMML → LaTeX-style source)

    private static let naryCommands: [String: String] = ["∑": "\\sum", "∏": "\\prod", "∫": "\\int", "∮": "\\oint", "∬": "\\iint", "⋃": "\\bigcup", "⋂": "\\bigcap"]

    private static func text(_ node: XNode) -> String {
        var s = ""
        for t in node.descendants("m:t") { s += t.text }
        return s
    }

    private static func group(_ node: XNode?) -> String {
        guard let node else { return "{}" }
        return "{" + latex(node) + "}"
    }

    static func latex(_ node: XNode) -> String {
        func kids() -> String { node.children.map(latex).joined() }
        switch node.name {
        case "m:r":
            var t = text(node)
            let upright = node.child("m:rPr")?.child("m:sty")?.attrs["m:val"] == "p"
            t = t.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
                .replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "_", with: " ")
            if upright, t.count > 1, t.allSatisfy({ $0.isLetter }) { return "\\mathrm{\(t)}" }
            return t
        case "m:f": return "\\frac" + group(node.child("m:num")) + group(node.child("m:den"))
        case "m:sSub": return group(node.child("m:e")) + "_" + group(node.child("m:sub"))
        case "m:sSup": return group(node.child("m:e")) + "^" + group(node.child("m:sup"))
        case "m:sSubSup": return group(node.child("m:e")) + "_" + group(node.child("m:sub")) + "^" + group(node.child("m:sup"))
        case "m:sPre": return group(node.child("m:e"))
        case "m:rad":
            let hide = node.child("m:radPr")?.child("m:degHide")?.attrs["m:val"]
            let deg = node.child("m:deg").map(latex) ?? ""
            if hide == "1" || hide == "true" || deg.isEmpty { return "\\sqrt" + group(node.child("m:e")) }
            return "\\sqrt[\(deg)]" + group(node.child("m:e"))
        case "m:nary":
            let chr = node.child("m:naryPr")?.child("m:chr")?.attrs["m:val"] ?? "∫"
            let cmd = naryCommands[chr] ?? "\\int"
            var s = cmd
            if let sub = node.child("m:sub"), !latex(sub).isEmpty { s += "_" + group(sub) }
            if let sup = node.child("m:sup"), !latex(sup).isEmpty { s += "^" + group(sup) }
            return s + " " + latex(node.child("m:e") ?? XNode("m:e"))
        case "m:d":
            let pr = node.child("m:dPr")
            let beg = pr?.child("m:begChr")?.attrs["m:val"] ?? "("
            let end = pr?.child("m:endChr")?.attrs["m:val"] ?? ")"
            let parts = node.kids("m:e").map(latex).joined(separator: " , ")
            return "\\left\(beg.isEmpty ? "." : beg) \(parts) \\right\(end.isEmpty ? "." : end)"
        case "m:func": return latex(node.child("m:fName") ?? XNode("m:fName")) + " " + latex(node.child("m:e") ?? XNode("m:e"))
        case "m:limLow": return group(node.child("m:e")) + "_" + group(node.child("m:lim"))
        case "m:limUpp": return group(node.child("m:e")) + "^" + group(node.child("m:lim"))
        case "m:m": return node.kids("m:mr").map { $0.kids("m:e").map(latex).joined(separator: " ") }.joined(separator: " ; ")
        case "m:eqArr": return node.kids("m:e").map(latex).joined(separator: " ; ")
        case "m:rPr", "m:ctrlPr", "m:naryPr", "m:dPr", "m:radPr", "m:fPr", "m:funcPr", "w:rPr": return ""
        default: return kids()
        }
    }
}

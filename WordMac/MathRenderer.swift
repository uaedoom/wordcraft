import AppKit

indirect enum MathNode {
    case row([MathNode])
    case text(String, italic: Bool)
    case frac(MathNode, MathNode)
    case script(base: MathNode, sub: MathNode?, sup: MathNode?)
    case sqrt(MathNode, index: MathNode?)
    case nary(symbol: String, sub: MathNode?, sup: MathNode?)
    case fenced(open: String, body: MathNode, close: String)
}

/// Parses a LaTeX-style subset: \frac{a}{b}, x^2, x_i, \sqrt[n]{x}, \sum_{i=1}^{n}, \int_a^b, \left( ... \right), Greek letters, operators.
struct MathParser {
    private var s: [Character]
    private var i = 0

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "infty": "∞", "pm": "±", "mp": "∓", "times": "×", "cdot": "·", "div": "÷", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥",
        "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔", "partial": "∂", "nabla": "∇", "in": "∈", "notin": "∉",
        "subset": "⊂", "supset": "⊃", "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨",
        "ldots": "…", "cdots": "⋯", "degree": "°", "angle": "∠", "perp": "⊥", "parallel": "∥", "emptyset": "∅", "prime": "′",
        "lt": "<", "gt": ">", "hbar": "ħ", "ell": "ℓ", "mid": "|",
    ]
    static let binary: Set<String> = ["+", "-", "=", "<", ">", "±", "∓", "×", "·", "÷", "≤", "≥", "≠", "≈", "≡", "→", "←", "⇒", "∈", "∉", "⊂", "∪", "∩"]
    static let nary: [String: String] = ["sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "iint": "∬", "bigcup": "⋃", "bigcap": "⋂"]
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "lim", "max", "min", "det", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh"]

    init(_ source: String) { s = Array(source) }

    mutating func parse() -> MathNode { parseRow() }

    private func peekCommand() -> String? {
        guard i < s.count, s[i] == "\\" else { return nil }
        var j = i + 1, name = ""
        while j < s.count, s[j].isLetter { name.append(s[j]); j += 1 }
        return name
    }

    private mutating func parseRow() -> MathNode {
        var items: [MathNode] = []
        while i < s.count {
            if s[i] == "}" { break }
            if peekCommand() == "right" { break }
            if let atom = parseAtom() { items.append(parseScripts(atom)) }
        }
        return .row(items)
    }

    private mutating func parseGroupOrAtom() -> MathNode {
        while i < s.count, s[i] == " " { i += 1 }
        guard i < s.count else { return .row([]) }
        if s[i] == "{" {
            i += 1
            let r = parseRow()
            if i < s.count, s[i] == "}" { i += 1 }
            return r
        }
        return parseAtom() ?? .row([])
    }

    private mutating func parseScripts(_ base: MathNode) -> MathNode {
        var node = base
        var sub: MathNode?, sup: MathNode?
        while i < s.count {
            while i < s.count, s[i] == " " { i += 1 }
            guard i < s.count else { break }
            if s[i] == "^" { i += 1; sup = parseGroupOrAtom() }
            else if s[i] == "_" { i += 1; sub = parseGroupOrAtom() }
            else { break }
        }
        if sub != nil || sup != nil {
            if case .nary(let sym, _, _) = base { node = .nary(symbol: sym, sub: sub, sup: sup) }
            else { node = .script(base: base, sub: sub, sup: sup) }
        }
        return node
    }

    private mutating func parseAtom() -> MathNode? {
        guard i < s.count else { return nil }
        let c = s[i]
        if c == " " || c == "\n" { i += 1; return nil }
        if c == "{" { return parseGroupOrAtom() }
        if c == "^" || c == "_" { return .row([]) }       // script without a base
        if c == "\\" {
            guard let name = peekCommand() else { i += 2; return nil }
            if name.isEmpty {                                  // \, \; \! \  \\ \{ \}
                let next = i + 1 < s.count ? s[i + 1] : " "
                i += 2
                if next == "{" || next == "}" || next == "|" { return .text(String(next), italic: false) }
                return next == "," || next == ";" || next == " " ? .text("\u{2009}", italic: false) : nil
            }
            i += 1 + name.count
            switch name {
            case "frac", "dfrac":
                let a = parseGroupOrAtom(), b = parseGroupOrAtom()
                return .frac(a, b)
            case "sqrt":
                var index: MathNode?
                if i < s.count, s[i] == "[" {
                    i += 1
                    var inner = MathParser(String(s[i...]))
                    var depth = 0, j = i
                    while j < s.count, !(s[j] == "]" && depth == 0) { if s[j] == "[" { depth += 1 }; if s[j] == "]" { depth -= 1 }; j += 1 }
                    inner = MathParser(String(s[i..<j]))
                    index = inner.parse()
                    i = min(s.count, j + 1)
                }
                return .sqrt(parseGroupOrAtom(), index: index)
            case "left":
                let open = i < s.count ? String(s[i]) : "("
                i += 1
                let body = parseRow()
                var close = ")"
                if peekCommand() == "right" { i += 6; if i < s.count { close = String(s[i]); i += 1 } }
                return .fenced(open: open == "." ? "" : open, body: body, close: close == "." ? "" : close)
            case "text", "mathrm", "mathbf", "operatorname":
                let g = parseGroupOrAtom()
                return .text(Self.plain(g), italic: false)
            case "mathit":
                return .text(Self.plain(parseGroupOrAtom()), italic: true)
            case "lbrace": return .text("{", italic: false)
            case "rbrace": return .text("}", italic: false)
            case "langle": return .text("⟨", italic: false)
            case "rangle": return .text("⟩", italic: false)
            case "quad": return .text("\u{2003}", italic: false)
            default: break
            }
            if let sym = Self.nary[name] { return .nary(symbol: sym, sub: nil, sup: nil) }
            if Self.functions.contains(name) { return .text(name + "\u{2009}", italic: false) }
            if let sym = Self.symbols[name] {
                let greekLower = sym.unicodeScalars.first.map { (0x3B1...0x3C9).contains($0.value) } ?? false
                if Self.binary.contains(sym) { return .text("\u{2005}" + sym + "\u{2005}", italic: false) }
                return .text(sym, italic: greekLower)
            }
            return .text(name, italic: false)
        }
        if c.isLetter { i += 1; return .text(String(c), italic: true) }
        if c.isNumber || c == "." {
            var d = ""
            while i < s.count, s[i].isNumber || s[i] == "." { d.append(s[i]); i += 1 }
            return .text(d, italic: false)
        }
        i += 1
        let str = String(c)
        if Self.binary.contains(str) { return .text("\u{2005}" + (str == "-" ? "−" : str) + "\u{2005}", italic: false) }
        return .text(str, italic: false)
    }

    private static func plain(_ n: MathNode) -> String {
        switch n {
        case .text(let t, _): return t
        case .row(let items): return items.map(plain).joined()
        default: return ""
        }
    }
}

struct MathBox {
    var width: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    /// Draws with its left edge at x and baseline at y (y up).
    var draw: (CGFloat, CGFloat) -> Void
}

enum MathRenderer {
    static func font(_ size: CGFloat, italic: Bool) -> NSFont {
        NSFont(name: italic ? "STIXGeneral-Italic" : "STIXGeneral-Regular", size: size)
            ?? NSFont(name: italic ? "TimesNewRomanPS-ItalicMT" : "TimesNewRomanPSMT", size: size)
            ?? .systemFont(ofSize: size)
    }

    static func layout(_ node: MathNode, size: CGFloat) -> MathBox {
        switch node {
        case .row(let items):
            let boxes = items.map { layout($0, size: size) }
            let w = boxes.reduce(0) { $0 + $1.width }
            let asc = boxes.map(\.ascent).max() ?? size * 0.7
            let desc = boxes.map(\.descent).max() ?? size * 0.2
            return MathBox(width: w, ascent: asc, descent: desc) { x, y in
                var cx = x
                for b in boxes { b.draw(cx, y); cx += b.width }
            }

        case .text(let t, let italic):
            let f = font(size, italic: italic)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.black]
            let w = (t as NSString).size(withAttributes: attrs).width
            return MathBox(width: w, ascent: f.ascender * 0.9, descent: -f.descender) { x, y in
                (t as NSString).draw(at: NSPoint(x: x, y: y + f.descender), withAttributes: attrs)
            }

        case .frac(let n, let d):
            let nb = layout(n, size: size * 0.9), db = layout(d, size: size * 0.9)
            let axis = size * 0.27, gap = size * 0.12, bar = max(0.8, size * 0.055)
            let w = max(nb.width, db.width) + size * 0.2
            let numBase = axis + bar / 2 + gap + nb.descent
            let denBase = axis - bar / 2 - gap - db.ascent
            return MathBox(width: w, ascent: numBase + nb.ascent, descent: -(denBase - db.descent)) { x, y in
                nb.draw(x + (w - nb.width) / 2, y + numBase)
                db.draw(x + (w - db.width) / 2, y + denBase)
                NSColor.black.setFill()
                NSRect(x: x + size * 0.05, y: y + axis - bar / 2, width: w - size * 0.1, height: bar).fill()
            }

        case .script(let base, let sub, let sup):
            let b = layout(base, size: size)
            let sb = sub.map { layout($0, size: size * 0.7) }
            let pb = sup.map { layout($0, size: size * 0.7) }
            let supBase = max(size * 0.38, b.ascent * 0.62)
            var subBase = -max(size * 0.18, b.descent * 0.6 + size * 0.1)
            if let sb, let pb {
                let gap = (supBase - pb.descent) - (subBase + sb.ascent)
                if gap < size * 0.12 { subBase -= (size * 0.12 - gap) }
            }
            let sw = max(sb?.width ?? 0, pb?.width ?? 0)
            return MathBox(width: b.width + sw + size * 0.04,
                           ascent: max(b.ascent, pb.map { supBase + $0.ascent } ?? 0),
                           descent: max(b.descent, sb.map { -subBase + $0.descent } ?? 0)) { x, y in
                b.draw(x, y)
                pb?.draw(x + b.width + size * 0.03, y + supBase)
                sb?.draw(x + b.width + size * 0.03, y + subBase)
            }

        case .sqrt(let body, let index):
            let b = layout(body, size: size)
            let ib = index.map { layout($0, size: size * 0.55) }
            let rw = size * 0.6, pad = size * 0.1, ink = max(0.8, size * 0.05)
            let top = b.ascent + size * 0.14, bottom = -b.descent - size * 0.04
            let lead = max(0, (ib?.width ?? 0) - rw * 0.45)
            return MathBox(width: lead + rw + b.width + pad, ascent: top + ink, descent: -bottom) { x, y in
                let x0 = x + lead
                let h = top - bottom
                let path = NSBezierPath()
                path.lineWidth = ink
                path.lineJoinStyle = .miter
                path.move(to: NSPoint(x: x0, y: y + bottom + h * 0.42))
                path.line(to: NSPoint(x: x0 + rw * 0.22, y: y + bottom + h * 0.5))
                path.line(to: NSPoint(x: x0 + rw * 0.5, y: y + bottom))
                path.line(to: NSPoint(x: x0 + rw, y: y + top))
                path.line(to: NSPoint(x: x0 + rw + b.width + pad, y: y + top))
                NSColor.black.setStroke()
                path.stroke()
                b.draw(x0 + rw, y)
                ib?.draw(x, y + bottom + h * 0.55)
            }

        case .nary(let sym, let sub, let sup):
            let isIntegral = sym == "∫" || sym == "∮" || sym == "∬"
            let big = font(size * (isIntegral ? 1.7 : 1.45), italic: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: big, .foregroundColor: NSColor.black]
            let sw = (sym as NSString).size(withAttributes: attrs).width
            let axis = size * 0.27
            let capH = big.capHeight
            let base0 = axis - capH / 2
            let sb = sub.map { layout($0, size: size * 0.7) }
            let pb = sup.map { layout($0, size: size * 0.7) }
            let symAsc = base0 + capH, symDesc = max(0, -base0) + capH * 0.12
            if isIntegral {
                let sx = sw + size * 0.05
                let supBase = symAsc - (pb?.ascent ?? 0) * 0.5
                let subBase = -symDesc + (sb?.ascent ?? 0) * 0.3
                let w = sw + max(sb?.width ?? 0, pb?.width ?? 0) + size * 0.1
                return MathBox(width: w, ascent: max(symAsc, pb.map { supBase + $0.ascent } ?? 0),
                               descent: max(symDesc, sb.map { -subBase + $0.descent } ?? 0)) { x, y in
                    (sym as NSString).draw(at: NSPoint(x: x, y: y + base0 + big.descender), withAttributes: attrs)
                    pb?.draw(x + sx + size * 0.2, y + supBase)
                    sb?.draw(x + sx - size * 0.15, y + subBase)
                }
            }
            let gap = size * 0.08
            let w = max(sw, sb?.width ?? 0, pb?.width ?? 0) + size * 0.05
            let supBase = symAsc + gap + (pb?.descent ?? 0)
            let subBase = -symDesc - gap - (sb?.ascent ?? 0)
            return MathBox(width: w, ascent: pb.map { supBase + $0.ascent } ?? symAsc,
                           descent: sb.map { -subBase + $0.descent } ?? symDesc) { x, y in
                (sym as NSString).draw(at: NSPoint(x: x + (w - sw) / 2, y: y + base0 + big.descender), withAttributes: attrs)
                pb?.draw(x + (w - pb!.width) / 2, y + supBase)
                sb?.draw(x + (w - sb!.width) / 2, y + subBase)
            }

        case .fenced(let open, let body, let close):
            let b = layout(body, size: size)
            let half = max(b.ascent, b.descent) + size * 0.08
            let k = max(1, (2 * half) / (size * 1.0))
            let f = font(size, italic: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.black]
            func delimWidth(_ d: String) -> CGFloat { d.isEmpty ? size * 0.1 : (d as NSString).size(withAttributes: attrs).width * (k > 1.2 ? 1.1 : 1) }
            let ow = delimWidth(open), cw = delimWidth(close)
            func drawDelim(_ d: String, x: CGFloat, y: CGFloat) {
                guard !d.isEmpty else { return }
                let ctx = NSGraphicsContext.current!.cgContext
                ctx.saveGState()
                let mid = (b.ascent - b.descent) / 2
                ctx.translateBy(x: x, y: y + mid)
                ctx.scaleBy(x: 1, y: k)
                (d as NSString).draw(at: NSPoint(x: 0, y: -size * 0.25 + f.descender), withAttributes: attrs)
                ctx.restoreGState()
            }
            return MathBox(width: ow + b.width + cw, ascent: max(b.ascent, half * 0.9 + (b.ascent - b.descent) / 2),
                           descent: max(b.descent, half * 0.9 - (b.ascent - b.descent) / 2)) { x, y in
                drawDelim(open, x: x, y: y)
                b.draw(x + ow, y)
                drawDelim(close, x: x + ow + b.width, y: y)
            }
        }
    }

    /// Draws the equation to an image; `descent` is how far the baseline sits above the image bottom.
    static func render(_ source: String, fontSize: CGFloat) -> (image: NSImage, descent: CGFloat) {
        var parser = MathParser(source)
        let box = layout(parser.parse(), size: fontSize)
        let pad: CGFloat = 2
        let w = max(4, box.width + pad * 2)
        let h = max(4, box.ascent + box.descent + pad * 2)
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            box.draw(pad, pad + box.descent)
            return true
        }
        return (image, box.descent + pad)
    }
}

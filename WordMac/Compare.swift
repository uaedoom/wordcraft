import AppKit

/// Longest-common-subsequence diff used by Compare.
enum Diff {
    enum Op { case equal(Int, Int), delete(Int), insert(Int) }

    static func ops<T: Equatable>(_ a: [T], _ b: [T]) -> [Op]? {
        let n = a.count, m = b.count
        guard (n + 1) * (m + 1) <= 18_000_000 else { return nil }
        var t = [UInt32](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i * w + j] = a[i] == b[j] ? t[(i + 1) * w + j + 1] + 1 : max(t[(i + 1) * w + j], t[i * w + j + 1])
            }
        }
        var out: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.append(.equal(i, j)); i += 1; j += 1 }
            else if t[(i + 1) * w + j] >= t[i * w + j + 1] { out.append(.delete(i)); i += 1 }
            else { out.append(.insert(j)); j += 1 }
        }
        while i < n { out.append(.delete(i)); i += 1 }
        while j < m { out.append(.insert(j)); j += 1 }
        return out
    }

    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = "", kind = 0
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for ch in s {
            let k = (ch.isLetter || ch.isNumber) ? 1 : (ch.isWhitespace ? 2 : 0)
            if k == 0 { flush(); kind = 0; out.append(String(ch)) }
            else if k == kind { cur.append(ch) }
            else { flush(); cur = String(ch); kind = k }
        }
        flush()
        return out
    }
}

extension EditorController {
    private enum Edit {
        case markInsert(NSRange)
        case insertDeleted(String, at: Int)
        var location: Int {
            switch self { case .markInsert(let r): return r.location; case .insertDeleted(_, let at): return at }
        }
    }

    func compareWithOriginal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wordMac, .docx, .dotx, .rtf, .plainText]
        panel.message = "Choose the original document to compare this one against"
        guard panel.runModal() == .OK, let url = panel.url,
              let wrapper = try? FileWrapper(url: url, options: []),
              let loaded = try? RichTextDocument.load(wrapper) else { return }
        compare(original: loaded.attributed.string)
    }

    /// Marks differences against `original` as tracked changes in this document.
    func compare(original: String) {
        guard let tv = bodyTextView, let st = tv.textStorage, canEditText else { return }
        let oPars = original.replacingOccurrences(of: "\u{200B}", with: "").components(separatedBy: "\n")
        let cText = st.string
        let cPars = cText.components(separatedBy: "\n")
        var cStarts: [Int] = []
        var pos = 0
        for p in cPars { cStarts.append(pos); pos += (p as NSString).length + 1 }
        func cStart(_ i: Int) -> Int { min(cStarts[min(i, cStarts.count - 1)], st.length) }

        var edits: [Edit] = []
        func wordDiff(_ o: String, _ c: String, base: Int) {
            let ta = Diff.tokens(o), tb = Diff.tokens(c)
            guard let ops = Diff.ops(ta, tb) else {
                if !o.isEmpty { edits.append(.insertDeleted(o, at: base)) }
                if !c.isEmpty { edits.append(.markInsert(NSRange(location: base, length: (c as NSString).length))) }
                return
            }
            var p = base
            var pending = ""
            func flushDeleted() { if !pending.isEmpty { edits.append(.insertDeleted(pending, at: p)); pending = "" } }
            for op in ops {
                switch op {
                case .equal(_, let j): flushDeleted(); p += (tb[j] as NSString).length
                case .delete(let i): pending += ta[i]
                case .insert(let j):
                    let len = (tb[j] as NSString).length
                    flushDeleted()
                    edits.append(.markInsert(NSRange(location: p, length: len)))
                    p += len
                }
            }
            flushDeleted()
        }

        if let ops = Diff.ops(oPars, cPars) {
            var dels: [Int] = [], ins: [Int] = []
            var nextC = 0
            func flushHunk(nextC: Int) {
                let pairs = min(dels.count, ins.count)
                for k in 0..<pairs { wordDiff(oPars[dels[k]], cPars[ins[k]], base: cStart(ins[k])) }
                if dels.count > pairs {
                    let text = dels[pairs...].map { oPars[$0] }.joined(separator: "\n") + "\n"
                    edits.append(.insertDeleted(text, at: cStart(nextC)))
                }
                if ins.count > pairs {
                    for k in pairs..<ins.count {
                        let s = cStart(ins[k])
                        let len = (cPars[ins[k]] as NSString).length + (ins[k] < cPars.count - 1 ? 1 : 0)
                        if len > 0 { edits.append(.markInsert(NSRange(location: s, length: len))) }
                    }
                }
                dels = []; ins = []
            }
            for op in ops {
                switch op {
                case .equal(_, let j):
                    if !dels.isEmpty || !ins.isEmpty { flushHunk(nextC: j) }
                    nextC = j + 1
                case .delete(let i): dels.append(i)
                case .insert(let j): ins.append(j)
                }
            }
            flushHunk(nextC: cPars.count - 1)
        } else {
            NSSound.beep()
            return
        }

        let me = author
        let ins = RevisionInfo(kind: .insert, author: me, date: Date()).encoded
        let del = RevisionInfo(kind: .delete, author: me, date: Date()).encoded
        applyingTracked = true
        defer { applyingTracked = false }
        tv.undoManager?.beginUndoGrouping()
        // later edits first so earlier offsets stay valid; ties: mark insertions before inserting deleted text
        let ordered = edits.enumerated().sorted { a, b in
            if a.element.location != b.element.location { return a.element.location > b.element.location }
            let aMark: Bool = { if case .markInsert = a.element { return true }; return false }()
            let bMark: Bool = { if case .markInsert = b.element { return true }; return false }()
            if aMark != bMark { return aMark }
            return a.offset > b.offset
        }
        for (_, e) in ordered {
            switch e {
            case .markInsert(let r):
                guard NSMaxRange(r) <= st.length, r.length > 0, tv.shouldChangeText(in: r, replacementString: nil) else { continue }
                st.addAttribute(.wcRevision, value: ins, range: r)
                tv.didChangeText()
            case .insertDeleted(let text, let at):
                var attrs = st.length > 0 ? st.attributes(at: min(at, st.length - 1), effectiveRange: nil) : [:]
                for k in [NSAttributedString.Key.wcRevision, .wcComment, .link, .wcFootnote, .wcEndnote, .attachment, .wcImage, .wcEquation, .wcObject, .wcSection] { attrs.removeValue(forKey: k) }
                attrs[.wcRevision] = del
                let r = NSRange(location: min(at, st.length), length: 0)
                if tv.shouldChangeText(in: r, replacementString: text) {
                    st.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: attrs))
                    tv.didChangeText()
                }
            }
        }
        tv.undoManager?.setActionName("Compare Documents")
        tv.undoManager?.endUndoGrouping()
        showReview = true
        reviewTab = 0
        scheduleMarkup()
    }
}

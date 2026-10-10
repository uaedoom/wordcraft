import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func shortID() -> String { String(UUID().uuidString.prefix(8)) }

// MARK: - Generic block helpers

extension EditorController {
    /// Replaces (or inserts at the caret paragraph) a generated block marked with `key`.
    func replaceBlock(_ key: NSAttributedString.Key, with block: NSAttributedString, actionName: String) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        var target: NSRange
        if let existing = blockRange(key) { target = existing }
        else {
            let ns = tv.string as NSString
            let loc = ns.paragraphRange(for: NSRange(location: min(tv.selectedRange().location, ns.length), length: 0)).location
            target = NSRange(location: loc, length: 0)
        }
        guard block.string != (target.length > 0 ? (st.string as NSString).substring(with: target) : "\u{0}") else { return }
        applyingTracked = true
        defer { applyingTracked = false }
        tv.undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: target, replacementString: block.string) {
            st.replaceCharacters(in: target, with: block)
            tv.didChangeText()
        }
        tv.undoManager?.setActionName(actionName)
        tv.undoManager?.endUndoGrouping()
    }

    func styled(_ text: String, _ styleID: String, extra: [NSAttributedString.Key: Any] = [:], tweak: ((NSMutableParagraphStyle) -> Void)? = nil) -> NSAttributedString {
        let def = style(styleID) ?? StyleDef.make(styleID, styleID)
        var a = def.attributes(preserving: nil)
        if let tweak, let ps = a[.paragraphStyle] as? NSMutableParagraphStyle { tweak(ps) }
        for (k, v) in extra { a[k] = v }
        return NSAttributedString(string: text, attributes: a)
    }

    /// Runs `f` for every run carrying `key`, last to first, replacing its text. Generated edits are not tracked.
    func rewriteRuns(_ key: NSAttributedString.Key, _ newText: (NSRange, Any, [NSAttributedString.Key: Any]) -> String?) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        var runs: [(NSRange, Any, [NSAttributedString.Key: Any])] = []
        st.enumerateAttribute(key, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            if let v { runs.append((r, v, st.attributes(at: r.location, effectiveRange: nil))) }
        }
        guard !runs.isEmpty else { return }
        applyingTracked = true
        defer { applyingTracked = false }
        tv.undoManager?.beginUndoGrouping()
        for (r, v, a) in runs.reversed() {
            guard let t = newText(r, v, a), t != (st.string as NSString).substring(with: r),
                  tv.shouldChangeText(in: r, replacementString: t) else { continue }
            st.replaceCharacters(in: r, with: NSAttributedString(string: t, attributes: a))
            tv.didChangeText()
        }
        tv.undoManager?.endUndoGrouping()
    }
}

// MARK: - Update all fields

extension EditorController {
    func updateAllFields() {
        engine?.settle()
        updateCaptions()
        updateCitations()
        if blockRange(.wcBib) != nil { insertBibliography() }
        engine?.settle()
        updateXrefs()
        if blockRange(.wcIndexBlock) != nil { insertIndex() }
        if blockRange(.wcEndnotes) != nil { updateEndnotesBlock() }
        if hasTOC { insertTableOfContents() }
        engine?.settle()
        updateXrefs()
    }
}

// MARK: - Mail merge

extension EditorController {
    var mergeColumns: [String] { meta.mergeData?.columns ?? [] }
    var mergeCount: Int { meta.mergeData?.rows.count ?? 0 }

    func importMergeData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV or tab-separated recipients file (first row = field names)"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return }
        let data = MergeData.parse(text)
        guard !data.columns.isEmpty else { NSSound.beep(); return }
        restoreMergeFields()
        updateMeta("Select Recipients") { $0.mergeData = data }
        mergeIndex = 0
    }

    func insertMergeField(_ name: String) {
        guard let tv = bodyTextView else { return }
        var a = tv.typingAttributes
        a[.wcMerge] = name
        a[.backgroundColor] = NSColor(calibratedWhite: 0.86, alpha: 1)
        tv.insertText(NSAttributedString(string: "«\(name)»", attributes: a), replacementRange: tv.selectedRange())
        sanitizeTypingAttributes(tv)
        tv.window?.makeFirstResponder(tv)
    }

    /// Puts «Field» placeholders back where a preview substituted values.
    func restoreMergeFields() {
        guard let st = engine?.storage, let tv = bodyTextView else { return }
        var runs: [(NSRange, String)] = []
        st.enumerateAttribute(.wcMergeValue, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            if v != nil, let n = st.attribute(.wcMerge, at: r.location, effectiveRange: nil) as? String { runs.append((r, n)) }
        }
        tv.undoManager?.disableUndoRegistration()
        st.beginEditing()
        for (r, n) in runs.reversed() {
            var a = st.attributes(at: r.location, effectiveRange: nil)
            a.removeValue(forKey: .wcMergeValue)
            a[.backgroundColor] = NSColor(calibratedWhite: 0.86, alpha: 1)
            st.replaceCharacters(in: r, with: NSAttributedString(string: "«\(n)»", attributes: a))
        }
        st.endEditing()
        tv.undoManager?.enableUndoRegistration()
        mergePreviewing = false
    }

    /// Shows recipient `index` in place of the placeholders (nil switches the preview off).
    func previewMerge(_ index: Int?) {
        restoreMergeFields()
        guard let index, let data = meta.mergeData, index >= 0, index < data.rows.count, let st = engine?.storage, let tv = bodyTextView else { return }
        var runs: [(NSRange, String)] = []
        st.enumerateAttribute(.wcMerge, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            if let n = v as? String { runs.append((r, n)) }
        }
        tv.undoManager?.disableUndoRegistration()
        st.beginEditing()
        for (r, n) in runs.reversed() {
            let value = data.columns.firstIndex(of: n).map { data.rows[index][$0] } ?? ""
            var a = st.attributes(at: r.location, effectiveRange: nil)
            a[.wcMergeValue] = 1
            a.removeValue(forKey: .backgroundColor)
            st.replaceCharacters(in: r, with: NSAttributedString(string: value, attributes: a))
        }
        st.endEditing()
        tv.undoManager?.enableUndoRegistration()
        mergePreviewing = true
        mergeIndex = index
    }

    func stepMerge(_ d: Int) {
        guard mergeCount > 0 else { return }
        previewMerge((mergeIndex + d + mergeCount) % mergeCount)
    }

    /// Builds one letter per recipient (separated by page breaks) in a new untitled document.
    func finishMerge() {
        guard let st = engine?.storage, let data = meta.mergeData, !data.rows.isEmpty else { NSSound.beep(); return }
        restoreMergeFields()
        let template = AttachmentBuilder.stripped(st)
        let out = NSMutableAttributedString()
        for (i, row) in data.rows.enumerated() {
            let copy = NSMutableAttributedString(attributedString: template)
            var runs: [(NSRange, String)] = []
            copy.enumerateAttribute(.wcMerge, in: NSRange(location: 0, length: copy.length), options: []) { v, r, _ in
                if let n = v as? String { runs.append((r, n)) }
            }
            for (r, n) in runs.reversed() {
                var a = copy.attributes(at: r.location, effectiveRange: nil)
                a.removeValue(forKey: .wcMerge); a.removeValue(forKey: .backgroundColor)
                copy.replaceCharacters(in: r, with: NSAttributedString(string: data.columns.firstIndex(of: n).map { row[$0] } ?? "", attributes: a))
            }
            if i > 0 {                               // floating objects stay with the first letter
                var anchors: [NSRange] = []
                copy.enumerateAttribute(.wcObject, in: NSRange(location: 0, length: copy.length), options: []) { v, r, _ in if v != nil { anchors.append(r) } }
                for r in anchors.reversed() { copy.deleteCharacters(in: r) }
                out.append(NSAttributedString(string: "\u{000C}", attributes: template.length > 0 ? template.attributes(at: 0, effectiveRange: nil) : [:]))
            }
            out.append(copy)
        }
        var m = meta
        m.mergeData = nil
        m.comments = [:]
        PendingDocument.payload = (out, m, document?.assets.data ?? [:])
        NSDocumentController.shared.newDocument(nil)
    }
}

// MARK: - Citations and bibliography

extension EditorController {
    var citationStyle: CitationStyle { CitationStyle(rawValue: meta.citationStyle) ?? .apa }

    func setCitationStyle(_ s: CitationStyle) {
        updateMeta("Citation Style") { $0.citationStyle = s.rawValue }
        updateCitations()
        if blockRange(.wcBib) != nil { insertBibliography() }
    }

    func saveSource(_ s: Source) {
        updateMeta("Source") { m in
            if let i = m.sources.firstIndex(where: { $0.id == s.id }) { m.sources[i] = s } else { m.sources.append(s) }
        }
        updateCitations()
        if blockRange(.wcBib) != nil { insertBibliography() }
    }

    func deleteSource(_ id: String) { updateMeta("Delete Source") { $0.sources.removeAll { $0.id == id } } }

    /// Sources in the order they are first cited.
    private func citedTags() -> [String] {
        guard let st = engine?.storage else { return [] }
        var tags: [String] = []
        st.enumerateAttribute(.wcCite, in: NSRange(location: 0, length: st.length), options: []) { v, _, _ in
            if let s = v as? String, let tag = s.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init), !tags.contains(tag) { tags.append(tag) }
        }
        return tags
    }

    func insertCitation(tag: String, page: String) {
        guard let tv = bodyTextView, let src = meta.sources.first(where: { $0.id == tag }) else { return }
        var a = tv.typingAttributes
        a[.wcCite] = "\(tag)|\(page)"
        let text = CitationFormatter.inText(src, style: citationStyle, page: page, number: citedTags().count + 1)
        tv.insertText(NSAttributedString(string: text, attributes: a), replacementRange: tv.selectedRange())
        sanitizeTypingAttributes(tv)
        updateCitations()
    }

    func updateCitations() {
        let order = citedTags()
        let style = citationStyle
        rewriteRuns(.wcCite) { _, v, _ in
            guard let s = v as? String else { return nil }
            let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let tag = parts.first, let src = meta.sources.first(where: { $0.id == tag }) else { return nil }
            return CitationFormatter.inText(src, style: style, page: parts.count > 1 ? parts[1] : "", number: (order.firstIndex(of: tag) ?? 0) + 1)
        }
    }

    func insertBibliography() {
        guard let st = engine?.storage else { return }
        let style = citationStyle
        let cited = citedTags()
        var list = meta.sources.filter { cited.contains($0.id) }
        if list.isEmpty && blockRange(.wcBib) == nil { list = meta.sources }
        if style == .ieee { list.sort { (cited.firstIndex(of: $0.id) ?? 0) < (cited.firstIndex(of: $1.id) ?? 0) } }
        else {
            list.sort {
                let a = CitationFormatter.names($0).first?.last ?? $0.title, b = CitationFormatter.names($1).first?.last ?? $1.title
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        let block = NSMutableAttributedString()
        block.append(styled(style.bibliographyTitle + "\n", "h1", extra: [.wcBib: 1]))
        let normal = style_("normal")
        for (i, s) in list.enumerated() {
            let e = NSMutableAttributedString(attributedString: CitationFormatter.entry(s, style: style, number: i + 1, font: normal.font()))
            e.append(NSAttributedString(string: "\n"))
            var attrs = normal.attributes(preserving: nil)
            if let ps = attrs[.paragraphStyle] as? NSMutableParagraphStyle, style != .ieee { ps.headIndent = 36; ps.firstLineHeadIndent = 0 }
            attrs.removeValue(forKey: .font)
            e.addAttributes(attrs, range: NSRange(location: 0, length: e.length))
            e.addAttribute(.wcBib, value: 1, range: NSRange(location: 0, length: e.length))
            block.append(e)
        }
        _ = st
        replaceBlock(.wcBib, with: block, actionName: "Bibliography")
    }

    private func style_(_ id: String) -> StyleDef { style(id) ?? StyleDef.make(id, id) }

    func removeBibliography() {
        guard let tv = bodyTextView, let st = tv.textStorage, let r = blockRange(.wcBib), tv.shouldChangeText(in: r, replacementString: "") else { return }
        st.deleteCharacters(in: r)
        tv.didChangeText()
    }
}

// MARK: - Bookmarks, captions, cross-references

extension EditorController {
    struct BookmarkInfo: Identifiable { var id: String { name }; var name: String; var range: NSRange; var text: String }

    func bookmarks(includeHidden: Bool = false) -> [BookmarkInfo] {
        guard let st = engine?.storage else { return [] }
        var out: [BookmarkInfo] = []
        let ns = st.string as NSString
        st.enumerateAttribute(.wcBookmark, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            guard let n = v as? String, includeHidden || !n.hasPrefix("_") else { return }
            if let i = out.firstIndex(where: { $0.name == n }) { out[i].range = NSUnionRange(out[i].range, r) }
            else { out.append(BookmarkInfo(name: n, range: r, text: ns.substring(with: r))) }
        }
        return out
    }

    func addBookmark(_ name: String) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        var r = tv.selectedRange()
        if r.length == 0 { r = tv.selectionRange(forProposedRange: r, granularity: .selectByWord) }
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard r.length > 0, !clean.isEmpty, tv.shouldChangeText(in: r, replacementString: nil) else { NSSound.beep(); return }
        st.addAttribute(.wcBookmark, value: clean, range: r)
        tv.didChangeText()
        tv.undoManager?.setActionName("Bookmark")
    }

    func deleteBookmark(_ name: String) {
        guard let tv = bodyTextView, let st = tv.textStorage, let b = bookmarks(includeHidden: true).first(where: { $0.name == name }),
              tv.shouldChangeText(in: b.range, replacementString: nil) else { return }
        st.removeAttribute(.wcBookmark, range: b.range)
        tv.didChangeText()
    }

    /// Existing bookmark over `range`, or a hidden one created for a cross-reference.
    func ensureBookmark(over range: NSRange) -> String? {
        guard let tv = bodyTextView, let st = tv.textStorage, range.length > 0 else { return nil }
        if let n = st.attribute(.wcBookmark, at: range.location, effectiveRange: nil) as? String { return n }
        let name = "_Ref" + shortID()
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return nil }
        st.addAttribute(.wcBookmark, value: name, range: range)
        tv.didChangeText()
        return name
    }

    func goToBookmark(_ name: String) {
        if let b = bookmarks(includeHidden: true).first(where: { $0.name == name }) { show(range: b.range) }
    }

    // MARK: Captions

    struct CaptionInfo: Identifiable { var id: Int { range.location }; var label: String; var number: Int; var range: NSRange; var text: String }

    func captions() -> [CaptionInfo] {
        guard let st = engine?.storage else { return [] }
        var out: [CaptionInfo] = []
        var counts: [String: Int] = [:]
        let ns = st.string as NSString
        st.enumerateAttribute(.wcCaption, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            guard let label = v as? String else { return }
            counts[label, default: 0] += 1
            let para = ns.paragraphRange(for: r)
            out.append(CaptionInfo(label: label, number: counts[label]!, range: r,
                                   text: ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return out
    }

    func insertCaption(label: String) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        let ns = tv.string as NSString
        var at = ns.paragraphRange(for: NSRange(location: min(tv.selectedRange().location, ns.length), length: 0))
        if let g = TableGrid.find(in: st, at: at.location) { at = g.range }
        var loc = NSMaxRange(at)
        let needsLead = loc > 0 && loc <= ns.length && ns.character(at: loc - 1) != 10
        let n = captions().filter { $0.label == label }.count + 1
        let labelText = "\(label) \(n)"
        let def = style("caption") ?? StyleDef.make("caption", "Caption")
        let body = NSMutableAttributedString()
        if needsLead { body.append(NSAttributedString(string: "\n", attributes: def.attributes(preserving: nil))) }
        var labelAttrs = def.attributes(preserving: nil)
        labelAttrs[.wcCaption] = label
        body.append(NSAttributedString(string: labelText, attributes: labelAttrs))
        body.append(NSAttributedString(string: ": \n", attributes: def.attributes(preserving: nil)))
        loc = min(loc, ns.length)
        tv.undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: NSRange(location: loc, length: 0), replacementString: body.string) {
            st.replaceCharacters(in: NSRange(location: loc, length: 0), with: body)
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: loc + body.length - 1, length: 0))
        tv.undoManager?.setActionName("Insert Caption")
        tv.undoManager?.endUndoGrouping()
        updateCaptions()
    }

    func updateCaptions() {
        var counts: [String: Int] = [:]
        // numbering follows document order, but rewrite runs back to front
        guard let st = engine?.storage else { return }
        var order: [NSRange: Int] = [:]
        st.enumerateAttribute(.wcCaption, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            if let label = v as? String { counts[label, default: 0] += 1; order[r] = counts[label]! }
        }
        rewriteRuns(.wcCaption) { r, v, _ in
            guard let label = v as? String, let n = order[r] else { return nil }
            return "\(label) \(n)"
        }
    }

    // MARK: Cross-references

    func xrefText(_ name: String, what: String) -> String {
        guard let b = bookmarks(includeHidden: true).first(where: { $0.name == name }), let engine else { return "Error! Reference source not found." }
        if what == "page" { return "\(engine.pageNumber(forCharacter: b.range.location))" }
        return b.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }

    func insertCrossRef(name: String, what: String) {
        guard let tv = bodyTextView else { return }
        var a = tv.typingAttributes
        let props = XrefProps(name: name, what: what)
        a[.wcXref] = props.json
        tv.insertText(NSAttributedString(string: xrefText(name, what: what), attributes: a), replacementRange: tv.selectedRange())
        sanitizeTypingAttributes(tv)
    }

    func updateXrefs() {
        rewriteRuns(.wcXref) { _, v, _ in
            guard let p = XrefProps.decode(v) else { return nil }
            return xrefText(p.name, what: p.what)
        }
    }
}

// MARK: - Index

extension EditorController {
    func markIndexEntry(main: String, sub: String, all: Bool) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        let value = sub.isEmpty ? main : "\(main)|\(sub)"
        var targets: [NSRange] = []
        if all {
            let ns = st.string as NSString
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let r = ns.range(of: main, options: [.caseInsensitive], range: search)
                if r.location == NSNotFound { break }
                targets.append(r)
                search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
            }
        } else {
            var r = tv.selectedRange()
            if r.length == 0 { r = tv.selectionRange(forProposedRange: r, granularity: .selectByWord) }
            if r.length > 0 { targets = [r] }
        }
        guard !targets.isEmpty else { NSSound.beep(); return }
        tv.undoManager?.beginUndoGrouping()
        for r in targets where tv.shouldChangeText(in: r, replacementString: nil) {
            st.addAttribute(.wcIndex, value: value, range: r)
            tv.didChangeText()
        }
        tv.undoManager?.setActionName("Mark Index Entry")
        tv.undoManager?.endUndoGrouping()
        scheduleMarkup()
    }

    func clearIndexMarks() {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        let full = NSRange(location: 0, length: st.length)
        if tv.shouldChangeText(in: full, replacementString: nil) { st.removeAttribute(.wcIndex, range: full); tv.didChangeText() }
        scheduleMarkup()
    }

    func insertIndex() {
        guard let st = engine?.storage, let engine else { return }
        engine.settle()
        struct E { var main: String; var sub: String; var pages: [Int] }
        var entries: [String: E] = [:]
        st.enumerateAttribute(.wcIndex, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            guard let s = v as? String else { return }
            let p = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let main = p[0], sub = p.count > 1 ? p[1] : ""
            let key = main.lowercased() + "|" + sub.lowercased()
            let page = engine.pageNumber(forCharacter: r.location)
            var e = entries[key] ?? E(main: main, sub: sub, pages: [])
            if !e.pages.contains(page) { e.pages.append(page) }
            entries[key] = e
        }
        func pages(_ p: [Int]) -> String {
            let s = p.sorted()
            var out: [String] = [], i = 0
            while i < s.count {
                var j = i
                while j + 1 < s.count, s[j + 1] == s[j] + 1 { j += 1 }
                out.append(j > i ? "\(s[i])–\(s[j])" : "\(s[i])")
                i = j + 1
            }
            return out.joined(separator: ", ")
        }
        let tab = { (ps: NSMutableParagraphStyle) in ps.tabStops = [NSTextTab(textAlignment: .right, location: self.layout.columnWidth)] }
        let block = NSMutableAttributedString()
        block.append(styled("Index\n", "tocHeading", extra: [.wcIndexBlock: 1]))
        let mains = Dictionary(grouping: entries.values, by: { $0.main.lowercased() })
        var lastLetter = ""
        for key in mains.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let group = mains[key]!
            let name = group.first!.main
            let letter = String(name.prefix(1)).uppercased()
            if letter != lastLetter {
                block.append(styled(letter + "\n", "normal", extra: [.wcIndexBlock: 1]) { $0.paragraphSpacingBefore = 8; $0.paragraphSpacing = 2 })
                let r = NSRange(location: block.length - letter.count - 1, length: letter.count)
                if let f = block.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont {
                    block.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask), range: r)
                }
                lastLetter = letter
            }
            if let top = group.first(where: { $0.sub.isEmpty }) {
                block.append(styled("\(name)\t\(pages(top.pages))\n", "normal", extra: [.wcIndexBlock: 1]) { tab($0); $0.paragraphSpacing = 0 })
            } else {
                block.append(styled("\(name)\n", "normal", extra: [.wcIndexBlock: 1]) { $0.paragraphSpacing = 0 })
            }
            for e in group.filter({ !$0.sub.isEmpty }).sorted(by: { $0.sub.localizedCaseInsensitiveCompare($1.sub) == .orderedAscending }) {
                block.append(styled("\(e.sub)\t\(pages(e.pages))\n", "normal", extra: [.wcIndexBlock: 1]) { tab($0); $0.headIndent = 18; $0.firstLineHeadIndent = 18; $0.paragraphSpacing = 0 })
            }
        }
        if entries.isEmpty { block.append(styled("No index entries. Select text and use Mark Entry.\n", "normal", extra: [.wcIndexBlock: 1])) }
        replaceBlock(.wcIndexBlock, with: block, actionName: "Index")
    }

    func removeIndex() {
        guard let tv = bodyTextView, let st = tv.textStorage, let r = blockRange(.wcIndexBlock), tv.shouldChangeText(in: r, replacementString: "") else { return }
        st.deleteCharacters(in: r)
        tv.didChangeText()
    }
}

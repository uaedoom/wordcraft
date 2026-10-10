import AppKit
import SwiftUI

struct HeadingItem: Identifiable, Equatable {
    var id: Int { loc }
    let loc: Int
    let level: Int
    let title: String
}

struct NoteEntry: Identifiable {
    let id: String
    let isEndnote: Bool
    let label: String
}

private func shortID() -> String { String(UUID().uuidString.prefix(8)) }

// MARK: - Styles

extension EditorController {
    var styles: [StyleDef] { meta.styles }
    func style(_ id: String) -> StyleDef? { meta.style(id) }

    func sanitizeTypingAttributes(_ tv: NSTextView) {
        guard tv.selectedRange().length == 0 else { return }
        var a = tv.typingAttributes
        var dirty = false
        for k in [NSAttributedString.Key.wcFootnote, .wcEndnote, .wcTOC, .wcEndnotes, .wcSection, .wcFormula, .link, .wcImage, .wcEquation, .wcObject, .wcRevision, .wcComment, .wcMerge, .wcMergeValue, .wcCite, .wcBib, .wcBookmark, .wcXref, .wcCaption, .wcIndex, .wcIndexBlock, .wcControl, .attachment] where a[k] != nil {
            a.removeValue(forKey: k)
            dirty = true
        }
        if dirty { tv.typingAttributes = a }
    }

    /// Applies a paragraph style to every paragraph touched by the selection.
    func applyStyle(_ id: String) {
        guard let tv = textView, let st = tv.textStorage, let def = style(id) else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let full = ns.paragraphRange(for: sel)
        tv.undoManager?.beginUndoGrouping()
        if full.length > 0, tv.shouldChangeText(in: full, replacementString: nil) {
            st.beginEditing()
            var loc = full.location
            while loc < NSMaxRange(full) {
                let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let existing = st.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
                st.addAttributes(def.attributes(preserving: existing), range: pr)
                loc = NSMaxRange(pr)
                if pr.length == 0 { break }
            }
            st.endEditing()
            tv.didChangeText()
        }
        if sel.length == 0 {
            var typing = tv.typingAttributes
            let existing = typing[.paragraphStyle] as? NSParagraphStyle
            typing.merge(def.attributes(preserving: existing)) { $1 }
            tv.typingAttributes = typing
        }
        tv.undoManager?.setActionName("Apply Style")
        tv.undoManager?.endUndoGrouping()
        tv.window?.makeFirstResponder(tv)
        refresh()
        scheduleOutline()
    }

    /// After Return at the end of a heading, the new paragraph takes the style's "next" style.
    func applyNextStyleAfterReturn() {
        guard let tv = textView, let st = tv.textStorage else { return }
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        guard caret > 0, caret <= ns.length else { return }
        let prev = ns.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        guard prev.length > 0,
              let id = st.attribute(.wcStyle, at: prev.location, effectiveRange: nil) as? String,
              let def = style(id), def.next != id, style(def.next) != nil else { return }
        let cur = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        guard cur.length <= 1 else { return }
        applyStyle(def.next)
    }

    func editStyle(_ id: String) {
        guard let def = style(id) else { return }
        isNewStyle = false
        editingStyle = def
    }

    func newStyleFromSelection() {
        let f = format
        var d = StyleDef(id: "custom-" + shortID(), name: "Style \(meta.styles.filter { !$0.builtin }.count + 1)")
        d.family = f.fontFamily; d.size = f.fontSize; d.bold = f.bold; d.italic = f.italic; d.underline = f.underline
        d.nsColor = f.textColor
        d.alignment = f.alignment.rawValue
        d.spaceBefore = f.spaceBefore; d.spaceAfter = f.spaceAfter; d.lineMultiple = f.lineSpacing
        d.leftIndent = f.leftIndent; d.rightIndent = f.rightIndent; d.firstLine = f.firstLine
        d.next = "normal"; d.builtin = false
        isNewStyle = true
        editingStyle = d
    }

    func commitStyle(_ def: StyleDef) {
        guard let um = textView?.undoManager else { return }
        um.beginUndoGrouping()
        updateMeta("Modify Style") { m in
            if let i = m.styles.firstIndex(where: { $0.id == def.id }) { m.styles[i] = def } else { m.styles.append(def) }
        }
        restyleAll(def)
        um.setActionName("Modify Style")
        um.endUndoGrouping()
        editingStyle = nil
    }

    func updateStyleToMatchSelection() {
        guard var d = style(format.styleID) else { return }
        let f = format
        d.family = f.fontFamily; d.size = f.fontSize; d.bold = f.bold; d.italic = f.italic; d.underline = f.underline
        d.nsColor = f.textColor
        d.alignment = f.alignment.rawValue
        d.spaceBefore = f.spaceBefore; d.spaceAfter = f.spaceAfter; d.lineMultiple = f.lineSpacing
        d.leftIndent = f.leftIndent; d.rightIndent = f.rightIndent; d.firstLine = f.firstLine
        commitStyle(d)
    }

    func deleteStyle(_ id: String) {
        guard let def = style(id), !def.builtin, let um = textView?.undoManager else { return }
        um.beginUndoGrouping()
        retag(from: id, to: "normal")
        updateMeta("Delete Style") { $0.styles.removeAll { $0.id == id } }
        um.setActionName("Delete Style")
        um.endUndoGrouping()
    }

    /// Re-applies a style definition to every paragraph that uses it.
    private func restyleAll(_ def: StyleDef) {
        guard let tv = textView, let st = tv.textStorage else { return }
        let ns = st.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0, tv.shouldChangeText(in: full, replacementString: nil) else { return }
        st.beginEditing()
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if (st.attribute(.wcStyle, at: pr.location, effectiveRange: nil) as? String) == def.id {
                let existing = st.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
                st.addAttributes(def.attributes(preserving: existing), range: pr)
            }
            loc = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
        st.endEditing()
        tv.didChangeText()
        refresh()
        scheduleOutline()
    }

    private func retag(from old: String, to new: String) {
        guard let nd = style(new) else { return }
        guard let tv = textView, let st = tv.textStorage else { return }
        let ns = st.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0, tv.shouldChangeText(in: full, replacementString: nil) else { return }
        st.beginEditing()
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if (st.attribute(.wcStyle, at: pr.location, effectiveRange: nil) as? String) == old {
                let existing = st.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
                st.addAttributes(nd.attributes(preserving: existing), range: pr)
            }
            loc = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
        st.endEditing()
        tv.didChangeText()
    }
}

// MARK: - Outline / navigation

extension EditorController {
    func scheduleOutline() {
        outlineWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshOutline() }
        outlineWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func refreshOutline() {
        let items = headings().map { HeadingItem(loc: $0.loc, level: $0.level, title: $0.title) }
        if items != outline { outline = items }
    }

    func headings() -> [(loc: Int, level: Int, title: String)] {
        guard let st = engine?.storage else { return [] }
        let ns = st.string as NSString
        var out: [(Int, Int, String)] = []
        var loc = 0
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{000C}\u{2003}"))
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if let id = st.attribute(.wcStyle, at: pr.location, effectiveRange: nil) as? String,
               let def = style(id), def.outline > 0 {
                let t = ns.substring(with: pr).trimmingCharacters(in: junk)
                if !t.isEmpty { out.append((pr.location, def.outline, t)) }
            }
            loc = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
        return out.map { (loc: $0.0, level: $0.1, title: $0.2) }
    }

    func go(to loc: Int) { engine?.reveal(loc: loc) }
}

// MARK: - Table of contents

extension EditorController {
    func blockRange(_ key: NSAttributedString.Key) -> NSRange? {
        guard let st = engine?.storage else { return nil }
        var found: NSRange?
        st.enumerateAttribute(key, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            if v != nil { found = found.map { NSUnionRange($0, r) } ?? r }
        }
        return found
    }

    func tocRange() -> NSRange? { blockRange(.wcTOC) }
    var hasTOC: Bool { tocRange() != nil }

    private func buildTOC(width: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func line(_ text: String, _ def: StyleDef, tab: Bool) {
            var attrs = def.attributes(preserving: nil)
            attrs[.wcTOC] = 1
            if tab, let ps = attrs[.paragraphStyle] as? NSMutableParagraphStyle {
                ps.tabStops = [NSTextTab(textAlignment: .right, location: width)]
                ps.defaultTabInterval = 0
            }
            out.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        let heading = style("tocHeading") ?? StyleDef.make("tocHeading", "TOC Heading", size: 16, bold: true)
        line("Table of Contents", heading, tab: false)
        let items = headings().filter { $0.level <= 3 }
        if items.isEmpty {
            line("No headings found. Apply Heading 1–3 styles to your titles, then update.", style("normal") ?? heading, tab: false)
        }
        for h in items {
            let def = style("toc\(h.level)") ?? style("toc1") ?? heading
            let page = "\(engine?.pageNumber(forCharacter: h.loc) ?? 1)"
            let font = def.font()
            let textW = (h.title as NSString).size(withAttributes: [.font: font]).width
            let pageW = (page as NSString).size(withAttributes: [.font: font]).width
            let dotW = (". " as NSString).size(withAttributes: [.font: font]).width
            let avail = width - def.leftIndent - textW - pageW - 12
            let dots = avail > dotW * 2 ? String(repeating: ". ", count: Int(avail / dotW)) : ""
            line("\(h.title) \(dots)\t\(page)", def, tab: true)
        }
        return out
    }

    /// Inserts a table of contents at the caret, or refreshes the existing one.
    func insertTableOfContents() {
        guard let tv = textView, let st = tv.textStorage, let engine else { return }
        var target: NSRange
        if let existing = tocRange() {
            target = existing
        } else {
            let ns = tv.string as NSString
            let loc = ns.paragraphRange(for: NSRange(location: tv.selectedRange().location, length: 0)).location
            target = NSRange(location: loc, length: 0)
        }
        let width = layout.columnWidth
        tv.undoManager?.beginUndoGrouping()
        var last = ""
        for _ in 0..<3 {
            engine.settle()
            let block = buildTOC(width: width)
            if block.string == last { break }
            last = block.string
            if tv.shouldChangeText(in: target, replacementString: block.string) {
                st.replaceCharacters(in: target, with: block)
                tv.didChangeText()
            }
            target = NSRange(location: target.location, length: block.length)
        }
        tv.undoManager?.setActionName("Table of Contents")
        tv.undoManager?.endUndoGrouping()
        scheduleOutline()
    }

    func removeTableOfContents() {
        guard let tv = textView, let st = tv.textStorage, let r = tocRange() else { return }
        if tv.shouldChangeText(in: r, replacementString: "") {
            st.deleteCharacters(in: r)
            tv.didChangeText()
        }
    }

    /// Brings generated content (TOC, endnotes) up to date before printing or exporting.
    func refreshFields() {
        updateAllFields()
    }
}

// MARK: - Footnotes and endnotes

extension EditorController {
    /// Footnotes then endnotes, in document order, one entry per note id.
    func noteEntries() -> [NoteEntry] {
        guard let marks = engine?.noteMarks() else { return [] }
        var seen = Set<String>()
        var out: [NoteEntry] = []
        for (i, m) in marks.foot.enumerated() where seen.insert(m.id).inserted {
            out.append(NoteEntry(id: m.id, isEndnote: false, label: "Footnote \(i + 1)"))
        }
        for (i, m) in marks.end.enumerated() where seen.insert(m.id).inserted {
            out.append(NoteEntry(id: m.id, isEndnote: true, label: "Endnote \(romanNumeral(i + 1))"))
        }
        return out
    }

    func insertNote(endnote: Bool) {
        guard let tv = textView else { return }
        let id = shortID()
        var attrs = tv.typingAttributes
        attrs[endnote ? .wcEndnote : .wcFootnote] = id
        tv.undoManager?.beginUndoGrouping()
        updateMeta("Insert Note") { $0.notes[id] = "" }
        tv.insertText(NSAttributedString(string: "\u{2003}", attributes: attrs), replacementRange: tv.selectedRange())
        sanitizeTypingAttributes(tv)
        tv.undoManager?.setActionName("Insert Note")
        tv.undoManager?.endUndoGrouping()
        showNotes = true
    }

    func setNotes(_ new: [String: String]) {
        updateMeta("Edit Notes") { $0.notes = new }
        if blockRange(.wcEndnotes) != nil || !(engine?.noteMarks().end.isEmpty ?? true) { updateEndnotesBlock() }
    }

    func deleteNote(_ id: String) {
        guard let tv = textView, let st = tv.textStorage else { return }
        tv.undoManager?.beginUndoGrouping()
        for key in [NSAttributedString.Key.wcFootnote, .wcEndnote] {
            var ranges: [NSRange] = []
            st.enumerateAttribute(key, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
                if (v as? String) == id { ranges.append(r) }
            }
            for r in ranges.reversed() where tv.shouldChangeText(in: r, replacementString: "") {
                st.deleteCharacters(in: r)
                tv.didChangeText()
            }
        }
        updateMeta("Delete Note") { $0.notes.removeValue(forKey: id) }
        tv.undoManager?.endUndoGrouping()
        updateEndnotesBlock()
    }

    func updateEndnotesBlock() {
        guard let tv = textView, let st = tv.textStorage, let engine else { return }
        let marks = engine.noteMarks().end
        let existing = blockRange(.wcEndnotes)
        let block = NSMutableAttributedString()
        if !marks.isEmpty {
            func line(_ text: String, _ def: StyleDef) {
                var a = def.attributes(preserving: nil)
                a[.wcEndnotes] = 1
                block.append(NSAttributedString(string: text + "\n", attributes: a))
            }
            line("Endnotes", style("endnotesHeading") ?? StyleDef.make("endnotesHeading", "Endnotes", size: 14, bold: true))
            let body = style("endnote") ?? StyleDef.make("endnote", "Endnote Text", size: 10)
            for (i, m) in marks.enumerated() { line("\(romanNumeral(i + 1)). \(meta.notes[m.id] ?? "")", body) }
        }
        var target = existing ?? NSRange(location: st.length, length: 0)
        if block.length == 0 && existing == nil { return }
        if existing == nil, st.length > 0, !st.string.hasSuffix("\n") {
            block.insert(NSAttributedString(string: "\n"), at: 0)
        }
        if block.length == 0 || block.string != (existing.map { (st.string as NSString).substring(with: $0) } ?? "") {
            tv.undoManager?.beginUndoGrouping()
            if tv.shouldChangeText(in: target, replacementString: block.string) {
                st.replaceCharacters(in: target, with: block)
                tv.didChangeText()
            }
            tv.undoManager?.setActionName("Update Endnotes")
            tv.undoManager?.endUndoGrouping()
        }
        target = NSRange(location: target.location, length: block.length)
    }
}

// MARK: - Sections

extension EditorController {
    /// Starts a new section (on a new page) at the caret. The new section begins with the current page setup.
    func insertSectionBreak() {
        guard let tv = bodyTextView, !format.inTable else { NSSound.beep(); return }
        let id = shortID()
        let current = layout
        var attrs = tv.typingAttributes
        attrs[.wcSection] = id
        tv.undoManager?.beginUndoGrouping()
        updateMeta("Section Break") { $0.sectionLayouts[id] = current }
        tv.insertText(NSAttributedString(string: "\u{000C}", attributes: attrs), replacementRange: tv.selectedRange())
        sanitizeTypingAttributes(tv)
        tv.undoManager?.setActionName("Section Break")
        tv.undoManager?.endUndoGrouping()
    }
}

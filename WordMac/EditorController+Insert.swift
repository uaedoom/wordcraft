import AppKit
import SwiftUI

struct LinkDraft: Identifiable {
    let id = UUID()
    var text: String
    var address: String
    var hasSelection: Bool
}

struct SymbolGroup: Identifiable {
    let name: String
    let items: [String]
    var id: String { name }

    static let all: [SymbolGroup] = [
        SymbolGroup(name: "Common", items: ["©", "®", "™", "°", "§", "¶", "†", "‡", "•", "…", "–", "—", "«", "»", "“", "”", "‘", "’"]),
        SymbolGroup(name: "Math", items: ["±", "×", "÷", "≠", "≈", "≤", "≥", "∞", "√", "∑", "∏", "∫", "∂", "∆", "∇", "∈", "∉", "∩", "∪", "⊂", "⊃", "∀", "∃", "¬", "∧", "∨", "½", "¼", "¾", "²", "³", "‰"]),
        SymbolGroup(name: "Currency", items: ["$", "€", "£", "¥", "¢", "₹", "₩", "₽", "₺", "₿", "₪", "﷼"]),
        SymbolGroup(name: "Arrows", items: ["←", "→", "↑", "↓", "↔", "↕", "⇐", "⇒", "⇑", "⇓", "⇔", "↩", "↪", "➔", "➜"]),
        SymbolGroup(name: "Greek", items: ["α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "λ", "μ", "π", "ρ", "σ", "τ", "φ", "ψ", "ω", "Γ", "Δ", "Θ", "Λ", "Π", "Σ", "Φ", "Ψ", "Ω"]),
        SymbolGroup(name: "Shapes", items: ["■", "□", "▲", "△", "▼", "▽", "◆", "◇", "○", "●", "★", "☆", "✓", "✔", "✗", "✘", "♠", "♥", "♦", "♣", "☀", "☎", "✉", "✂"]),
    ]
}

// MARK: - Links and symbols

extension EditorController {
    func startLink() {
        guard let tv = textView, let st = tv.textStorage else { return }
        let sel = tv.selectedRange()
        var text = sel.length > 0 ? (tv.string as NSString).substring(with: sel) : ""
        var address = ""
        let probe = sel.length > 0 ? sel.location : max(0, sel.location - 1)
        if probe < st.length, let l = st.attribute(.link, at: probe, effectiveRange: nil) {
            address = (l as? URL)?.absoluteString ?? (l as? String) ?? ""
            if sel.length == 0, let r = linkRun(at: probe) { text = (tv.string as NSString).substring(with: r) }
        }
        linkDraft = LinkDraft(text: text, address: address, hasSelection: sel.length > 0)
    }

    private func linkRun(at loc: Int) -> NSRange? {
        guard let st = textView?.textStorage, loc >= 0, loc < st.length else { return nil }
        var r = NSRange()
        guard st.attribute(.link, at: loc, longestEffectiveRange: &r, in: NSRange(location: 0, length: st.length)) != nil else { return nil }
        return r
    }

    static let linkColor = NSColor(calibratedRed: 0.05, green: 0.3, blue: 0.8, alpha: 1)

    static func normalizedURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("://") || t.hasPrefix("mailto:") || t.hasPrefix("tel:") { return URL(string: t) }
        if t.contains("@") && !t.contains("/") { return URL(string: "mailto:" + t) }
        return URL(string: "https://" + t)
    }

    func applyLink(_ draft: LinkDraft) {
        guard let tv = textView, let st = tv.textStorage, let url = Self.normalizedURL(draft.address) else { return }
        let sel = tv.selectedRange()
        var target = sel
        if sel.length == 0, let r = linkRun(at: max(0, sel.location - 1)) { target = r }
        let text = draft.text.isEmpty ? draft.address : draft.text
        tv.undoManager?.beginUndoGrouping()
        if target.length > 0, (tv.string as NSString).substring(with: target) == text {
            if tv.shouldChangeText(in: target, replacementString: nil) {
                st.addAttributes([.link: url, .foregroundColor: Self.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: target)
                tv.didChangeText()
            }
        } else {
            var attrs = target.length > 0 ? st.attributes(at: target.location, effectiveRange: nil) : tv.typingAttributes
            attrs[.link] = url
            attrs[.foregroundColor] = Self.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            tv.insertText(NSAttributedString(string: text, attributes: attrs), replacementRange: target)
        }
        tv.undoManager?.setActionName("Hyperlink")
        tv.undoManager?.endUndoGrouping()
        sanitizeTypingAttributes(tv)
        linkDraft = nil
        refresh()
    }

    func removeLink() {
        guard let tv = textView, let st = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let probe = sel.length > 0 ? sel.location : max(0, sel.location - 1)
        let target = sel.length > 0 ? sel : (linkRun(at: probe) ?? sel)
        guard target.length > 0, tv.shouldChangeText(in: target, replacementString: nil) else { return }
        st.removeAttribute(.link, range: target)
        st.addAttribute(.foregroundColor, value: NSColor.black, range: target)
        st.removeAttribute(.underlineStyle, range: target)
        tv.didChangeText()
        refresh()
    }

    func insertSymbol(_ s: String) {
        guard let tv = textView else { return }
        tv.insertText(s, replacementRange: tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
    }

    func showCharacterViewer() { NSApp.orderFrontCharacterPalette(nil) }
}

// MARK: - Tables

extension EditorController {
    struct TableContext {
        var caret: Int
        var selected: [Int]
    }

    private func editTable(_ name: String, _ op: (inout TableGrid, TableContext) -> (row: Int, col: Int)?) {
        guard let tv = textView, let st = tv.textStorage else { return }
        let sel = tv.selectedRange()
        guard var grid = TableGrid.find(in: st, at: sel.location), let ci = grid.cellIndex(containing: sel.location) else { return }
        var selected: [Int] = []
        for v in tv.selectedRanges {
            let r = v.rangeValue
            for (i, c) in grid.cells.enumerated() where NSIntersectionRange(r, c.range).length > 0 { selected.append(i) }
        }
        if selected.isEmpty { selected = [ci] }
        let oldRange = grid.range
        guard let target = op(&grid, TableContext(caret: ci, selected: Array(Set(selected)))) else { NSSound.beep(); return }
        let rendered = grid.render()
        tv.undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: oldRange, replacementString: rendered.text.string) {
            st.replaceCharacters(in: oldRange, with: rendered.text)
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: oldRange.location + (rendered.starts["\(target.row),\(target.col)"] ?? 0), length: 0))
        tv.undoManager?.setActionName(name)
        tv.undoManager?.endUndoGrouping()
        tv.window?.makeFirstResponder(tv)
        refresh()
    }

    func insertTable(rows: Int, cols: Int) {
        guard let tv = textView, let st = tv.textStorage else { return }
        var attrs: [NSAttributedString.Key: Any] = [.font: (tv.typingAttributes[.font] as? NSFont) ?? Self.defaultFont,
                                                    .foregroundColor: NSColor.black, .wcStyle: "normal"]
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.0
        attrs[.paragraphStyle] = ps
        var grid = TableGrid()
        grid.rows = rows; grid.cols = cols
        for r in 0..<rows { for c in 0..<cols { grid.cells.append(TableCell(row: r, col: c, content: NSAttributedString(string: "\n", attributes: attrs))) } }
        let rendered = grid.render()
        let ns = tv.string as NSString
        var loc = tv.selectedRange().location
        let pr = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        let block = NSMutableAttributedString()
        if loc != pr.location { block.append(NSAttributedString(string: "\n", attributes: tv.typingAttributes)) }
        let startInBlock = block.length
        block.append(rendered.text)
        if loc >= ns.length || NSMaxRange(pr) == ns.length || pr.length == 0 || true {
            // keep a normal paragraph after the table so the caret can leave it
            block.append(NSAttributedString(string: "\n", attributes: [.font: attrs[.font]!, .wcStyle: "normal"]))
        }
        tv.undoManager?.beginUndoGrouping()
        let sel = tv.selectedRange()
        if tv.shouldChangeText(in: sel, replacementString: block.string) {
            st.replaceCharacters(in: sel, with: block)
            tv.didChangeText()
        }
        loc = sel.location + startInBlock
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.undoManager?.setActionName("Insert Table")
        tv.undoManager?.endUndoGrouping()
        tv.window?.makeFirstResponder(tv)
        refresh()
    }

    func tableInsertRow(below: Bool) {
        editTable("Insert Row") { g, ctx in
            let c = g.cells[ctx.caret]
            let idx = below ? c.row + c.rowSpan : c.row
            g.insertRow(at: idx, template: c.row)
            return (idx, c.col)
        }
    }

    func tableInsertColumn(right: Bool) {
        editTable("Insert Column") { g, ctx in
            let c = g.cells[ctx.caret]
            let idx = right ? c.col + c.colSpan : c.col
            g.insertColumn(at: idx, template: c.col)
            return (c.row, idx)
        }
    }

    func tableDeleteRow() {
        editTable("Delete Row") { g, ctx in
            let c = g.cells[ctx.caret]
            guard g.rows > 1 else { return nil }
            g.deleteRow(c.row)
            return (min(c.row, g.rows - 1), min(c.col, g.cols - 1))
        }
    }

    func tableDeleteColumn() {
        editTable("Delete Column") { g, ctx in
            let c = g.cells[ctx.caret]
            guard g.cols > 1 else { return nil }
            g.deleteColumn(c.col)
            return (min(c.row, g.rows - 1), min(c.col, g.cols - 1))
        }
    }

    func tableDelete() {
        guard let tv = textView, let st = tv.textStorage, let g = TableGrid.find(in: st, at: tv.selectedRange().location) else { return }
        if tv.shouldChangeText(in: g.range, replacementString: "") {
            st.deleteCharacters(in: g.range)
            tv.didChangeText()
        }
        refresh()
    }

    func tableMerge() {
        editTable("Merge Cells") { g, ctx in
            let sel = ctx.selected.map { g.cells[$0] }
            guard sel.count > 1 else { return nil }
            let r0 = sel.map { $0.row }.min()!, r1 = sel.map { $0.row + $0.rowSpan - 1 }.max()!
            let c0 = sel.map { $0.col }.min()!, c1 = sel.map { $0.col + $0.colSpan - 1 }.max()!
            return g.merge(rows: r0, r1: r1, cols: c0, c1: c1) ? (r0, c0) : nil
        }
    }

    func tableSplit() {
        editTable("Split Cell") { g, ctx in
            let c = g.cells[ctx.caret]
            guard c.rowSpan > 1 || c.colSpan > 1 else { return nil }
            g.split(at: ctx.caret)
            return (c.row, c.col)
        }
    }

    func tableBorders(_ preset: TableGrid.BorderPreset) {
        editTable("Table Borders") { g, ctx in
            let w = g.cells.flatMap { $0.borders }.first { $0 > 0 } ?? 0.5
            g.applyBorders(preset, width: w, color: g.cells.first?.borderColor ?? .gray)
            let c = g.cells[ctx.caret]
            return (c.row, c.col)
        }
    }

    func tableBorderStyle(width: CGFloat, color: NSColor) {
        editTable("Border Style") { g, ctx in
            for i in g.cells.indices {
                for e in 0..<4 where g.cells[i].borders[e] > 0 { g.cells[i].borders[e] = width }
                g.cells[i].borderColor = color
            }
            let c = g.cells[ctx.caret]
            return (c.row, c.col)
        }
    }

    func tableShade(_ color: NSColor?) {
        editTable("Shading") { g, ctx in
            for i in ctx.selected { g.cells[i].shading = color }
            let c = g.cells[ctx.caret]
            return (c.row, c.col)
        }
    }

    func tableToggleHeader() {
        editTable("Header Row") { g, ctx in
            let top = g.cells.indices.filter { g.cells[$0].row == 0 }
            let on = !top.allSatisfy { g.cells[$0].shading != nil }
            for i in top {
                g.cells[i].shading = on ? NSColor(white: 0.85, alpha: 1) : nil
                let m = NSMutableAttributedString(attributedString: g.cells[i].content)
                m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { v, r, _ in
                    guard let f = v as? NSFont else { return }
                    m.addAttribute(.font, value: on ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
                                                    : NSFontManager.shared.convert(f, toNotHaveTrait: .boldFontMask), range: r)
                }
                g.cells[i].content = m
            }
            let c = g.cells[ctx.caret]
            return (c.row, c.col)
        }
    }

    /// Puts a formula result into the current cell and remembers the formula so the table can be recalculated.
    func tableFormula(_ formula: String) {
        editTable("Formula") { g, ctx in
            let c = g.cells[ctx.caret]
            var attrs = c.content.length > 0 ? c.content.attributes(at: 0, effectiveRange: nil) : [:]
            attrs[.wcFormula] = formula
            var text = "!Error"
            if let v = FormulaEvaluator.evaluate(formula, grid: g, row: c.row, col: c.col), v.isFinite {
                text = FormulaEvaluator.format(v)
            }
            g.cells[ctx.caret].content = NSAttributedString(string: text + "\n", attributes: attrs)
            return (c.row, c.col)
        }
    }

    /// Recomputes every formula cell in every table.
    func recalculateTables() {
        guard let tv = textView, let st = tv.textStorage else { return }
        tv.undoManager?.beginUndoGrouping()
        for var g in TableGrid.allTables(in: st).reversed() {
            var changed = false
            for _ in 0..<3 {
                for i in g.cells.indices.sorted(by: { (g.cells[$0].row, g.cells[$0].col) < (g.cells[$1].row, g.cells[$1].col) }) {
                    let c = g.cells[i]
                    guard c.content.length > 0, let f = c.content.attribute(.wcFormula, at: 0, effectiveRange: nil) as? String else { continue }
                    var text = "!Error"
                    if let v = FormulaEvaluator.evaluate(f, grid: g, row: c.row, col: c.col), v.isFinite { text = FormulaEvaluator.format(v) }
                    if text != c.plainText {
                        g.cells[i].content = NSAttributedString(string: text + "\n", attributes: c.content.attributes(at: 0, effectiveRange: nil))
                        changed = true
                    }
                }
            }
            if changed {
                let r = g.render()
                if tv.shouldChangeText(in: g.range, replacementString: r.text.string) {
                    st.replaceCharacters(in: g.range, with: r.text)
                    tv.didChangeText()
                }
            }
        }
        tv.undoManager?.setActionName("Recalculate")
        tv.undoManager?.endUndoGrouping()
    }
}

#if DEBUG
extension EditorController {
    /// Test helper: fills the table under the caret from a 2-D array of strings.
    func debugFillTable(_ values: [[String]]) {
        editTable("Fill") { g, ctx in
            for (r, row) in values.enumerated() {
                for (c, v) in row.enumerated() {
                    guard let i = g.cell(covering: r, c) else { continue }
                    let attrs = g.cells[i].content.length > 0 ? g.cells[i].content.attributes(at: 0, effectiveRange: nil) : [:]
                    g.cells[i].content = NSAttributedString(string: v + "\n", attributes: attrs)
                }
            }
            let c = g.cells[ctx.caret]
            return (c.row, c.col)
        }
    }

    func debugMerge(r0: Int, r1: Int, c0: Int, c1: Int) {
        editTable("Merge") { g, _ in g.merge(rows: r0, r1: r1, cols: c0, c1: c1) ? (r0, c0) : nil }
    }

    func debugCaret(inCell r: Int, _ c: Int) {
        guard let tv = textView, let st = tv.textStorage, let g = TableGrid.find(in: st, at: tv.selectedRange().location),
              let i = g.cell(covering: r, c) else { return }
        tv.setSelectedRange(NSRange(location: g.cells[i].range.location, length: 0))
    }
}
#endif

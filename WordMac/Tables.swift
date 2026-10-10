import AppKit

extension NSAttributedString.Key {
    /// Formula (e.g. "=SUM(ABOVE)") that produced a table cell's text.
    static let wcFormula = NSAttributedString.Key("wc.formula")
}

struct TableCell {
    var row: Int
    var col: Int
    var rowSpan = 1
    var colSpan = 1
    var content: NSAttributedString
    var shading: NSColor?
    /// Border widths indexed by NSRectEdge raw value: left, top, right, bottom.
    var borders: [CGFloat] = [0.5, 0.5, 0.5, 0.5]
    var borderColor: NSColor = NSColor(white: 0.45, alpha: 1)
    /// Location of the cell in the document when it was parsed.
    var range = NSRange(location: 0, length: 0)

    func covers(_ r: Int, _ c: Int) -> Bool {
        r >= row && r < row + rowSpan && c >= col && c < col + colSpan
    }
    var plainText: String { content.string.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// An editable view of a text table. Edits change the grid, then the whole table is re-rendered into the text.
struct TableGrid {
    var rows = 0
    var cols = 0
    var cells: [TableCell] = []
    var range = NSRange(location: 0, length: 0)
    /// Width of each column as a percentage of the table width (equal when empty).
    var columnWidths: [CGFloat] = []

    var colPercents: [CGFloat] {
        columnWidths.count == cols && cols > 0 ? columnWidths : Array(repeating: 100 / CGFloat(max(1, cols)), count: cols)
    }

    // MARK: Parsing

    private static func block(in st: NSTextStorage, at loc: Int) -> NSTextTableBlock? {
        guard loc >= 0, loc < st.length else { return nil }
        return (st.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.last as? NSTextTableBlock
    }

    static func find(in st: NSTextStorage, at location: Int) -> TableGrid? {
        let ns = st.string as NSString
        guard ns.length > 0 else { return nil }
        var loc = min(location, ns.length - 1)
        guard let first = block(in: st, at: ns.paragraphRange(for: NSRange(location: loc, length: 0)).location) else {
            // caret at the very end of a paragraph just after a table's last cell is not inside the table
            return nil
        }
        let table = first.table
        var start = ns.paragraphRange(for: NSRange(location: loc, length: 0)).location
        while start > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
            guard let b = block(in: st, at: prev.location), b.table === table else { break }
            start = prev.location
        }
        loc = start
        var end = loc
        while end < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: end, length: 0))
            guard let b = block(in: st, at: pr.location), b.table === table else { break }
            end = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
        var grid = TableGrid()
        var widths: [Int: CGFloat] = [:]
        grid.range = NSRange(location: start, length: end - start)
        grid.cols = table.numberOfColumns
        var pos = start
        var current: (row: Int, col: Int)?
        var cellStart = start
        var curBlock: NSTextTableBlock?
        func flush(upTo p: Int) {
            guard let b = curBlock else { return }
            let r = NSRange(location: cellStart, length: p - cellStart)
            var content = NSMutableAttributedString(attributedString: st.attributedSubstring(from: r))
            if !content.string.hasSuffix("\n") { content.append(NSAttributedString(string: "\n", attributes: content.length > 0 ? content.attributes(at: content.length - 1, effectiveRange: nil) : [:])) }
            var cell = TableCell(row: b.startingRow, col: b.startingColumn, content: content)
            cell.rowSpan = b.rowSpan
            cell.colSpan = b.columnSpan
            cell.shading = b.backgroundColor
            cell.borders = (0..<4).map { b.width(for: .border, edge: NSRectEdge(rawValue: UInt($0))!) }
            cell.borderColor = b.borderColor(for: .minX) ?? cell.borderColor
            cell.range = r
            if cell.colSpan == 1, b.contentWidthValueType == .percentageValueType, b.contentWidth > 0 { widths[cell.col] = b.contentWidth }
            grid.cells.append(cell)
            content = NSMutableAttributedString()
        }
        while pos < end {
            let pr = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            let b = block(in: st, at: pr.location)!
            let key = (b.startingRow, b.startingColumn)
            if current == nil || current! != key {
                flush(upTo: pos)
                current = key
                curBlock = b
                cellStart = pos
            }
            pos = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
        flush(upTo: end)
        grid.rows = grid.cells.map { $0.row + $0.rowSpan }.max() ?? 0
        grid.cols = max(grid.cols, grid.cells.map { $0.col + $0.colSpan }.max() ?? 0)
        if widths.count == grid.cols { grid.columnWidths = (0..<grid.cols).map { widths[$0]! } }
        return grid
    }

    /// Start locations of every table in the document (one per table).
    static func allTables(in st: NSTextStorage) -> [TableGrid] {
        var out: [TableGrid] = []
        let ns = st.string as NSString
        var loc = 0
        while loc < ns.length {
            if block(in: st, at: loc) != nil, let g = find(in: st, at: loc) {
                out.append(g)
                loc = max(NSMaxRange(g.range), loc + 1)
            } else {
                let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                loc = max(NSMaxRange(pr), loc + 1)
            }
        }
        return out
    }

    // MARK: Lookup

    func cell(covering r: Int, _ c: Int) -> Int? { cells.firstIndex { $0.covers(r, c) } }

    func cellIndex(containing location: Int) -> Int? {
        cells.firstIndex { location >= $0.range.location && location < NSMaxRange($0.range) }
            ?? cells.firstIndex { location == NSMaxRange($0.range) }
    }

    // MARK: Rendering

    func render() -> (text: NSAttributedString, starts: [String: Int]) {
        let table = NSTextTable()
        table.numberOfColumns = max(1, cols)
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.setContentWidth(99.5, type: .percentageValueType)
        let out = NSMutableAttributedString()
        var starts: [String: Int] = [:]
        for cell in cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) {
            let b = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: cell.rowSpan,
                                     startingColumn: cell.col, columnSpan: cell.colSpan)
            for e in 0..<4 {
                b.setWidth(cell.borders[e], type: .absoluteValueType, for: .border, edge: NSRectEdge(rawValue: UInt(e))!)
            }
            b.setBorderColor(cell.borderColor)
            b.setWidth(4, type: .absoluteValueType, for: .padding)
            let pcts = colPercents
            let span = (cell.col..<min(cols, cell.col + cell.colSpan)).reduce(CGFloat(0)) { $0 + pcts[$1] }
            b.setContentWidth(span, type: .percentageValueType)
            if let sh = cell.shading { b.backgroundColor = sh }
            let content = NSMutableAttributedString(attributedString: cell.content)
            if !content.string.hasSuffix("\n") { content.append(NSAttributedString(string: "\n")) }
            // swap in the new block on every paragraph of the cell
            var loc = 0
            let ns = content.string as NSString
            while loc < ns.length {
                let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let old = content.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
                let ps = (old?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                ps.textBlocks = [b]
                content.addAttribute(.paragraphStyle, value: ps, range: pr)
                loc = NSMaxRange(pr)
                if pr.length == 0 { break }
            }
            starts["\(cell.row),\(cell.col)"] = out.length
            out.append(content)
        }
        return (out, starts)
    }

    // MARK: Structure edits

    private func blank(like cell: TableCell?, row: Int, col: Int) -> TableCell {
        var attrs: [NSAttributedString.Key: Any] = [:]
        if let c = cell, c.content.length > 0 { attrs = c.content.attributes(at: 0, effectiveRange: nil) }
        attrs.removeValue(forKey: .wcFormula)
        var t = TableCell(row: row, col: col, content: NSAttributedString(string: "\n", attributes: attrs))
        if let c = cell { t.borders = c.borders; t.borderColor = c.borderColor }
        return t
    }

    mutating func insertRow(at index: Int, template row: Int) {
        let source = cells.filter { $0.row == row }
        for i in cells.indices {
            if cells[i].row >= index { cells[i].row += 1 }
            else if cells[i].row + cells[i].rowSpan > index { cells[i].rowSpan += 1 }
        }
        rows += 1
        for c in 0..<cols where cell(covering: index, c) == nil {
            cells.append(blank(like: source.first { $0.col == c } ?? source.first, row: index, col: c))
        }
    }

    mutating func insertColumn(at index: Int, template col: Int) {
        let source = cells.filter { $0.col == col }
        for i in cells.indices {
            if cells[i].col >= index { cells[i].col += 1 }
            else if cells[i].col + cells[i].colSpan > index { cells[i].colSpan += 1 }
        }
        cols += 1
        columnWidths = []
        for r in 0..<rows where cell(covering: r, index) == nil {
            cells.append(blank(like: source.first { $0.row == r } ?? source.first, row: r, col: index))
        }
    }

    mutating func deleteRow(_ r: Int) {
        guard rows > 1 else { return }
        var out: [TableCell] = []
        for var c in cells {
            if c.row == r {
                if c.rowSpan > 1 { c.rowSpan -= 1; out.append(c) }
                continue
            }
            if c.row > r { c.row -= 1 } else if c.row + c.rowSpan > r { c.rowSpan -= 1 }
            out.append(c)
        }
        cells = out
        rows -= 1
    }

    mutating func deleteColumn(_ col: Int) {
        guard cols > 1 else { return }
        var out: [TableCell] = []
        for var c in cells {
            if c.col == col {
                if c.colSpan > 1 { c.colSpan -= 1; out.append(c) }
                continue
            }
            if c.col > col { c.col -= 1 } else if c.col + c.colSpan > col { c.colSpan -= 1 }
            out.append(c)
        }
        cells = out
        cols -= 1
        columnWidths = []
    }

    /// Merges the rectangle of cells; returns false if the selection is not a clean rectangle.
    mutating func merge(rows r0: Int, r1: Int, cols c0: Int, c1: Int) -> Bool {
        let inside = cells.indices.filter {
            cells[$0].row >= r0 && cells[$0].row + cells[$0].rowSpan <= r1 + 1 &&
            cells[$0].col >= c0 && cells[$0].col + cells[$0].colSpan <= c1 + 1
        }
        let area = inside.reduce(0) { $0 + cells[$1].rowSpan * cells[$1].colSpan }
        guard inside.count > 1, area == (r1 - r0 + 1) * (c1 - c0 + 1) else { return false }
        let sorted = inside.sorted { (cells[$0].row, cells[$0].col) < (cells[$1].row, cells[$1].col) }
        var merged = NSMutableAttributedString()
        for i in sorted {
            let c = cells[i]
            if c.plainText.isEmpty { continue }
            if merged.length > 0 { merged.append(NSAttributedString(string: "\n")) }
            let t = NSMutableAttributedString(attributedString: c.content)
            if t.string.hasSuffix("\n") { t.deleteCharacters(in: NSRange(location: t.length - 1, length: 1)) }
            merged.append(t)
        }
        var keep = cells[sorted[0]]
        if merged.length == 0 { merged = NSMutableAttributedString(attributedString: keep.content) }
        else { merged.append(NSAttributedString(string: "\n", attributes: merged.attributes(at: merged.length - 1, effectiveRange: nil))) }
        keep.content = merged
        keep.row = r0; keep.col = c0
        keep.rowSpan = r1 - r0 + 1; keep.colSpan = c1 - c0 + 1
        let remove = Set(sorted)
        cells = cells.indices.filter { !remove.contains($0) }.map { cells[$0] } + [keep]
        return true
    }

    mutating func split(at index: Int) {
        let c = cells[index]
        guard c.rowSpan > 1 || c.colSpan > 1 else { return }
        cells[index].rowSpan = 1
        cells[index].colSpan = 1
        for r in c.row..<(c.row + c.rowSpan) {
            for col in c.col..<(c.col + c.colSpan) where !(r == c.row && col == c.col) {
                cells.append(blank(like: c, row: r, col: col))
            }
        }
    }

    // MARK: Borders and shading

    enum BorderPreset { case all, none, outside, inside }

    mutating func applyBorders(_ preset: BorderPreset, width: CGFloat, color: NSColor) {
        for i in cells.indices {
            let c = cells[i]
            let outer = [c.col == 0, c.row == 0, c.col + c.colSpan == cols, c.row + c.rowSpan == rows]
            for e in 0..<4 {
                switch preset {
                case .all: cells[i].borders[e] = width
                case .none: cells[i].borders[e] = 0
                case .outside: cells[i].borders[e] = outer[e] ? width : 0
                case .inside: cells[i].borders[e] = outer[e] ? 0 : width
                }
            }
            cells[i].borderColor = color
        }
    }
}

// MARK: - Formulas

/// Evaluates table formulas such as =SUM(ABOVE), =A1*B1, =AVERAGE(B2:B6).
struct FormulaEvaluator {
    let grid: TableGrid
    let row: Int
    let col: Int
    private var chars: [Character] = []
    private var pos = 0

    init(grid: TableGrid, row: Int, col: Int) {
        self.grid = grid; self.row = row; self.col = col
    }

    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "%", with: "")
        return t.isEmpty ? nil : Double(t)
    }

    func value(_ r: Int, _ c: Int) -> Double? {
        guard r >= 0, c >= 0, let i = grid.cell(covering: r, c) else { return nil }
        return Self.number(grid.cells[i].plainText)
    }

    static func format(_ d: Double) -> String {
        if abs(d - d.rounded()) < 1e-9 { return String(Int(d.rounded())) }
        var s = String(format: "%.4f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func evaluate(_ formula: String, grid: TableGrid, row: Int, col: Int) -> Double? {
        var e = FormulaEvaluator(grid: grid, row: row, col: col)
        var f = formula.trimmingCharacters(in: .whitespaces)
        if f.hasPrefix("=") { f.removeFirst() }
        e.chars = Array(f.uppercased().filter { $0 != " " })
        guard let v = e.parseExpr(), e.pos == e.chars.count else { return nil }
        return v
    }

    private mutating func parseExpr() -> Double? {
        guard var v = parseTerm() else { return nil }
        while pos < chars.count, chars[pos] == "+" || chars[pos] == "-" {
            let op = chars[pos]; pos += 1
            guard let r = parseTerm() else { return nil }
            v = op == "+" ? v + r : v - r
        }
        return v
    }

    private mutating func parseTerm() -> Double? {
        guard var v = parseFactor() else { return nil }
        while pos < chars.count, chars[pos] == "*" || chars[pos] == "/" {
            let op = chars[pos]; pos += 1
            guard let r = parseFactor() else { return nil }
            v = op == "*" ? v * r : (r == 0 ? .nan : v / r)
        }
        return v
    }

    private mutating func parseFactor() -> Double? {
        guard pos < chars.count else { return nil }
        let c = chars[pos]
        if c == "-" { pos += 1; return parseFactor().map { -$0 } }
        if c == "(" {
            pos += 1
            let v = parseExpr()
            if pos < chars.count, chars[pos] == ")" { pos += 1 }
            return v
        }
        if c.isNumber || c == "." {
            var s = ""
            while pos < chars.count, chars[pos].isNumber || chars[pos] == "." { s.append(chars[pos]); pos += 1 }
            return Double(s)
        }
        if c.isLetter {
            var name = ""
            while pos < chars.count, chars[pos].isLetter { name.append(chars[pos]); pos += 1 }
            if pos < chars.count, chars[pos] == "(" {          // function call
                pos += 1
                var values: [Double] = []
                while pos < chars.count, chars[pos] != ")" {
                    guard let list = parseArgument() else { return nil }
                    values += list
                    if pos < chars.count, chars[pos] == "," { pos += 1 }
                }
                if pos < chars.count { pos += 1 }
                return apply(name, values)
            }
            // cell reference like B3
            var digits = ""
            while pos < chars.count, chars[pos].isNumber { digits.append(chars[pos]); pos += 1 }
            guard let r = Int(digits), let cidx = Self.columnIndex(name) else { return nil }
            return value(r - 1, cidx) ?? 0
        }
        return nil
    }

    /// An argument is a keyword (ABOVE...), a range (A1:B3), or a plain expression.
    private mutating func parseArgument() -> [Double]? {
        let save = pos
        var word = ""
        while pos < chars.count, chars[pos].isLetter { word.append(chars[pos]); pos += 1 }
        switch word {
        case "ABOVE":
            return (0..<row).reversed().compactMap { value($0, col) }
        case "BELOW":
            return ((row + 1)..<max(row + 1, grid.rows)).compactMap { value($0, col) }
        case "LEFT":
            return (0..<col).reversed().compactMap { value(row, $0) }
        case "RIGHT":
            return ((col + 1)..<max(col + 1, grid.cols)).compactMap { value(row, $0) }
        default: break
        }
        if !word.isEmpty, let c0 = Self.columnIndex(word) {
            var d = ""
            while pos < chars.count, chars[pos].isNumber { d.append(chars[pos]); pos += 1 }
            if let r0 = Int(d), pos < chars.count, chars[pos] == ":" {
                pos += 1
                var w2 = ""
                while pos < chars.count, chars[pos].isLetter { w2.append(chars[pos]); pos += 1 }
                var d2 = ""
                while pos < chars.count, chars[pos].isNumber { d2.append(chars[pos]); pos += 1 }
                guard let c1 = Self.columnIndex(w2), let r1 = Int(d2) else { return nil }
                var out: [Double] = []
                for r in min(r0, r1)...max(r0, r1) { for c in min(c0, c1)...max(c0, c1) { if let v = value(r - 1, c) { out.append(v) } } }
                return out
            }
        }
        pos = save
        return parseExpr().map { [$0] }
    }

    private func apply(_ name: String, _ v: [Double]) -> Double? {
        switch name {
        case "SUM": return v.reduce(0, +)
        case "AVERAGE", "AVG": return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        case "MIN": return v.min()
        case "MAX": return v.max()
        case "COUNT": return Double(v.count)
        case "PRODUCT": return v.reduce(1, *)
        default: return nil
        }
    }

    static func columnIndex(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        var n = 0
        for ch in s.uppercased() { n = n * 26 + Int(ch.asciiValue! - 64) }
        return n - 1
    }
}

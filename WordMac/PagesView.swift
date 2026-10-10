import AppKit

struct PageInfo {
    var settings: LayoutSettings
    var section: Int
    var fnHeight: CGFloat = 0
    var notes: [NSAttributedString] = []
    var views: [NSTextView] = []

    var containerHeight: CGFloat { max(36, settings.containerSize.height - fnHeight) }
}

/// Document view of the scroll view: draws the pages (header, footer, footnotes) and hosts one text view per column per page.
final class PagesView: NSView {
    static let gap: CGFloat = 20

    var pages: [PageInfo] = [] { didSet { resizeToFit(); needsDisplay = true } }
    private var ys: [CGFloat] = []
    private var contentHeight: CGFloat = 0

    let overlay = ObjectOverlay()
    var placed: [PlacedObject] = [] { didSet { overlay.placed = placed; needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlay.pagesView = self
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Document pages" }
    var pageCount: Int { pages.count }
    var textViews: [NSTextView] { pages.flatMap { $0.views } }

    private func recompute() {
        var y = Self.gap
        ys = pages.map { p in
            let v = y
            y += p.settings.effectiveSize.height + Self.gap
            return v
        }
        contentHeight = y
    }

    func pageRect(_ i: Int) -> NSRect {
        let size = pages[i].settings.effectiveSize
        let x = max(Self.gap, (bounds.width - size.width) / 2)
        return NSRect(x: x, y: ys[i], width: size.width, height: size.height)
    }

    func resizeToFit() { setFrameSize(frame.size) }

    override func setFrameSize(_ newSize: NSSize) {
        recompute()
        let widest = pages.map { $0.settings.effectiveSize.width }.max() ?? 612
        super.setFrameSize(NSSize(width: max(newSize.width, widest + 2 * Self.gap), height: contentHeight))
        overlay.frame = bounds
        positionTextViews()
        needsDisplay = true
    }

    func positionTextViews() {
        guard ys.count == pages.count else { return }
        for (i, p) in pages.enumerated() {
            let r = pageRect(i)
            let s = p.settings
            let w = s.columnWidth
            for (j, tv) in p.views.enumerated() {
                let frame = NSRect(x: r.minX + s.left + CGFloat(j) * (w + s.columnSpacing),
                                   y: r.minY + s.top, width: w, height: p.containerHeight)
                if tv.frame != frame { tv.frame = frame }
                tv.minSize = frame.size
                tv.maxSize = frame.size
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let screen = NSGraphicsContext.currentContextDrawingToScreen()
        for i in 0..<pages.count {
            let r = pageRect(i)
            guard r.insetBy(dx: -12, dy: -12).intersects(dirtyRect) else { continue }
            if screen {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = 6
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.set()
                NSColor.white.setFill()
                r.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            for p in placed where p.page == i && p.obj.wrap == .behind {
                ObjectDrawing.draw(p.obj, in: NSRect(x: r.minX + p.obj.x, y: r.minY + p.obj.y, width: p.obj.w, height: p.obj.h), assets: overlay.assets)
            }
            drawHeaderFooter(page: i + 1, info: pages[i], rect: r)
            drawFootnotes(info: pages[i], rect: r)
        }
    }

    private func drawHeaderFooter(page: Int, info: PageInfo, rect r: NSRect) {
        let settings = info.settings
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica Neue", size: 10) ?? .systemFont(ofSize: 10),
            .foregroundColor: NSColor(white: 0.25, alpha: 1)]
        func expand(_ s: String) -> String {
            s.replacingOccurrences(of: "{page}", with: "\(page)")
             .replacingOccurrences(of: "{pages}", with: "\(pages.count)")
        }
        func draw(_ hf: HeaderFooter, y: CGFloat) {
            let x0 = r.minX + settings.left, x1 = r.maxX - settings.right
            let w = x1 - x0
            if !hf.left.isEmpty {
                (expand(hf.left) as NSString).draw(in: NSRect(x: x0, y: y, width: w, height: 14), withAttributes: attrs)
            }
            if !hf.center.isEmpty {
                let s = expand(hf.center) as NSString
                s.draw(at: NSPoint(x: x0 + (w - s.size(withAttributes: attrs).width) / 2, y: y), withAttributes: attrs)
            }
            if !hf.right.isEmpty {
                let s = expand(hf.right) as NSString
                s.draw(at: NSPoint(x: x1 - s.size(withAttributes: attrs).width, y: y), withAttributes: attrs)
            }
        }
        draw(settings.header, y: r.minY + settings.headerDistance)
        draw(settings.footer, y: r.maxY - settings.footerDistance - 12)
    }

    static func noteHeight(_ n: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(n.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
    }

    private func drawFootnotes(info: PageInfo, rect r: NSRect) {
        guard !info.notes.isEmpty else { return }
        let s = info.settings
        let width = s.effectiveSize.width - s.left - s.right
        let x0 = r.minX + s.left
        let top = r.maxY - s.bottom - info.fnHeight
        NSColor(white: 0.3, alpha: 1).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x0, y: top + 3))
        line.line(to: NSPoint(x: x0 + min(144, width / 3), y: top + 3))
        line.lineWidth = 0.5
        line.stroke()
        var y = top + 8
        for n in info.notes {
            let h = Self.noteHeight(n, width: width)
            n.draw(in: NSRect(x: x0, y: y, width: width, height: h))
            y += h
        }
    }

    // MARK: Printing (one printed page per page rect)

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        pageRect(min(max(0, page - 1), pages.count - 1))
    }
}

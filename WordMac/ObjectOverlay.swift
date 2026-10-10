import AppKit

/// Transparent layer above the text views that draws floating objects and handles selecting, moving and resizing them.
final class ObjectOverlay: NSView, NSTextViewDelegate {
    weak var pagesView: PagesView?
    var assets: AssetStore?
    var placed: [PlacedObject] = [] { didSet { syncTextBoxes(); needsDisplay = true } }
    var selectedID: String? { didSet { needsDisplay = true } }
    private var boxViews: [String: NSTextView] = [:]

    var onSelect: ((String?) -> Void)?
    var onBegin: (() -> Void)?
    var onLive: ((String, (inout FloatingObject) -> Void) -> Void)?
    var onCommit: (() -> Void)?
    var onDelete: ((String) -> Void)?
    var onText: ((String, Data) -> Void)?
    var onTextEvent: (() -> Void)?

    private enum Drag { case none, move, resize(Int) }
    private var drag = Drag.none
    private var dragStart = NSPoint.zero
    private var startObj: FloatingObject?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { selectedID != nil }

    func frame(of p: PlacedObject) -> NSRect {
        guard let pv = pagesView, p.page < pv.pages.count else { return .zero }
        let r = pv.pageRect(p.page)
        return NSRect(x: r.minX + p.obj.x, y: r.minY + p.obj.y, width: p.obj.w, height: p.obj.h)
    }

    private var ordered: [PlacedObject] { placed.sorted { $0.obj.z < $1.obj.z } }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let screen = NSGraphicsContext.currentContextDrawingToScreen()
        for p in ordered where p.obj.wrap != .behind {
            let f = frame(of: p)
            guard f.insetBy(dx: -12, dy: -12).intersects(dirtyRect) else { continue }
            ObjectDrawing.draw(p.obj, in: f, assets: assets)
        }
        guard screen, let id = selectedID, let p = placed.first(where: { $0.obj.id == id }) else { return }
        let f = frame(of: p)
        NSColor.controlAccentColor.setStroke()
        let b = NSBezierPath(rect: f)
        b.lineWidth = 1
        b.setLineDash([4, 3], count: 2, phase: 0)
        b.stroke()
        for h in handleRects(f) {
            NSColor.white.setFill(); NSBezierPath(rect: h).fill()
            NSColor.controlAccentColor.setStroke(); let hb = NSBezierPath(rect: h); hb.lineWidth = 1; hb.stroke()
        }
    }

    private func handleRects(_ f: NSRect) -> [NSRect] {
        let s: CGFloat = 8
        let xs = [f.minX, f.midX, f.maxX], ys = [f.minY, f.midY, f.maxY]
        // tl, t, tr, r, br, b, bl, l
        let pts = [(xs[0], ys[0]), (xs[1], ys[0]), (xs[2], ys[0]), (xs[2], ys[1]), (xs[2], ys[2]), (xs[1], ys[2]), (xs[0], ys[2]), (xs[0], ys[1])]
        return pts.map { NSRect(x: $0.0 - s / 2, y: $0.1 - s / 2, width: s, height: s) }
    }

    // MARK: Hit testing

    private func hitRect(_ p: PlacedObject) -> NSRect {
        var f = frame(of: p).insetBy(dx: -4, dy: -4)
        if f.height < 14 { f = f.insetBy(dx: 0, dy: (f.height - 14) / 2) }
        return f
    }

    private func object(at pt: NSPoint) -> PlacedObject? {
        ordered.reversed().first { hitRect($0).contains(pt) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let pt = convert(point, from: superview)
        if let id = selectedID, let p = placed.first(where: { $0.obj.id == id }),
           handleRects(frame(of: p)).contains(where: { $0.insetBy(dx: -3, dy: -3).contains(pt) }) { return self }
        guard let hit = object(at: pt) else { return nil }
        if hit.obj.kind == .textbox, hit.obj.id == selectedID, let tv = boxViews[hit.obj.id], tv.frame.contains(pt) {
            return tv        // inside a selected text box: edit its text
        }
        return self
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if let id = selectedID, let p = placed.first(where: { $0.obj.id == id }),
           let h = handleRects(frame(of: p)).firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(pt) }) {
            drag = .resize(h); startObj = p.obj; dragStart = pt; onBegin?()
            return
        }
        if let hit = object(at: pt) {
            if selectedID != hit.obj.id { selectedID = hit.obj.id; onSelect?(hit.obj.id) }
            drag = .move; startObj = hit.obj; dragStart = pt; onBegin?()
        } else {
            selectedID = nil
            onSelect?(nil)
            drag = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startObj, let pv = pagesView, let id = selectedID,
              let placedObj = placed.first(where: { $0.obj.id == id }), placedObj.page < pv.pages.count else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - dragStart.x, dy = pt.y - dragStart.y
        let pageSize = pv.pages[placedObj.page].settings.effectiveSize
        switch drag {
        case .move:
            onLive?(id) { o in
                o.x = min(max(0, start.x + dx), max(0, pageSize.width - start.w))
                o.y = min(max(0, start.y + dy), max(0, pageSize.height - start.h))
            }
        case .resize(let h):
            var x = start.x, y = start.y, w = start.w, hgt = start.h
            if [0, 6, 7].contains(h) { x = start.x + dx; w = start.w - dx }
            if [2, 3, 4].contains(h) { w = start.w + dx }
            if [0, 1, 2].contains(h) { y = start.y + dy; hgt = start.h - dy }
            if [4, 5, 6].contains(h) { hgt = start.h + dy }
            if start.kind == .image && [0, 2, 4, 6].contains(h) && !event.modifierFlags.contains(.option) {
                let ratio = start.w / max(1, start.h)
                let nh = max(12, w / ratio)
                if [0, 2].contains(h) { y = start.y + start.h - nh }
                hgt = nh
            }
            if w < 12 { if [0, 6, 7].contains(h) { x = start.x + start.w - 12 }; w = 12 }
            if hgt < 12 { if [0, 1, 2].contains(h) { y = start.y + start.h - 12 }; hgt = 12 }
            let (fx, fy, fw, fh) = (x, y, w, hgt)
            onLive?(id) { o in o.x = fx; o.y = fy; o.w = fw; o.h = fh }
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .none = drag { return }
        drag = .none
        startObj = nil
        onCommit?()
    }

    override func keyDown(with event: NSEvent) {
        guard let id = selectedID else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 51, 117: onDelete?(id)
        case 53: selectedID = nil; onSelect?(nil)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? {
        ordered.map { p in
            let o = p.obj
            let role: NSAccessibility.Role = o.kind == .image ? .image : .group
            var label: String
            switch o.kind {
            case .image: label = (o.image?.alt.isEmpty == false ? o.image?.alt : nil) ?? (o.alt.isEmpty ? "Picture" : o.alt)
            case .shape: label = o.alt.isEmpty ? "Shape" : o.alt
            case .textbox: label = "Text box"
            }
            let e = NSAccessibilityElement.element(withRole: role, frame: .zero, label: label, parent: self)
            (e as? NSAccessibilityElement)?.setAccessibilityFrameInParentSpace(frame(of: p))
            return e
        }
    }

    // MARK: Text boxes

    private func syncTextBoxes() {
        let boxes = placed.filter { $0.obj.kind == .textbox }
        let keep = Set(boxes.map { $0.obj.id })
        for (id, tv) in boxViews where !keep.contains(id) { tv.removeFromSuperview(); boxViews[id] = nil }
        for p in boxes {
            let tv = boxViews[p.obj.id] ?? makeBox(p.obj)
            if tv.superview == nil { addSubview(tv) }
            let f = frame(of: p).insetBy(dx: p.obj.strokeWidth + 3, dy: p.obj.strokeWidth + 3)
            if tv.frame != f { tv.frame = f }
        }
    }

    private func makeBox(_ obj: FloatingObject) -> NSTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: max(20, obj.w - 8), height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        let tv = NSTextView(frame: .zero, textContainer: tc)
        tv.drawsBackground = false
        tv.isRichText = true
        tv.allowsUndo = true
        tv.usesFontPanel = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = NSSize(width: 2, height: 2)
        tv.appearance = NSAppearance(named: .aqua)
        tv.delegate = self
        if let d = obj.rtf, let a = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            storage.setAttributedString(a)
        } else {
            tv.typingAttributes = [.font: NSFont(name: "Helvetica Neue", size: 12) ?? .systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        }
        boxViews[obj.id] = tv
        return tv
    }

    func focusTextBox(_ id: String) {
        guard let tv = boxViews[id] else { return }
        window?.makeFirstResponder(tv)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, let id = boxViews.first(where: { $0.value === tv })?.key,
              let st = tv.textStorage,
              let data = try? st.data(from: NSRange(location: 0, length: st.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
        onText?(id, data)
        onTextEvent?()
    }

    func textViewDidChangeSelection(_ notification: Notification) { onTextEvent?() }
}

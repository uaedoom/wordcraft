import AppKit

/// Container that can be switched off so text flows past it (used for the unused columns after a section break).
final class PageContainer: NSTextContainer {
    var skipped = false
    override var isSimpleRectangularTextContainer: Bool { false }
    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        if skipped {
            remainingRect?.pointee = .zero
            return .zero
        }
        return super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                      writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

/// Draws footnote/endnote numbers over the placeholder marker characters.
final class WCLayoutManager: NSLayoutManager {
    var labelFor: ((Int) -> String?)?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let labelFor else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for key in [NSAttributedString.Key.wcFootnote, .wcEndnote] {
            storage.enumerateAttribute(key, in: chars) { v, r, _ in
                guard v != nil else { return }
                for loc in r.location..<NSMaxRange(r) {
                    guard let label = labelFor(loc) else { continue }
                    let g = glyphIndexForCharacter(at: loc)
                    guard let tc = textContainer(forGlyphAt: g, effectiveRange: nil) else { continue }
                    let rect = boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                    let font = storage.attribute(.font, at: loc, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: max(6, font.pointSize * 0.62)),
                        .foregroundColor: NSColor.black]
                    (label as NSString).draw(at: NSPoint(x: origin.x + rect.minX + 1, y: origin.y + rect.minY), withAttributes: attrs)
                }
            }
        }
    }
}

struct SectionInfo {
    var settings: LayoutSettings
    var id: String?
    var breakLoc: Int?
}

struct SectionPlan {
    var settings: LayoutSettings
    var id: String?
    var pages: Int
}

func romanNumeral(_ n: Int) -> String {
    let t: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                              (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
    var n = n, s = ""
    for (v, r) in t { while n >= v { s += r; n -= v } }
    return s
}

/// Owns the shared layout manager and builds containers/views per section, page and column,
/// growing and shrinking the page list as text flows.
final class PageEngine: NSObject, NSLayoutManagerDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    let storage: NSTextStorage
    let layoutManager = WCLayoutManager()
    let pagesView = PagesView()
    private weak var controller: EditorController?
    private weak var document: RichTextDocument?
    private weak var lastActive: NSTextView?
    private var plan: [SectionPlan] = []
    private var adjustScheduled = false
    private var fnPasses = 0
    private var labelsDirty = true
    private var labels: [Int: String] = [:]
    private var pendingNewline = false
    private var pendingAttachmentScan = false
    private var objectPasses = 0
    private var objectPages: [String: Int] = [:]
    private var exclusionCache: [ObjectIdentifier: [NSRect]] = [:]

    init(storage: NSTextStorage, document: RichTextDocument, controller: EditorController) {
        self.storage = storage
        self.document = document
        self.controller = controller
        super.init()
        layoutManager.delegate = self
        layoutManager.backgroundLayoutEnabled = true
        layoutManager.labelFor = { [weak self] loc in self?.label(at: loc) }
        storage.addLayoutManager(layoutManager)
        storage.delegate = self
        pagesView.overlay.assets = document.assets
        rebuild(readSections())
    }

    var meta: DocMeta { document?.meta ?? DocMeta() }

    /// Restrict Editing: read-only and comments-only documents can't be typed into.
    func applyProtection() {
        let editable = [.none, .trackedChanges, .forms].contains(meta.protection.mode)
        for tv in pagesView.textViews { tv.isEditable = editable }
    }

    var activeTextView: NSTextView? {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.layoutManager === layoutManager { return tv }
        if let tv = lastActive, tv.superview != nil { return tv }
        return layoutManager.firstTextView
    }

    func containerIndex(of tv: NSTextView) -> Int? {
        guard let tc = tv.textContainer else { return nil }
        return layoutManager.textContainers.firstIndex(of: tc)
    }

    /// Zero-based page index for a container index.
    func pageIndex(ofContainer idx: Int) -> Int {
        var count = 0
        for (i, p) in pagesView.pages.enumerated() {
            count += p.views.count
            if idx < count { return i }
        }
        return max(0, pagesView.pages.count - 1)
    }

    func pageNumber(forCharacter loc: Int) -> Int {
        guard storage.length > 0 else { return 1 }
        let g = layoutManager.glyphIndexForCharacter(at: min(loc, storage.length - 1))
        guard let tc = layoutManager.textContainer(forGlyphAt: g, effectiveRange: nil),
              let idx = layoutManager.textContainers.firstIndex(of: tc) else { return pagesView.pageCount }
        return pageIndex(ofContainer: idx) + 1
    }

    // MARK: Sections

    func readSections() -> [SectionInfo] {
        let m = meta
        var out: [SectionInfo] = []
        storage.enumerateAttribute(.wcSection, in: NSRange(location: 0, length: storage.length), options: []) { v, r, _ in
            if let id = v as? String { out.append(SectionInfo(settings: m.settings(for: id), id: id, breakLoc: r.upperBound - 1)) }
        }
        out.append(SectionInfo(settings: m.layout, id: nil, breakLoc: nil))
        return out
    }

    func sectionInfo(at loc: Int) -> (index: Int, info: SectionInfo) {
        let secs = readSections()
        let i = secs.firstIndex { ($0.breakLoc ?? Int.max) >= loc } ?? secs.count - 1
        return (i, secs[i])
    }

    // MARK: Building pages

    private func makeTextView(_ tc: NSTextContainer) -> NSTextView {
        let tv = NSTextView(frame: NSRect(origin: .zero, size: tc.size), textContainer: tc)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.autoresizingMask = []
        tv.textContainerInset = .zero
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsUndo = true
        tv.usesFontPanel = true
        tv.usesRuler = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.allowsDocumentBackgroundColorChange = false
        if let c = controller {
            tv.isContinuousSpellCheckingEnabled = c.spellingOn
            tv.isGrammarCheckingEnabled = c.grammarOn
            tv.isAutomaticSpellingCorrectionEnabled = c.autoCorrectOn
        }
        tv.isEditable = [.none, .trackedChanges, .forms].contains(meta.protection.mode)
        tv.delegate = self
        if storage.length == 0, let normal = meta.style("normal") {
            tv.typingAttributes = normal.attributes(preserving: nil)
        }
        return tv
    }

    private func makePage(section k: Int, settings: LayoutSettings, insertingAt containerIndex: Int?) -> PageInfo {
        var views: [NSTextView] = []
        for j in 0..<max(1, settings.columns) {
            let tc = PageContainer(size: NSSize(width: settings.columnWidth, height: settings.containerSize.height))
            tc.lineFragmentPadding = 0
            tc.widthTracksTextView = false
            tc.heightTracksTextView = false
            if let idx = containerIndex { layoutManager.insertTextContainer(tc, at: idx + j) }
            else { layoutManager.addTextContainer(tc) }
            let tv = makeTextView(tc)
            pagesView.addSubview(tv)
            views.append(tv)
        }
        return PageInfo(settings: settings, section: k, views: views)
    }

    private func rebuild(_ secs: [SectionInfo]) {
        let oldPages = plan.map(\.pages)
        let sel = plan.isEmpty ? nil : activeTextView?.selectedRange()
        for i in (0..<layoutManager.textContainers.count).reversed() { layoutManager.removeTextContainer(at: i) }
        pagesView.pages.forEach { $0.views.forEach { $0.removeFromSuperview() } }
        plan = secs.enumerated().map { i, s in
            SectionPlan(settings: s.settings, id: s.id, pages: max(1, i < oldPages.count ? oldPages[i] : 1))
        }
        var pages: [PageInfo] = []
        for (k, p) in plan.enumerated() {
            for _ in 0..<p.pages { pages.append(makePage(section: k, settings: p.settings, insertingAt: nil)) }
        }
        pagesView.pages = pages
        fnPasses = 0
        if let sel, let first = pages.first?.views.first {
            first.window?.makeFirstResponder(first)
            first.setSelectedRange(NSRange(location: min(sel.location, storage.length), length: min(sel.length, max(0, storage.length - sel.location))))
        }
    }

    /// Call after page setup or sections changed. Rebuilds only when page geometry differs.
    func structureChanged() {
        let secs = readSections()
        let same = secs.count == plan.count && zip(secs, plan).allSatisfy { $0.settings.sameGeometry(as: $1.settings) }
        if same {
            var pages = pagesView.pages
            for k in plan.indices { plan[k].settings = secs[k].settings; plan[k].id = secs[k].id }
            for i in pages.indices { pages[i].settings = secs[pages[i].section].settings }
            pagesView.pages = pages
        } else {
            rebuild(secs)
        }
        controller?.refresh()
    }

    private func addPage(section k: Int) {
        let upTo = plan[0...k].reduce(0) { $0 + $1.pages }
        let containerIndex = pagesView.pages[0..<upTo].reduce(0) { $0 + $1.views.count }
        let page = makePage(section: k, settings: plan[k].settings, insertingAt: containerIndex)
        var pages = pagesView.pages
        pages.insert(page, at: upTo)
        pagesView.pages = pages
        plan[k].pages += 1
        fnPasses = 0
    }

    private func removePages(section k: Int, to count: Int) {
        guard count >= 1 else { return }
        var pages = pagesView.pages
        while plan[k].pages > count {
            let pageIdx = plan[0...k].reduce(0) { $0 + $1.pages } - 1
            let page = pages.remove(at: pageIdx)
            let start = pages[0..<pageIdx].reduce(0) { $0 + $1.views.count }
            for j in (0..<page.views.count).reversed() {
                layoutManager.removeTextContainer(at: start + j)
                page.views[j].removeFromSuperview()
            }
            plan[k].pages -= 1
        }
        pagesView.pages = pages
        fnPasses = 0
        if let tv = layoutManager.textViewForBeginningOfSelection { tv.window?.makeFirstResponder(tv) }
    }

    // MARK: Reconciling pages with text

    private func containerRange(ofSection k: Int) -> Range<Int> {
        var start = 0
        for i in 0..<k { start += plan[i].pages * max(1, plan[i].settings.columns) }
        return start..<(start + plan[k].pages * max(1, plan[k].settings.columns))
    }

    private func firstPage(ofSection k: Int) -> Int { plan[0..<k].reduce(0) { $0 + $1.pages } }

    @discardableResult
    private func setSkips(section k: Int, after idx: Int?) -> Bool {
        var changed = false
        for c in containerRange(ofSection: k) {
            guard let pc = layoutManager.textContainers[c] as? PageContainer else { continue }
            let want = idx.map { c > $0 } ?? false
            if pc.skipped != want {
                pc.skipped = want
                layoutManager.textContainerChangedGeometry(pc)
                changed = true
            }
        }
        return changed
    }

    /// One reconciliation step; returns true when something changed (call again until false).
    private func reconcileOnce() -> Bool {
        let lm = layoutManager
        let secs = readSections()
        if secs.count != plan.count || zip(secs, plan).contains(where: { !$0.settings.sameGeometry(as: $1.settings) }) {
            structureChanged()
            return true
        }
        for k in plan.indices {
            let isLast = k == plan.count - 1
            let prevBreak = k == 0 ? -1 : (secs[k - 1].breakLoc ?? -1)
            let lastChar = isLast ? storage.length - 1 : (secs[k].breakLoc ?? -1)
            let range = containerRange(ofSection: k)

            if lastChar <= prevBreak {      // empty section
                if setSkips(section: k, after: nil) { return true }
                if plan[k].pages > 1 { removePages(section: k, to: 1); return true }
                continue
            }
            let g = lm.glyphIndexForCharacter(at: lastChar)
            guard let tc = lm.textContainer(forGlyphAt: g, effectiveRange: nil),
                  let idx = lm.textContainers.firstIndex(of: tc), idx < range.upperBound else {
                if setSkips(section: k, after: nil) { return true }
                addPage(section: k)
                return true
            }
            let needed = pageIndex(ofContainer: idx) - firstPage(ofSection: k) + 1
            if needed < plan[k].pages { removePages(section: k, to: needed); return true }
            if setSkips(section: k, after: isLast ? nil : idx) { return true }
        }
        if footnotePass() { return true }
        return objectPass()
    }

    func settle() {
        var n = 0
        while n < 500 && reconcileOnce() { n += 1 }
        controller?.refresh()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        guard !adjustScheduled else { return }
        adjustScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustScheduled = false
            var n = 0
            while n < 50 && self.reconcileOnce() { n += 1 }
            self.pagesView.needsDisplay = true
            self.controller?.refresh()
        }
    }

    // MARK: Footnotes

    func noteMarks() -> (foot: [(loc: Int, id: String)], end: [(loc: Int, id: String)]) {
        var foot: [(Int, String)] = [], end: [(Int, String)] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.wcFootnote, in: full, options: []) { v, r, _ in
            if let id = v as? String { for l in r.location..<NSMaxRange(r) { foot.append((l, id)) } }
        }
        storage.enumerateAttribute(.wcEndnote, in: full, options: []) { v, r, _ in
            if let id = v as? String { for l in r.location..<NSMaxRange(r) { end.append((l, id)) } }
        }
        return (foot.map { (loc: $0.0, id: $0.1) }, end.map { (loc: $0.0, id: $0.1) })
    }

    private func rebuildLabels() {
        labelsDirty = false
        labels = [:]
        let m = noteMarks()
        for (i, x) in m.foot.enumerated() { labels[x.loc] = "\(i + 1)" }
        for (i, x) in m.end.enumerated() { labels[x.loc] = romanNumeral(i + 1) }
    }

    private func label(at loc: Int) -> String? {
        if labelsDirty { rebuildLabels() }
        return labels[loc]
    }

    private func noteText(number: Int, text: String) -> NSAttributedString {
        let font = NSFont(name: "Helvetica Neue", size: 9) ?? .systemFont(ofSize: 9)
        let out = NSMutableAttributedString(string: "\(number)  ", attributes: [
            .font: font, .foregroundColor: NSColor.black, .baselineOffset: 3])
        out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        return out
    }

    /// Reserves room at the bottom of each page for its footnotes.
    private func footnotePass() -> Bool {
        let marks = noteMarks().foot
        let current = pagesView.pages
        if marks.isEmpty && current.allSatisfy({ $0.fnHeight == 0 && $0.notes.isEmpty }) { return false }
        var pages = current
        var changed = false
        let notes = meta.notes
        for i in pages.indices {
            var lo = Int.max, hi = -1
            for tv in pages[i].views {
                guard let tc = tv.textContainer else { continue }
                let gr = layoutManager.glyphRange(for: tc)
                if gr.length > 0 {
                    let cr = layoutManager.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                    lo = min(lo, cr.location)
                    hi = max(hi, NSMaxRange(cr))
                }
            }
            var list: [NSAttributedString] = []
            if hi >= 0 {
                for (n, m) in marks.enumerated() where m.loc >= lo && m.loc < hi {
                    list.append(noteText(number: n + 1, text: notes[m.id] ?? ""))
                }
            }
            let s = pages[i].settings
            let width = s.effectiveSize.width - s.left - s.right
            let height: CGFloat = list.isEmpty ? 0 : 11 + list.reduce(0) { $0 + PagesView.noteHeight($1, width: width) }
            pages[i].notes = list
            if abs(height - pages[i].fnHeight) > 0.5 && fnPasses < 6 {
                pages[i].fnHeight = height
                for tv in pages[i].views {
                    tv.textContainer?.size = NSSize(width: s.columnWidth, height: pages[i].containerHeight)
                }
                changed = true
            }
        }
        pagesView.pages = pages
        if changed { fnPasses += 1 }
        return changed
    }

    // MARK: Floating objects

    func objectAnchors() -> [String: Int] {
        var out: [String: Int] = [:]
        storage.enumerateAttribute(.wcObject, in: NSRange(location: 0, length: storage.length), options: []) { v, r, _ in
            if let id = v as? String { out[id] = r.location }
        }
        return out
    }

    /// Places objects on the page of their anchor and makes body text flow around them.
    private func objectPass() -> Bool {
        let objs = meta.objects
        let anchors = objectAnchors()
        var placed: [PlacedObject] = []
        for (id, loc) in anchors {
            guard let o = objs[id] else { continue }
            var page = min(max(0, pageNumber(forCharacter: loc) - 1), max(0, pagesView.pages.count - 1))
            if objectPasses >= 3, let frozen = objectPages[id] { page = min(frozen, pagesView.pages.count - 1) }
            objectPages[id] = page
            placed.append(PlacedObject(obj: o, page: page))
        }
        var changed = false
        for (pi, page) in pagesView.pages.enumerated() {
            let s = page.settings
            let wrapRects = placed.filter { $0.page == pi && $0.obj.wrap.wrapsText }
            for (col, tv) in page.views.enumerated() {
                guard let tc = tv.textContainer else { continue }
                let origin = NSPoint(x: s.left + CGFloat(col) * (s.columnWidth + s.columnSpacing), y: s.top)
                let bounds = NSRect(x: 0, y: 0, width: tc.size.width, height: tc.size.height)
                var rects: [NSRect] = []
                for p in wrapRects {
                    var r = NSRect(x: p.obj.x - origin.x, y: p.obj.y - origin.y, width: p.obj.w, height: p.obj.h).insetBy(dx: -8, dy: -6)
                    if p.obj.wrap == .topBottom { r.origin.x = 0; r.size.width = bounds.width }
                    else {      // don't leave slivers of text in narrow gaps beside the object
                        let minGap: CGFloat = 54
                        if r.minX > 0 && r.minX < minGap { r.size.width += r.minX; r.origin.x = 0 }
                        let right = bounds.width - r.maxX
                        if right > 0 && right < minGap { r.size.width += right }
                    }
                    if r.intersects(bounds) { rects.append(r.intersection(bounds.insetBy(dx: -50, dy: -50))) }
                }
                let key = ObjectIdentifier(tc)
                if (exclusionCache[key] ?? []) != rects {
                    exclusionCache[key] = rects
                    tc.exclusionPaths = rects.map { NSBezierPath(rect: $0) }
                    changed = true
                }
            }
        }
        pagesView.placed = placed
        if changed { objectPasses += 1 }
        return changed && objectPasses < 8
    }

    func syncObjectContent() {
        var p = pagesView.placed
        for i in p.indices { if let o = meta.objects[p[i].obj.id] { p[i].obj = o } }
        pagesView.placed = p
    }

    /// Re-lays out text after an object moved, resized or changed wrapping.
    func refreshObjects() {
        objectPasses = 0
        objectPages = [:]
        settle()
        pagesView.needsDisplay = true
    }

    func placement(for tv: NSTextView, size: CGSize) -> (page: Int, x: CGFloat, y: CGFloat) {
        guard let idx = containerIndex(of: tv) else { return (0, 72, 100) }
        let pi = pageIndex(ofContainer: idx)
        let s = pagesView.pages[pi].settings
        var y: CGFloat = s.top + 20
        if storage.length > 0 {
            let g = layoutManager.glyphIndexForCharacter(at: min(tv.selectedRange().location, storage.length - 1))
            let lf = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            y = s.top + lf.minY
        }
        let maxY = s.effectiveSize.height - s.bottom - size.height
        return (pi, max(0, (s.effectiveSize.width - size.width) / 2), min(y, max(s.top, maxY)))
    }

    // MARK: Navigation

    func reveal(loc: Int) {
        guard storage.length > 0 else { return }
        let g = layoutManager.glyphIndexForCharacter(at: min(loc, storage.length - 1))
        guard let tc = layoutManager.textContainer(forGlyphAt: g, effectiveRange: nil), let tv = tc.textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        let inPages = tv.convert(rect, to: pagesView)
        if let clip = pagesView.enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, inPages.minY - 60)))
            pagesView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        labelsDirty = true
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let c = controller, !c.shouldAllowEdit(textView, range: affectedCharRange, replacement: replacementString) { return false }
        pendingNewline = (replacementString == "\n")
        if let r = replacementString, r.contains("\u{FFFC}") { pendingAttachmentScan = true }
        return true
    }

    /// Links open with ⌘-click so they can still be edited with a plain click.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if NSEvent.modifierFlags.contains(.command) {
            if let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(url) }
        }
        return true
    }

    func textView(_ textView: NSTextView, doubleClickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        controller?.editAttachment(at: charIndex)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if let tv = notification.object as? NSTextView {
            lastActive = tv
            if let t = NSApp.currentEvent?.type, t == .leftMouseDown || t == .leftMouseUp { controller?.controlClicked(tv) }
        }
        controller?.deselectObjectIfNeeded()
        controller?.syncSelectedComment()
        controller?.refresh()
        controller?.recount()
    }

    func textDidChange(_ notification: Notification) {
        if let tv = notification.object as? NSTextView { lastActive = tv }
        fnPasses = 0
        objectPasses = 0
        labelsDirty = true
        pagesView.textViews.forEach { $0.needsDisplay = true }
        if readSections().count != plan.count { structureChanged() }
        controller?.noteTextChanged()
        if pendingAttachmentScan {
            pendingAttachmentScan = false
            controller?.normalizeAttachments()
        }
        if pendingNewline {
            pendingNewline = false
            controller?.applyNextStyleAfterReturn()
        }
        controller?.refresh()
        controller?.recount()
    }

    @objc func magnifyEnded(_ n: Notification) {
        if let sv = n.object as? NSScrollView { controller?.zoom = sv.magnification }
    }

    /// Keeps the pages view as wide as the visible area so pages stay centred.
    func track(clipView: NSClipView) {
        clipView.postsFrameChangedNotifications = true
        clipView.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(clipChanged(_:)), name: name, object: clipView)
        }
        clipChanged(Notification(name: NSView.frameDidChangeNotification, object: clipView))
    }

    @objc private func clipChanged(_ n: Notification) {
        guard let clip = n.object as? NSClipView else { return }
        let w = clip.bounds.width
        if abs(pagesView.frame.width - w) > 0.5 && w > 0 {
            pagesView.setFrameSize(NSSize(width: w, height: pagesView.frame.height))
        }
    }
}

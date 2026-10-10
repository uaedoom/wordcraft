import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum ListKind { case bullet, numbered }

struct FormatState: Equatable {
    var fontFamily = "Helvetica Neue"
    var fontSize: CGFloat = 12
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var superscript = false
    var subscriptOn = false
    var alignment: NSTextAlignment = .left
    var list: ListKind? = nil
    var lineSpacing: CGFloat = 1.0
    var textColor: NSColor = .black
    var leftIndent: CGFloat = 0
    var rightIndent: CGFloat = 0
    var firstLine: CGFloat = 0
    var spaceBefore: CGFloat = 0
    var spaceAfter: CGFloat = 0
    var styleID = "normal"
    var inTable = false
    var link: String? = nil
    var rtl = false
}

struct DocStats: Equatable {
    var words = 0
    var characters = 0
    var selectedWords = 0
    var pages = 1
    var currentPage = 1
}

/// Bridges the SwiftUI ribbon and the AppKit text view.
final class EditorController: ObservableObject {
    static var defaultFont: NSFont {
        let d = UserDefaults.standard
        let size = d.double(forKey: "wc.defaultSize")
        let fam = d.string(forKey: "wc.defaultFont") ?? ""
        return NSFontManager.shared.font(withFamily: fam.isEmpty ? "Helvetica Neue" : fam, traits: [], weight: 5, size: size >= 6 ? CGFloat(size) : 12)
            ?? NSFont(name: "Helvetica Neue", size: 12) ?? .systemFont(ofSize: 12)
    }

    var engine: PageEngine?
    weak var scrollView: NSScrollView?
    weak var document: RichTextDocument?

    /// The text view that currently holds the selection (one per page column).
    var textView: NSTextView? {
        if let fr = NSApp.keyWindow?.firstResponder as? NSTextView, let pv = engine?.pagesView, fr.isDescendant(of: pv) { return fr }
        return engine?.activeTextView
    }

    /// The main body text view (never a text box).
    var bodyTextView: NSTextView? { engine?.activeTextView }

    @Published var format = FormatState()
    @Published var stats = DocStats()
    @Published var zoom: CGFloat = 1.0
    @Published var rulerVisible = false {
        didSet { scrollView?.rulersVisible = rulerVisible }
    }

    private var countWork: DispatchWorkItem?
    var outlineWork: DispatchWorkItem?
    var dragStartMeta: DocMeta?

    /// Page setup of the section that holds the caret.
    @Published var layout = LayoutSettings()
    @Published var meta = DocMeta()
    @Published var showHeaderFooter = false
    @Published var editingStyle: StyleDef?
    var isNewStyle = false
    @Published var showNotes = false
    @Published var showNav = false
    @Published var outline: [HeadingItem] = []
    @Published var currentSectionIndex = 0
    @Published var linkDraft: LinkDraft?
    @Published var showFormula = false
    @Published var showTableSize = false
    @Published var revisions: [RevisionItem] = []
    @Published var commentItems: [CommentItem] = []
    @Published var showReview = false
    @Published var showMarkup = true
    @Published var reviewTab = 0
    @Published var editingCommentID: String?
    @Published var selectedCommentID: String?
    @Published var showRestrict = false
    @Published var focusMode = false
    @Published var showSources = false
    @Published var showXref = false
    @Published var showIndexMark = false
    @Published var showControlProps = false
    @Published var showMergeData = false
    @Published var showSaveTemplate = false
    @Published var showBookmark = false
    @Published var controlDraft: ControlProps?
    @Published var mergeIndex = 0
    @Published var mergePreviewing = false
    @Published var showWordCount = false
    @Published var thesaurus: ThesaurusDraft?
    @Published var spellingOn = true
    @Published var grammarOn = false
    @Published var autoCorrectOn = true
    @Published var authorName: String = UserDefaults.standard.string(forKey: "wc.author") ?? NSFullUserName() {
        didSet { UserDefaults.standard.set(authorName, forKey: "wc.author") }
    }
    var defaultsObserver: NSObjectProtocol?
    var applyingTracked = false
    var pendingInsertion: (loc: Int, len: Int)?
    var markupWork: DispatchWorkItem?
    var markupRanges: [NSRange] = []
    @Published var selectedImage: ImageProps?
    @Published var selectedObjectID: String?
    @Published var selectedEquation: EquationProps?
    @Published var equationDraft: EquationDraft?

    func attach(engine: PageEngine, scrollView: NSScrollView, document: RichTextDocument) {
        self.engine = engine
        self.scrollView = scrollView
        self.document = document
        EditorRegistry.register(self)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let a = UserDefaults.standard.string(forKey: "wc.author"), a != self.authorName else { return }
            self.authorName = a
        }
        meta = document.meta
        fixDirections()
        wireOverlay(engine.pagesView.overlay)
        layout = document.meta.layout
        refresh()
        recount()
    }

    // MARK: State

    func refresh() {
        guard let tv = textView, let st = tv.textStorage else { return }
        sanitizeTypingAttributes(tv)
        let sel = tv.selectedRange()
        var attrs = tv.typingAttributes
        if sel.length > 0, sel.location < st.length {
            attrs = st.attributes(at: sel.location, effectiveRange: nil)
        }
        var s = FormatState()
        let font = (attrs[.font] as? NSFont) ?? Self.defaultFont
        s.fontFamily = font.familyName ?? font.fontName
        s.fontSize = font.pointSize
        let traits = NSFontManager.shared.traits(of: font)
        s.bold = traits.contains(.boldFontMask)
        s.italic = traits.contains(.italicFontMask)
        s.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        s.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        let sup = (attrs[.superscript] as? Int) ?? 0
        s.superscript = sup > 0
        s.subscriptOn = sup < 0
        let ps = attrs[.paragraphStyle] as? NSParagraphStyle
        let al = ps?.alignment ?? .natural
        let paraRange = (st.string as NSString).paragraphRange(for: NSRange(location: min(sel.location, max(0, st.length - 1)), length: 0))
        let dir = ps?.baseWritingDirection ?? .natural
        s.rtl = dir == .rightToLeft || (dir == .natural && st.length > 0 && (st.string as NSString).substring(with: paraRange).startsRightToLeft)
        s.alignment = (al == .natural) ? (s.rtl ? .right : .left) : al
        if let list = ps?.textLists.first {
            s.list = ["decimal", "alpha", "roman"].contains { list.markerFormat.rawValue.contains($0) } ? .numbered : .bullet
        }
        let lh = ps?.lineHeightMultiple ?? 0
        s.lineSpacing = lh == 0 ? 1.0 : lh
        s.textColor = (attrs[.foregroundColor] as? NSColor) ?? .black
        s.leftIndent = ps?.headIndent ?? 0
        s.rightIndent = (ps?.tailIndent ?? 0) <= 0 ? -(ps?.tailIndent ?? 0) : 0
        s.firstLine = (ps?.firstLineHeadIndent ?? 0) - (ps?.headIndent ?? 0)
        s.spaceBefore = ps?.paragraphSpacingBefore ?? 0
        s.spaceAfter = ps?.paragraphSpacing ?? 0
        s.styleID = (attrs[.wcStyle] as? String) ?? "normal"
        s.inTable = !(ps?.textBlocks.isEmpty ?? true)
        if let l = attrs[.link] { s.link = (l as? URL)?.absoluteString ?? (l as? String) }
        if s != format { format = s }
        var img: ImageProps?, eq: EquationProps?
        if sel.length == 1, sel.location < st.length {
            img = ImageProps.decode(st.attribute(.wcImage, at: sel.location, effectiveRange: nil))
            eq = EquationProps.decode(st.attribute(.wcEquation, at: sel.location, effectiveRange: nil))
        }
        if img != selectedImage { selectedImage = img }
        if eq != selectedEquation { selectedEquation = eq }
        if let engine, let tv = textView {
            let sec = engine.sectionInfo(at: tv.selectedRange().location)
            if layout != sec.info.settings { layout = sec.info.settings }
            if currentSectionIndex != sec.index { currentSectionIndex = sec.index }
        }
        updatePages()
    }

    func updatePages() {
        guard let engine else { return }
        var current = 1
        if let tv = textView, let i = engine.containerIndex(of: tv) { current = engine.pageIndex(ofContainer: i) + 1 }
        let total = engine.pagesView.pageCount
        if stats.pages != total || stats.currentPage != current {
            stats.pages = total
            stats.currentPage = current
        }
    }

    func recount() {
        countWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let tv = self.textView else { return }
            let str = tv.string
            func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
            var st = self.stats
            st.words = words(str)
            st.characters = str.count
            let sel = tv.selectedRange()
            st.selectedWords = sel.length > 0 ? words((str as NSString).substring(with: sel)) : 0
            if st != self.stats { self.stats = st }
            self.scheduleOutline()
        }
        countWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Editing core

    enum Scope { case selection, paragraphs }

    func range(for scope: Scope) -> NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        let sel = tv.selectedRange()
        switch scope {
        case .selection: return sel
        case .paragraphs: return (tv.string as NSString).paragraphRange(for: sel)
        }
    }

    /// Applies an attribute edit to the chosen range (undoable) and to the typing attributes when nothing is selected.
    func modify(scope: Scope,
                        typing: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any],
                        apply: (NSTextStorage, NSRange) -> Void) {
        guard let tv = textView, let st = tv.textStorage else { return }
        let r = range(for: scope)
        let isCaret = tv.selectedRange().length == 0
        if r.length > 0, tv.shouldChangeText(in: r, replacementString: nil) {
            st.beginEditing()
            apply(st, r)
            st.endEditing()
            tv.didChangeText()
        }
        if isCaret { tv.typingAttributes = typing(tv.typingAttributes) }
        tv.window?.makeFirstResponder(tv)
        refresh()
    }

    func changeFont(scope: Scope = .selection, _ transform: @escaping (NSFont) -> NSFont) {
        modify(scope: scope, typing: { a in
            var a = a
            a[.font] = transform((a[.font] as? NSFont) ?? Self.defaultFont)
            return a
        }, apply: { st, r in
            st.enumerateAttribute(.font, in: r) { v, sub, _ in
                st.addAttribute(.font, value: transform((v as? NSFont) ?? Self.defaultFont), range: sub)
            }
        })
    }

    func setAttribute(_ key: NSAttributedString.Key, _ value: Any?, scope: Scope = .selection) {
        modify(scope: scope, typing: { a in
            var a = a
            if let value { a[key] = value } else { a.removeValue(forKey: key) }
            return a
        }, apply: { st, r in
            if let value { st.addAttribute(key, value: value, range: r) } else { st.removeAttribute(key, range: r) }
        })
    }

    func modifyParagraphs(_ f: (NSMutableParagraphStyle) -> Void) {
        guard let tv = textView, let st = tv.textStorage else { return }
        let r = range(for: .paragraphs)
        func mutable(_ v: Any?) -> NSMutableParagraphStyle {
            (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        }
        var typing = tv.typingAttributes
        let tps = mutable(typing[.paragraphStyle])
        f(tps)
        typing[.paragraphStyle] = tps
        if r.length > 0, tv.shouldChangeText(in: r, replacementString: nil) {
            st.beginEditing()
            st.enumerateAttribute(.paragraphStyle, in: r) { v, sub, _ in
                let ps = mutable(v)
                f(ps)
                st.addAttribute(.paragraphStyle, value: ps, range: sub)
            }
            st.endEditing()
            tv.didChangeText()
        }
        tv.typingAttributes = typing
        tv.window?.makeFirstResponder(tv)
        refresh()
    }

    // MARK: Character formatting

    func toggleBold() {
        let on = !format.bold
        changeFont { on ? NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask)
                        : NSFontManager.shared.convert($0, toNotHaveTrait: .boldFontMask) }
    }

    func toggleItalic() {
        let on = !format.italic
        changeFont { on ? NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask)
                        : NSFontManager.shared.convert($0, toNotHaveTrait: .italicFontMask) }
    }

    func toggleUnderline() {
        setAttribute(.underlineStyle, format.underline ? nil : NSUnderlineStyle.single.rawValue)
    }

    func toggleStrike() {
        setAttribute(.strikethroughStyle, format.strike ? nil : NSUnderlineStyle.single.rawValue)
    }

    func toggleSuperscript() { setAttribute(.superscript, format.superscript ? nil : 1) }
    func toggleSubscript() { setAttribute(.superscript, format.subscriptOn ? nil : -1) }

    func setFamily(_ family: String) {
        changeFont { NSFontManager.shared.convert($0, toFamily: family) }
    }

    func setSize(_ size: CGFloat) {
        changeFont { NSFontManager.shared.convert($0, toSize: size) }
    }

    func stepSize(_ delta: CGFloat) {
        changeFont { f in
            let steps: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72, 96]
            let new: CGFloat
            if delta > 0 { new = steps.first(where: { $0 > f.pointSize }) ?? f.pointSize + 4 }
            else { new = steps.last(where: { $0 < f.pointSize }) ?? max(6, f.pointSize - 1) }
            return NSFontManager.shared.convert(f, toSize: new)
        }
    }

    func setTextColor(_ c: NSColor) { setAttribute(.foregroundColor, c) }
    func setHighlight(_ c: NSColor?) { setAttribute(.backgroundColor, c) }

    func clearFormatting() {
        applyStyle("normal")
        guard let tv = textView, let st = tv.textStorage else { return }
        let sel = tv.selectedRange()
        if sel.length > 0, tv.shouldChangeText(in: sel, replacementString: nil) {
            st.beginEditing()
            for k in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .backgroundColor, .superscript, .baselineOffset] {
                st.removeAttribute(k, range: sel)
            }
            st.endEditing()
            tv.didChangeText()
        }
        refresh()
    }

    // MARK: Paragraph formatting

    /// Sets the paragraph direction; text aligns to the start edge.
    func setDirection(rtl: Bool) {
        modifyParagraphs { $0.baseWritingDirection = rtl ? .rightToLeft : .leftToRight; $0.alignment = .natural }
    }

    func setAlignment(_ a: NSTextAlignment) { modifyParagraphs { $0.alignment = a } }
    func setLineSpacing(_ m: CGFloat) { modifyParagraphs { $0.lineHeightMultiple = m } }

    func indent(_ delta: CGFloat) {
        modifyParagraphs {
            $0.headIndent = max(0, $0.headIndent + delta)
            $0.firstLineHeadIndent = max(0, $0.firstLineHeadIndent + delta)
        }
    }

    func setLeftIndent(_ v: CGFloat) {
        modifyParagraphs {
            let fl = $0.firstLineHeadIndent - $0.headIndent
            $0.headIndent = max(0, v)
            $0.firstLineHeadIndent = max(0, v + fl)
        }
    }
    func setFirstLine(_ v: CGFloat) { modifyParagraphs { $0.firstLineHeadIndent = max(0, $0.headIndent + v) } }
    func setRightIndent(_ v: CGFloat) { modifyParagraphs { $0.tailIndent = -max(0, v) } }
    func setSpaceBefore(_ v: CGFloat) { modifyParagraphs { $0.paragraphSpacingBefore = max(0, v) } }
    func setSpaceAfter(_ v: CGFloat) { modifyParagraphs { $0.paragraphSpacing = max(0, v) } }

    // MARK: Lists

    func toggleList(_ kind: ListKind) {
        guard let tv = textView, let st = tv.textStorage else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        var paras: [NSRange] = []
        var loc = ns.paragraphRange(for: NSRange(location: sel.location, length: 0)).location
        let end = max(NSMaxRange(sel), loc)
        repeat {
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            paras.append(r)
            if r.length == 0 { break }
            loc = NSMaxRange(r)
        } while loc < end

        func style(of r: NSRange) -> NSParagraphStyle? {
            r.length > 0 ? st.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
                         : tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        }
        let removing = paras.allSatisfy { r in
            guard let l = style(of: r)?.textLists.first else { return false }
            return l.markerFormat.rawValue.contains("decimal") == (kind == .numbered)
        }

        tv.undoManager?.beginUndoGrouping()
        for (i, r) in paras.enumerated().reversed() {
            var attrs: [NSAttributedString.Key: Any] = r.length > 0
                ? st.attributes(at: r.location, effectiveRange: nil) : tv.typingAttributes
            let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()

            // Existing "\t<marker>\t" prefix, only when the paragraph is already a list item.
            var oldPrefix = 0
            if !ps.textLists.isEmpty, r.length > 0, ns.character(at: r.location) == 9 {
                let para = ns.substring(with: r) as NSString
                let second = para.range(of: "\t", options: [], range: NSRange(location: 1, length: para.length - 1))
                if second.location != NSNotFound { oldPrefix = second.location + 1 }
            }

            var newPrefix = ""
            if removing {
                ps.textLists = []
                ps.headIndent = 0
                ps.firstLineHeadIndent = 0
                ps.tabStops = []
            } else {
                let fmt: NSTextList.MarkerFormat = kind == .bullet ? .disc : NSTextList.MarkerFormat("{decimal}.")
                let list = NSTextList(markerFormat: fmt, options: 0)
                ps.textLists = [list]
                ps.headIndent = 36
                ps.firstLineHeadIndent = 0
                ps.tabStops = [NSTextTab(textAlignment: .left, location: 18), NSTextTab(textAlignment: .left, location: 36)]
                newPrefix = "\t" + list.marker(forItemNumber: i + 1) + "\t"
            }
            attrs[.paragraphStyle] = ps

            let prefixRange = NSRange(location: r.location, length: oldPrefix)
            if tv.shouldChangeText(in: prefixRange, replacementString: newPrefix) {
                st.beginEditing()
                st.replaceCharacters(in: prefixRange, with: NSAttributedString(string: newPrefix, attributes: attrs))
                let newLen = r.length - oldPrefix + (newPrefix as NSString).length
                st.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: r.location, length: newLen))
                st.endEditing()
                tv.didChangeText()
            }
            if r.length == 0 {
                tv.setSelectedRange(NSRange(location: r.location + (newPrefix as NSString).length, length: 0))
                tv.typingAttributes = attrs
            }
        }
        tv.undoManager?.endUndoGrouping()
        tv.window?.makeFirstResponder(tv)
        refresh()
    }

    // MARK: Clipboard / undo / find

    func cut() { textView?.cut(nil) }
    func copy() { textView?.copy(nil) }
    func paste() { textView?.paste(nil) }
    func undo() { textView?.undoManager?.undo(); refresh() }
    func redo() { textView?.undoManager?.redo(); refresh() }
    func selectAll() { textView?.selectAll(nil) }

    func showFind(replace: Bool) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        let item = NSMenuItem()
        item.tag = (replace ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        tv.performFindPanelAction(item)
    }

    // MARK: Zoom

    func setZoom(_ z: CGFloat) {
        guard let sv = scrollView else { return }
        let clamped = min(max(z, 0.5), 3.0)
        let visible = sv.contentView.bounds
        sv.setMagnification(clamped, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        zoom = clamped
    }

    func fitWidth() {
        guard let sv = scrollView else { return }
        let w = sv.frame.width - 2 * PagesView.gap - 20
        setZoom(w / (engine?.pagesView.pages.first?.settings.effectiveSize.width ?? 612))
    }

    // MARK: Page layout

    /// Single entry point for document-wide settings (page setup, styles, notes); undoable.
    func updateMeta(_ name: String, _ transform: (inout DocMeta) -> Void) {
        var new = meta
        transform(&new)
        guard new != meta else { return }
        setMeta(new, undoTo: meta, name: name)
    }

    func setMeta(_ new: DocMeta, undoTo old: DocMeta, name: String) {
        if let um = textView?.undoManager {
            um.registerUndo(withTarget: self) { $0.setMeta(old, undoTo: new, name: name) }
            um.setActionName(name)
        }
        meta = new
        document?.meta = new
        engine?.structureChanged()
        if old.protection != new.protection { engine?.applyProtection() }
        if old.comments != new.comments { scheduleMarkup() }
        if old.objects != new.objects {
            let geometry = { (m: DocMeta) in m.objects.mapValues { [$0.x, $0.y, $0.w, $0.h, CGFloat($0.wrap.hashValue)] } }
            if old.objects.keys != new.objects.keys || geometry(old) != geometry(new) { engine?.refreshObjects() }
            else { engine?.syncObjectContent() }
        }
        refresh()
        scheduleOutline()
    }

    /// Edits the page setup of the section that holds the caret.
    func updateLayout(_ name: String, _ transform: (inout LayoutSettings) -> Void) {
        let key = currentSectionKey()
        updateMeta(name) { m in
            var l = m.settings(for: key)
            transform(&l)
            m.set(l, for: key)
        }
    }

    func currentSectionKey() -> String? {
        guard let tv = textView, let engine else { return nil }
        return engine.sectionInfo(at: tv.selectedRange().location).info.id
    }

    func setPaper(_ p: PaperSize) {
        updateLayout("Page Size") { $0.pageWidth = p.width; $0.pageHeight = p.height }
    }

    func setMargins(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        updateLayout("Margins") { $0.top = top; $0.bottom = bottom; $0.left = left; $0.right = right }
    }

    func insertPageBreak() {
        guard let tv = textView, let engine else { return }
        let cols = max(1, layout.columns)
        let idx = engine.containerIndex(of: tv) ?? 0
        let n = cols - idx % cols     // fill the remaining columns so the next text starts on a new page
        tv.insertText(String(repeating: "\u{000C}", count: n), replacementRange: tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
    }

    func insertColumnBreak() {
        guard let tv = textView else { return }
        tv.insertText("\u{000C}", replacementRange: tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
    }

    enum PageNumberPlacement { case headerLeft, headerCenter, headerRight, footerLeft, footerCenter, footerRight, none }

    func setPageNumber(_ placement: PageNumberPlacement) {
        updateLayout("Page Number") { l in
            func strip(_ hf: inout HeaderFooter) {
                if hf.left.contains("{page") { hf.left = "" }
                if hf.center.contains("{page") { hf.center = "" }
                if hf.right.contains("{page") { hf.right = "" }
            }
            strip(&l.header); strip(&l.footer)
            switch placement {
            case .headerLeft: l.header.left = "{page}"
            case .headerCenter: l.header.center = "{page}"
            case .headerRight: l.header.right = "{page}"
            case .footerLeft: l.footer.left = "{page}"
            case .footerCenter: l.footer.center = "{page}"
            case .footerRight: l.footer.right = "{page}"
            case .none: break
            }
        }
    }

    // MARK: Printing / PDF

    private func makePrintInfo() -> NSPrintInfo {
        let first = engine?.pagesView.pages.first?.settings ?? layout
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = first.landscape ? .landscape : .portrait
        info.paperSize = first.effectiveSize
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    func printDocument() {
        guard let view = engine?.pagesView, let window = textView?.window else { return }
        refreshFields()
        let op = NSPrintOperation(view: view, printInfo: makePrintInfo())
        if revisions.isEmpty && commentItems.isEmpty { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
        else { withPrintedMarkup { _ = op.run() } }
    }

    /// Renders every page at its own size (sections can differ) and stitches them into one PDF.
    func writePDF(to url: URL, maxPages: Int = .max) {
        guard let view = engine?.pagesView else { return }
        refreshFields()
        let out = PDFDocument()
        withPrintedMarkup {
            for i in 0..<min(view.pageCount, maxPages) {
                let data = view.dataWithPDF(inside: view.pageRect(i))
                if let page = PDFDocument(data: data)?.page(at: 0) { out.insert(page, at: out.pageCount) }
            }
        }
        out.write(to: url)
    }

    func exportPDF() {
        guard let window = textView?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (window.title.isEmpty ? "Untitled" : window.title) + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.writePDF(to: url)
        }
    }
}

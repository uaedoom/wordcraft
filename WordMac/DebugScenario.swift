#if DEBUG
import AppKit

/// Drives the editor without UI so features can be verified from the command line.
/// WORDMAC_SCENARIO=1 → styles, section break + landscape/columns, footnote, TOC, then PDF to the sandbox tmp dir.
func log(_ items: Any...) {
    let line = items.map { "\($0)" }.joined(separator: " ") + "\n"
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "result.txt")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

enum DebugScenario {
    static func run(_ ed: EditorController, name: String) {
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func paragraphStarts() -> [Int] {
            guard let tv = ed.textView else { return [] }
            let ns = tv.string as NSString
            var out: [Int] = [], loc = 0
            while loc < ns.length { out.append(loc); loc = NSMaxRange(ns.paragraphRange(for: NSRange(location: loc, length: 0))) }
            return out
        }
        func select(_ p: Int) {
            let starts = paragraphStarts()
            guard !starts.isEmpty else { return }
            ed.textView?.setSelectedRange(NSRange(location: starts[min(p, starts.count - 1)], length: 0))
        }
        if name == "10" {
            guard (ed.textView?.string.contains("Lorem ipsum dolor") ?? false) else { return }
            func run(_ src: String) -> String {
                var err: NSDictionary?
                let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
                if let err { return "ERR \(err["NSAppleScriptErrorMessage"] ?? err)" }
                return r?.stringValue ?? r.map { "\($0.int32Value)" } ?? "ok"
            }
            after(1.5) {
                log("AS wordcount", run("tell application \"WordCraft\" to count words"))
                log("AS gettext", run("tell application \"WordCraft\" to return text 1 thru 30 of (get document text)"))
                log("AS replace", run("tell application \"WordCraft\" to replace text \"ipsum\" with \"IPSUM\""))
                log("AS style", run("tell application \"WordCraft\" to apply style \"Heading 2\""))
                log("AS tracking", run("tell application \"WordCraft\" to set tracking true"))
                log("AS bad style", run("tell application \"WordCraft\" to apply style \"Nope\""))
                log("AS insert", run("tell application \"WordCraft\" to insert text \"Hello from AppleScript. \""))
                log("TEXT now", String((ed.document?.storage.string ?? "").prefix(60)).replacingOccurrences(of: "\n", with: "⏎"), "revisions", ed.collectRevisions().count)
            }
            after(4) { NSApp.terminate(nil) }
            return
        }
        if name == "9" {
            guard (ed.textView?.string.contains("Lorem ipsum dolor") ?? false) else { return }
            func tv() -> NSTextView { ed.bodyTextView! }
            after(1) {
                ed.saveSource(Source(id: "Smith2020", kind: "book", authors: "Smith, John; Doe, Jane", title: "The Art of Writing", year: "2020", publisher: "Penguin", city: "London"))
                ed.saveSource(Source(id: "Lee2019", kind: "article", authors: "Lee, Min-jun", title: "Typography on screens", year: "2019", container: "Journal of Design", volume: "12", issue: "3", pages: "45-60"))
                select(2); ed.insertCitation(tag: "Smith2020", page: "45")
                select(3); ed.insertCitation(tag: "Lee2019", page: "")
            }
            after(2) { select(6); ed.insertCaption(label: "Figure") }
            after(2.6) { select(12); ed.insertCaption(label: "Figure") }
            after(3.2) {
                if let c = ed.captions().first, let n = ed.ensureBookmark(over: c.range) { select(8); ed.insertCrossRef(name: n, what: "text"); ed.insertCrossRef(name: n, what: "page") }
            }
            after(3.8) { select(4); tv().setSelectedRange(NSRange(location: tv().selectedRange().location + 6, length: 5)); ed.markIndexEntry(main: "ipsum", sub: "", all: true) }
            after(4.4) { select(5); ed.insertControl(kind: "dropdown"); tv().insertText(" ", replacementRange: tv().selectedRange()); ed.insertControl(kind: "checkbox") }
            after(5.0) {
                ed.setCitationStyle(.ieee)
                ed.updateAllFields()
                log("CITE ieee:", ed.document?.storage.string.components(separatedBy: "\n").first { $0.contains("[1]") }?.prefix(60) ?? "-")
                ed.setCitationStyle(.apa)
            }
            after(5.6) {
                let st = ed.document!.storage
                let ns = st.string as NSString
                log("CAPTIONS", ed.captions().map { "\($0.label) \($0.number)" }, "xref", ed.xrefText(ed.bookmarks(includeHidden: true).first?.name ?? "", what: "page"))
                var tail = NSRange(location: ns.length, length: 0)
                tail = ns.paragraphRange(for: NSRange(location: max(0, ns.length - 1), length: 0))
                tv().setSelectedRange(NSRange(location: tail.location, length: 0))
                ed.insertBibliography()
                log("BIB", ed.document!.storage.string.contains("References"), "has APA entry", ed.document!.storage.string.contains("Smith, J., & Doe, J. (2020)"))
            }
            after(6.4) { tv().setSelectedRange(NSRange(location: (ed.document!.storage.string as NSString).length, length: 0)); ed.insertIndex(); log("INDEX", ed.document!.storage.string.contains("Index")) }
            after(7.2) {
                var m = ed.meta
                m.mergeData = MergeData(columns: ["Name", "City"], rows: [["Amina", "Dubai"], ["Omar", "Abu Dhabi"]])
                ed.updateMeta("data") { $0.mergeData = m.mergeData }
                select(0); tv().setSelectedRange(NSRange(location: 0, length: 0))
                ed.insertMergeField("Name"); tv().insertText(" from ", replacementRange: tv().selectedRange()); ed.insertMergeField("City")
                ed.previewMerge(1)
                log("MERGE preview", String(ed.document!.storage.string.prefix(30)).replacingOccurrences(of: "\n", with: "⏎"))
                ed.previewMerge(nil)
                log("MERGE restored", String(ed.document!.storage.string.prefix(30)).replacingOccurrences(of: "\n", with: "⏎"))
                let before = NSDocumentController.shared.documents.count
                ed.finishMerge()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    log("MERGE docs", before, "->", NSDocumentController.shared.documents.count, "payloadConsumed", PendingDocument.payload == nil)
                }
            }
            after(8.6) {
                let before = NSDocumentController.shared.documents.count
                if let t = TemplateLibrary.builtin.first(where: { $0.id == "invoice" }) { TemplateLibrary.create(t) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let docs = NSDocumentController.shared.documents
                    log("TEMPLATE docs", before, "->", docs.count, "payloadConsumed", PendingDocument.payload == nil)
                }
            }
            after(10.2) {
                if let doc = ed.document, let data = ed.docxData() {
                    try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "power.docx"))
                    if let r = DocxReader.read(data) {
                        func count(_ k: NSAttributedString.Key) -> Int { var n = 0; r.attributed.enumerateAttribute(k, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in if v != nil { n += 1 } }; return n }
                        log("POWER ROUNDTRIP xref", count(.wcXref), "merge", count(.wcMerge), "caption", count(.wcCaption), "bookmark", count(.wcBookmark), "control", count(.wcControl), "cite?", count(.wcCite), "chars", r.attributed.length, "orig", doc.storage.length)
                    }
                }
            }
            after(10.8) {
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"), maxPages: 4)
                NSApp.terminate(nil)
            }
            return
        }
        if name == "8" {
            guard (ed.textView?.string.contains("Lorem ipsum dolor") ?? false) else { return }
            func tv() -> NSTextView { ed.bodyTextView! }
            after(1) { ed.authorName = "Alice"; ed.updateMeta("track") { $0.trackChanges = true }; select(1); tv().insertText("INSERTED ", replacementRange: tv().selectedRange()) }
            after(1.8) { select(2); let s = tv().selectedRange().location; tv().insertText("", replacementRange: NSRange(location: s + 6, length: 12)) }
            after(2.6) { select(3); let s = tv().selectedRange().location; tv().insertText("REPLACED", replacementRange: NSRange(location: s + 10, length: 6)) }
            after(3.4) { ed.authorName = "Bob"; select(4); tv().insertText("Bob wrote this. ", replacementRange: tv().selectedRange()) }
            after(4.2) {
                select(5); let s = tv().selectedRange().location
                tv().setSelectedRange(NSRange(location: s + 6, length: 5))
                ed.updateMeta("track") { $0.trackChanges = false }
                ed.addComment()
                if let id = ed.commentItems.first?.id ?? ed.editingCommentID { ed.updateComment(id) { $0.text = "Please check this word." }; ed.replyToComment(id, text: "Done.") }
            }
            after(5.4) {
                ed.refreshReviewLists()
                log("REVIEW revisions", ed.revisions.count, ed.revisions.map { "\($0.info.kind.rawValue):\($0.info.author):\($0.preview.prefix(12))" }, "comments", ed.commentItems.count, "text", ed.commentItems.first?.rec.text ?? "-")
                guard let doc = ed.document else { return }
                let data = DocxWriter(storage: doc.storage, meta: ed.meta, assets: doc.assets).write()
                try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "review.docx"))
                if let r = DocxReader.read(data) {
                    var n = 0, ins = 0, del = 0, cm = 0
                    r.attributed.enumerateAttribute(.wcRevision, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in
                        if let info = RevisionInfo.decode(v) { n += 1; if info.kind == .insert { ins += 1 } else { del += 1 } } }
                    r.attributed.enumerateAttribute(.wcComment, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in if v != nil { cm += 1 } }
                    log("DOCX ROUNDTRIP revisionRuns", n, "ins", ins, "del", del, "commentRuns", cm, "comments", r.meta.comments.count, "trackChanges", r.meta.trackChanges)
                }
            }
            after(6.0) {
                // protection
                let before = ed.document?.storage.length ?? 0
                ed.startProtection(.readOnly, password: "secret")
                select(1)
                tv().insertText("BLOCKED", replacementRange: tv().selectedRange())
                log("PROTECT readOnly lenChanged", (ed.document?.storage.length ?? 0) != before, "wrongPw", ed.stopProtection(password: "nope"), "rightPw", ed.stopProtection(password: "secret"))
            }
            after(6.8) {
                // compare against a modified original
                let original = (ed.document?.storage.string ?? "").replacingOccurrences(of: "Lorem ipsum dolor sit amet", with: "Lorem ipsum dolor SIT amet")
                let n0 = ed.collectRevisions().count
                ed.compare(original: original + "\nAn extra paragraph that was deleted.")
                log("COMPARE added revisions", ed.collectRevisions().count - n0)
            }
            after(8.0) {
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"), maxPages: 2)
                NSApp.terminate(nil)
            }
            return
        }
        if name == "7" {
            // imported Word documents: report and render to PDF
            after(2.5) {
                let m = ed.meta
                log("IMPORT chars", ed.document?.storage.length ?? 0, "pages", ed.stats.pages, "styles", m.styles.count, "objects", m.objects.count,
                    "sections", m.sectionLayouts.count + 1, "notes", m.notes.count, "outline", ed.outline.count, "assets", ed.assets?.data.count ?? 0)
                if let st = ed.document?.storage {
                    let ns = st.string as NSString
                    var loc = 0, n = 0
                    while loc < ns.length && n < 14 {
                        let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                        let a = st.attributes(at: pr.location, effectiveRange: nil)
                        let ps = a[.paragraphStyle] as? NSParagraphStyle
                        let f = a[.font] as? NSFont
                        log("P", pr.location, "len", pr.length, "style", a[.wcStyle] ?? "-", "font", f?.fontName ?? "-", f?.pointSize ?? 0, "before", ps?.paragraphSpacingBefore ?? -1, "after", ps?.paragraphSpacing ?? -1, "head", ps?.headIndent ?? -1, "blocks", ps?.textBlocks.count ?? 0, "text", ns.substring(with: pr).prefix(30).replacingOccurrences(of: "\n", with: "⏎"))
                        loc = NSMaxRange(pr); n += 1
                    }
                }
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"), maxPages: 6)
                NSApp.terminate(nil)
            }
            return
        }
        guard (ed.textView?.string.count ?? 0) > 500 else { return }
        if name == "6" {
            // everything at once, exported to .docx
            after(1) { select(0); ed.applyStyle("h1"); select(3); ed.applyStyle("h2") }
            after(1.6) { select(1); ed.textView?.setSelectedRange(NSRange(location: ed.textView!.selectedRange().location, length: 11)); ed.toggleBold(); ed.setTextColor(.systemRed) }
            after(2.2) { select(5); ed.toggleList(.bullet) }
            after(2.8) { select(6); ed.toggleList(.numbered) }
            after(3.4) { select(8); ed.insertTable(rows: 3, cols: 3) }
            after(4.0) { ed.debugFillTable([["A", "B", "C"], ["1", "2", "3"], ["", "", ""]]); ed.debugCaret(inCell: 2, 1); ed.tableFormula("=SUM(ABOVE)"); ed.debugMerge(r0: 0, r1: 0, c0: 0, c1: 1) }
            after(4.8) { select(12); ed.insertNote(endnote: false); ed.showNotes = false; if let e = ed.noteEntries().first { ed.updateMeta("n") { $0.notes[e.id] = "A footnote for Word." } } }
            after(5.4) { select(14); ed.applyEquation(EquationDraft(source: "x = \\frac{-b \\pm \\sqrt{b^{2}-4ac}}{2a}", size: 13, range: nil)) }
            after(6.0) {
                let ns = (ed.textView?.string ?? "") as NSString
                ed.textView?.setSelectedRange(NSRange(location: ns.length - 30, length: 4))
                ed.applyLink(LinkDraft(text: ns.substring(with: NSRange(location: ns.length - 30, length: 4)), address: "https://example.com", hasSelection: true))
            }
            after(6.6) { select(30); ed.insertSectionBreak() }
            after(7.2) { ed.updateLayout("t") { $0.landscape = true; $0.columns = 2; $0.header.center = "Landscape section"; $0.footer.right = "Page {page} of {pages}" } }
            after(7.8) {
                select(2)
                let img = NSImage(size: NSSize(width: 300, height: 200), flipped: false) { r in
                    NSColor.systemPink.setFill(); r.fill(); NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 40, dy: 30)).fill(); return true }
                let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
                let id = ed.assets!.add(rep.representation(using: .png, properties: [:])!)
                ed.addFloatingImage(ImageProps(asset: id, width: 150, height: 100), wrap: .square)
            }
            after(8.6) { ed.insertShape(.ellipse) }
            after(9.4) { ed.insertTextBox() }
            after(10.2) {
                if let d = ed.docxData() {
                    try? d.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "out.docx"))
                    log("DOCX bytes", d.count)
                }
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"))
                NSApp.terminate(nil)
            }
            return
        }
        if name == "5" {
            after(1) {
                select(2)
                let img = NSImage(size: NSSize(width: 300, height: 200), flipped: false) { r in
                    NSColor.systemPink.setFill(); r.fill()
                    NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 40, dy: 30)).fill()
                    ("FLOAT" as NSString).draw(at: NSPoint(x: 100, y: 80), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.systemPink])
                    return true
                }
                let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
                let id = ed.assets!.add(rep.representation(using: .png, properties: [:])!)
                ed.addFloatingImage(ImageProps(asset: id, width: 180, height: 120), wrap: .square)
            }
            after(2.2) { ed.updateObject("Move") { $0.x = 300; $0.y = 130 } }
            after(3.2) { select(10); ed.insertShape(.ellipse) }
            after(4.0) { ed.updateObject("Move") { $0.x = 60; $0.y = 520; $0.w = 160; $0.h = 110; $0.wrap = .front } }
            after(4.6) { select(12); ed.insertTextBox() }
            after(5.4) {
                ed.updateObject("Move") { $0.x = 280; $0.y = 520; $0.w = 240; $0.h = 100 }
                if let id = ed.selectedObjectID { ed.meta.objects[id]?.rtf = try? NSAttributedString(string: "Text box content", attributes: [.font: NSFont.systemFont(ofSize: 14)]).data(from: NSRange(location: 0, length: 16), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]); ed.document?.meta = ed.meta }
            }
            after(6.4) {
                guard let doc = ed.document, let snap = try? doc.snapshot(contentType: .wordMac), let l = try? RichTextDocument.load(RichTextDocument.wrapper(snap)) else { log("ROUNDTRIP failed"); return }
                log("ROUNDTRIP objects", l.meta.objects.count, "assets", l.assets.count, "kinds", l.meta.objects.values.map { $0.kind.rawValue }.sorted())
            }
            after(8.5) {
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"))
                NSApp.terminate(nil)
            }
            return
        }
        if name == "4" {
            // pictures + equations + save/load round trip
            after(1) {
                select(3)
                let img = NSImage(size: NSSize(width: 400, height: 240), flipped: false) { r in
                    NSColor.systemTeal.setFill(); r.fill()
                    NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 60, dy: 30)).fill()
                    ("PHOTO" as NSString).draw(at: NSPoint(x: 150, y: 100), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.white])
                    return true
                }
                let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
                ed.insertPicture(data: rep.representation(using: .png, properties: [:])!)
            }
            after(1.8) {
                // crop the picture 10% on the left and shrink: select it first
                if let tv = ed.textView, let st = tv.textStorage {
                    var loc = -1
                    st.enumerateAttribute(.wcImage, in: NSRange(location: 0, length: st.length)) { v, r, stop in if v != nil { loc = r.location; stop.pointee = true } }
                    if loc >= 0 { tv.setSelectedRange(NSRange(location: loc, length: 1)); ed.refresh(); ed.setImageCrop(0, 0.25); ed.scaleImage(by: 0.6) }
                }
            }
            after(2.8) {
                select(6)
                ed.textView?.insertText("Energy: ", replacementRange: ed.textView!.selectedRange())
                ed.applyEquation(EquationDraft(source: "E = mc^{2} + \\frac{a+b}{\\sqrt{x^{2}+1}} + \\sum_{i=1}^{n} \\alpha_{i}", size: 14, range: nil))
            }
            after(3.6) {
                select(9)
                ed.applyEquation(EquationDraft(source: "\\int_{0}^{\\infty} e^{-x^{2}}\\,dx = \\frac{\\sqrt{\\pi}}{2} \\quad \\left( \\frac{a}{b} \\right)", size: 16, range: nil))
            }
            after(4.6) {
                // round trip through the package format
                guard let doc = ed.document, let snap = try? doc.snapshot(contentType: .wordMac) else { log("ROUNDTRIP snapshot failed"); return }
                let wrap = RichTextDocument.wrapper(snap)
                if let l = try? RichTextDocument.load(wrap) {
                    let st = NSTextStorage(attributedString: l.attributed)
                    let assets = AssetStore(); assets.data = l.assets
                    AttachmentBuilder.restore(st, assets: assets)
                    var att = 0, imgs = 0, eqs = 0
                    st.enumerateAttribute(.attachment, in: NSRange(location: 0, length: st.length)) { v, _, _ in if v != nil { att += 1 } }
                    st.enumerateAttribute(.wcImage, in: NSRange(location: 0, length: st.length)) { v, _, _ in if v != nil { imgs += 1 } }
                    st.enumerateAttribute(.wcEquation, in: NSRange(location: 0, length: st.length)) { v, _, _ in if v != nil { eqs += 1 } }
                    log("ROUNDTRIP ok attachments", att, "images", imgs, "equations", eqs, "assets", l.assets.count, "chars", st.length, "orig", doc.storage.length)
                } else { log("ROUNDTRIP load failed") }
            }
            after(6.0) {
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"))
                NSApp.terminate(nil)
            }
            return
        }
        if name == "3" {
            after(1) { select(2); ed.insertTable(rows: 5, cols: 3) }
            after(1.8) { ed.debugFillTable([["Item", "Qty", "Price"], ["Pens", "10", "2.5"], ["Books", "4", "12"], ["Total", "", ""], ["", "", ""]]) }
            after(2.6) { ed.debugCaret(inCell: 3, 1); ed.tableFormula("=SUM(ABOVE)") }
            after(3.4) { ed.debugCaret(inCell: 3, 2); ed.tableFormula("=SUM(B2*C2, B3*C3)") }
            after(4.2) { ed.debugCaret(inCell: 0, 0); ed.tableToggleHeader() }
            after(5.0) { ed.debugCaret(inCell: 4, 0); ed.debugMerge(r0: 4, r1: 4, c0: 0, c1: 2); ed.tableShade(NSColor.systemYellow.withAlphaComponent(0.3)) }
            after(5.8) {
                // hyperlink on a word of paragraph 0, and a symbol
                let ns = (ed.textView?.string ?? "") as NSString
                ed.textView?.setSelectedRange(NSRange(location: 20, length: 5))
                ed.applyLink(LinkDraft(text: ns.substring(with: NSRange(location: 20, length: 5)), address: "example.com", hasSelection: true))
                ed.textView?.setSelectedRange(NSRange(location: 0, length: 0))
                ed.insertSymbol("© ≤ π ")
            }
            after(7.0) {
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"))
                log("SCENARIO3 pages", ed.stats.pages)
                NSApp.terminate(nil)
            }
            return
        }
        if name == "2" {
            after(1) { select(0); ed.updateLayout("cols") { $0.columns = 2 } }
            after(2) { select(12); ed.insertSectionBreak() }
            after(2.8) { ed.updateLayout("cols") { $0.columns = 1; $0.footer.center = "S2 page {page}" } }
            after(3.8) { ed.showNav = true; select(0); ed.applyStyle("h1"); select(12); ed.applyStyle("h2") }
            after(9) {
                ed.writePDF(to: URL(fileURLWithPath: NSTemporaryDirectory() + "scenario.pdf"))
                log("SCENARIO2 pages", ed.stats.pages)
                NSApp.terminate(nil)
            }
            return
        }
        after(1) { select(0); ed.applyStyle("h1") }
        after(1.3) { select(8); ed.applyStyle("h2") }
        after(1.6) { select(20); ed.applyStyle("h2") }
        after(2.0) { select(30); ed.insertSectionBreak() }
        after(2.6) {
            // caret is now in section 2
            ed.updateLayout("Test") { $0.landscape = true; $0.columns = 2; $0.header.left = "Section two"; $0.footer.center = "Page {page} of {pages}" }
        }
        after(3.4) {
            select(5)
            ed.insertNote(endnote: false)
            ed.showNotes = false
            if let e = ed.noteEntries().first {
                ed.updateMeta("note") { $0.notes[e.id] = "This is the text of the first footnote, which should appear at the bottom of the page." }
            }
        }
        after(4.2) { select(0); ed.insertTableOfContents() }
        after(6.0) {
            let path = NSTemporaryDirectory() + "scenario.pdf"
            ed.writePDF(to: URL(fileURLWithPath: path))
            log("SCENARIO PDF:", path, "pages", ed.stats.pages, "outline", ed.outline.count)
            NSApp.terminate(nil)
        }
    }
}
#endif

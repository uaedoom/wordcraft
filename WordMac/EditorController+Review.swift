import AppKit
import SwiftUI
import CoreServices

struct ThesaurusDraft: Identifiable {
    let id = UUID()
    var word: String
    var range: NSRange
    var synonyms: [String]
    var raw: String
}

struct WordCountInfo {
    var words = 0, characters = 0, noSpaces = 0, paragraphs = 0, lines = 0, pages = 0
}

// MARK: - State helpers

extension EditorController {
    var author: String { authorName.trimmingCharacters(in: .whitespaces).isEmpty ? "Author" : authorName }
    var initials: String {
        let parts = author.split(separator: " ").prefix(2).compactMap { $0.first }
        return parts.isEmpty ? "A" : String(parts).uppercased()
    }
    var isTracking: Bool { meta.trackChanges || meta.protection.mode == .trackedChanges }
    var canEditText: Bool { meta.protection.mode == .none || meta.protection.mode == .trackedChanges }
    var canComment: Bool { meta.protection.mode != .readOnly }

    func toggleTracking() {
        if meta.protection.mode == .trackedChanges { NSSound.beep(); return }
        updateMeta("Track Changes") { $0.trackChanges.toggle() }
    }
}

// MARK: - Tracking edits

extension EditorController {
    /// Called by the text view delegate before any edit. Returns false when the edit was handled here.
    func shouldAllowEdit(_ tv: NSTextView, range: NSRange, replacement: String?) -> Bool {
        if applyingTracked { return true }
        if meta.protection.mode == .forms, replacement != nil {
            // only the text inside a plain-text content control can be edited
            guard let st = tv.textStorage, st.length > 0 else { NSSound.beep(); return false }
            let probe = min(range.location, st.length - 1)
            var r = NSRange()
            if let v = st.attribute(.wcControl, at: probe, longestEffectiveRange: &r, in: NSRange(location: 0, length: st.length)),
               let p = ControlProps.decode(v), p.kind == "text",
               range.location >= r.location, NSMaxRange(range) <= NSMaxRange(r) { return true }
            NSSound.beep()
            return false
        }
        guard isTracking, let repl = replacement, let st = tv.textStorage else { return true }
        let replLen = (repl as NSString).length
        if range.length == 0 {
            if replLen > 0 { pendingInsertion = (range.location, replLen) }
            return true
        }
        let me = author
        let del = RevisionInfo(kind: .delete, author: me, date: Date())
        let region = NSMutableAttributedString(attributedString: st.attributedSubstring(from: range))
        var runs: [(NSRange, RevisionInfo?)] = []
        region.enumerateAttribute(.wcRevision, in: NSRange(location: 0, length: region.length)) { v, r, _ in runs.append((r, RevisionInfo.decode(v))) }
        for (r, rev) in runs.reversed() {
            if let rev, rev.kind == .insert, rev.author == me { region.deleteCharacters(in: r) }          // removing your own insertion
            else if let rev, rev.kind == .delete { continue }
            else { region.addAttribute(.wcRevision, value: del.encoded, range: r) }
        }
        if replLen > 0 {
            var attrs = st.attributes(at: min(range.location, max(0, st.length - 1)), effectiveRange: nil)
            for k in [NSAttributedString.Key.wcRevision, .wcComment, .link, .wcFootnote, .wcEndnote, .attachment, .wcImage, .wcEquation, .wcObject, .wcSection] { attrs.removeValue(forKey: k) }
            attrs[.wcRevision] = RevisionInfo(kind: .insert, author: me, date: Date()).encoded
            region.append(NSAttributedString(string: repl, attributes: attrs))
        }
        let sel = tv.selectedRange()
        let backspace = replLen == 0 && range.length == 1 && sel.length == 0 && sel.location == NSMaxRange(range)
        applyingTracked = true
        defer { applyingTracked = false }
        tv.undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: range, replacementString: region.string) {
            st.replaceCharacters(in: range, with: region)
            tv.didChangeText()
        }
        tv.undoManager?.setActionName("Tracked Change")
        tv.undoManager?.endUndoGrouping()
        tv.setSelectedRange(NSRange(location: backspace ? range.location : range.location + region.length, length: 0))
        return false
    }

    /// Paragraphs that start with a right-to-left script get a right-to-left base direction (and so align to the right).
    func fixDirections(in range: NSRange? = nil) {
        guard let st = engine?.storage, st.length > 0 else { return }
        let ns = st.string as NSString
        var r = range ?? NSRange(location: 0, length: ns.length)
        r = ns.paragraphRange(for: NSIntersectionRange(r, NSRange(location: 0, length: ns.length)))
        var loc = r.location
        var edits: [(NSRange, NSParagraphStyle)] = []
        while loc < NSMaxRange(r) {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if let ps = st.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle,
               ps.baseWritingDirection == .natural, ps.alignment == .natural || ps.alignment == .left,
               ns.substring(with: pr).startsRightToLeft, ps.textBlocks.isEmpty || true {
                let m = ps.mutableCopy() as! NSMutableParagraphStyle
                m.baseWritingDirection = .rightToLeft
                m.alignment = .natural
                edits.append((pr, m))
            }
            loc = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
        guard !edits.isEmpty else { return }
        st.beginEditing()
        for (pr, m) in edits { st.addAttribute(.paragraphStyle, value: m, range: pr) }
        st.endEditing()
    }

    /// Marks text that was just typed or pasted as a tracked insertion.
    func noteTextChanged() {
        if let tv = bodyTextView {
            let ns = tv.string as NSString
            let caret = min(tv.selectedRange().location, ns.length)
            let prev = max(0, caret - 1)
            fixDirections(in: NSRange(location: prev, length: caret - prev))
        }
        if let p = pendingInsertion, let st = engine?.storage {
            pendingInsertion = nil
            let r = NSRange(location: p.loc, length: p.len)
            if NSMaxRange(r) <= st.length {
                st.addAttribute(.wcRevision, value: RevisionInfo(kind: .insert, author: author, date: Date()).encoded, range: r)
            }
        }
        scheduleMarkup()
    }

    func scheduleMarkup() {
        markupWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshMarkup(); self?.refreshReviewLists() }
        markupWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    /// Draws revisions and commented text with temporary attributes (they are never saved).
    func refreshMarkup() {
        guard let lm = engine?.layoutManager, let st = engine?.storage else { return }
        for r in markupRanges where NSMaxRange(r) <= st.length {
            for k in [NSAttributedString.Key.foregroundColor, .strikethroughStyle, .underlineStyle, .underlineColor, .strikethroughColor, .backgroundColor] {
                lm.removeTemporaryAttribute(k, forCharacterRange: r)
            }
        }
        markupRanges = []
        guard showMarkup, st.length > 0 else { lm.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: st.length)); return }
        let full = NSRange(location: 0, length: st.length)
        st.enumerateAttribute(.wcRevision, in: full, options: []) { v, r, _ in
            guard let rev = RevisionInfo.decode(v) else { return }
            let c = RevisionInfo.color(for: rev.author)
            var a: [NSAttributedString.Key: Any] = [.foregroundColor: c]
            if rev.kind == .insert { a[.underlineStyle] = NSUnderlineStyle.single.rawValue; a[.underlineColor] = c }
            else { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; a[.strikethroughColor] = c }
            lm.addTemporaryAttributes(a, forCharacterRange: r)
            markupRanges.append(r)
        }
        st.enumerateAttribute(.wcControl, in: full, options: []) { v, r, _ in
            guard let p = ControlProps.decode(v) else { return }
            var a: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor(calibratedRed: 0.55, green: 0.7, blue: 1, alpha: 0.22)]
            if (st.string as NSString).substring(with: r) == p.placeholder { a[.foregroundColor] = NSColor(white: 0.5, alpha: 1) }
            lm.addTemporaryAttributes(a, forCharacterRange: r)
            markupRanges.append(r)
        }
        st.enumerateAttribute(.wcIndex, in: full, options: []) { v, r, _ in
            guard v != nil else { return }
            lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.systemPurple], forCharacterRange: r)
            markupRanges.append(r)
        }
        st.enumerateAttribute(.wcComment, in: full, options: []) { v, r, _ in
            guard let id = v as? String, let rec = meta.comments[id], !rec.resolved else { return }
            let sel = id == selectedCommentID
            lm.addTemporaryAttributes([.backgroundColor: NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: sel ? 0.55 : 0.3)], forCharacterRange: r)
            markupRanges.append(r)
        }
    }

    /// Printing ignores temporary attributes, so for PDF/print the markup is written into the text for the duration of `body`.
    func withPrintedMarkup(_ body: () -> Void) {
        guard showMarkup, let st = engine?.storage, st.length > 0 else { body(); return }
        var saved: [(NSRange, NSAttributedString)] = []
        st.enumerateAttributes(in: NSRange(location: 0, length: st.length), options: []) { a, r, _ in
            if a[.wcRevision] != nil || (a[.wcComment] as? String).map({ meta.comments[$0]?.resolved == false }) == true {
                saved.append((r, st.attributedSubstring(from: r)))
            }
        }
        guard !saved.isEmpty else { body(); return }
        st.beginEditing()
        for (r, orig) in saved {
            let a = orig.attributes(at: 0, effectiveRange: nil)
            if let rev = RevisionInfo.decode(a[.wcRevision]) {
                let c = RevisionInfo.color(for: rev.author)
                var add: [NSAttributedString.Key: Any] = [.foregroundColor: c]
                if rev.kind == .insert { add[.underlineStyle] = NSUnderlineStyle.single.rawValue; add[.underlineColor] = c }
                else { add[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; add[.strikethroughColor] = c }
                st.addAttributes(add, range: r)
            } else {
                st.addAttribute(.backgroundColor, value: NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 0.35), range: r)
            }
        }
        st.endEditing()
        body()
        st.beginEditing()
        for (r, orig) in saved where NSMaxRange(r) <= st.length { st.replaceCharacters(in: r, with: orig) }
        st.endEditing()
    }

    func setShowMarkup(_ on: Bool) {
        showMarkup = on
        refreshMarkup()
    }

    // MARK: Lists

    func collectRevisions() -> [RevisionItem] {
        guard let st = engine?.storage else { return [] }
        var out: [RevisionItem] = []
        st.enumerateAttribute(.wcRevision, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            guard let info = RevisionInfo.decode(v) else { return }
            if var last = out.last, last.info == info, NSMaxRange(last.range) == r.location {
                last.range.length += r.length
                out[out.count - 1] = last
            } else {
                out.append(RevisionItem(range: r, info: info, preview: ""))
            }
        }
        let ns = st.string as NSString
        for i in out.indices {
            let t = ns.substring(with: out[i].range).replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\u{FFFC}", with: "▢")
            out[i].preview = String(t.prefix(80))
        }
        return out
    }

    func refreshReviewLists() {
        let revs = collectRevisions()
        if revs != revisions { revisions = revs }
        var items: [CommentItem] = []
        if let st = engine?.storage {
            let ns = st.string as NSString
            st.enumerateAttribute(.wcComment, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
                guard let id = v as? String, let rec = meta.comments[id] else { return }
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].range = NSUnionRange(items[i].range, r)
                } else {
                    items.append(CommentItem(id: id, range: r, preview: String(ns.substring(with: r).prefix(60)), rec: rec))
                }
            }
        }
        if items != commentItems { commentItems = items }
    }

    // MARK: Accept / reject

    private func resolve(_ items: [RevisionItem], accept: Bool) {
        guard let tv = bodyTextView, let st = tv.textStorage, !items.isEmpty else { return }
        applyingTracked = true
        defer { applyingTracked = false }
        tv.undoManager?.beginUndoGrouping()
        for item in items.sorted(by: { $0.range.location > $1.range.location }) {
            let r = item.range
            guard NSMaxRange(r) <= st.length else { continue }
            let removeText = (item.info.kind == .insert) != accept
            if removeText {
                if tv.shouldChangeText(in: r, replacementString: "") { st.deleteCharacters(in: r); tv.didChangeText() }
            } else if tv.shouldChangeText(in: r, replacementString: nil) {
                st.removeAttribute(.wcRevision, range: r)
                tv.didChangeText()
            }
        }
        tv.undoManager?.setActionName(accept ? "Accept Changes" : "Reject Changes")
        tv.undoManager?.endUndoGrouping()
        scheduleMarkup()
    }

    func acceptAll() { resolve(collectRevisions(), accept: true) }
    func rejectAll() { resolve(collectRevisions(), accept: false) }
    func accept(_ item: RevisionItem) { resolve([item], accept: true) }
    func reject(_ item: RevisionItem) { resolve([item], accept: false) }

    /// Accepts or rejects the change at the caret/selection (or the next one) and moves on.
    func resolveCurrent(accept: Bool) {
        guard let tv = bodyTextView else { return }
        let sel = tv.selectedRange()
        let all = collectRevisions()
        let hit = all.filter { NSIntersectionRange($0.range, sel).length > 0 || ($0.range.location <= sel.location && sel.location <= NSMaxRange($0.range)) }
        let target = hit.isEmpty ? all.first { $0.range.location >= sel.location } : nil
        let items = hit.isEmpty ? (target.map { [$0] } ?? []) : hit
        guard !items.isEmpty else { NSSound.beep(); return }
        resolve(items, accept: accept)
        goToRevision(next: true)
    }

    func goToRevision(next: Bool) {
        guard let tv = bodyTextView else { return }
        let all = collectRevisions()
        guard !all.isEmpty else { NSSound.beep(); return }
        let loc = tv.selectedRange().location
        let pick: RevisionItem
        if next { pick = all.first { $0.range.location > loc } ?? all[0] }
        else { pick = all.last { $0.range.location < loc } ?? all[all.count - 1] }
        show(range: pick.range)
    }

    func show(range: NSRange) {
        engine?.reveal(loc: range.location)
        bodyTextView?.setSelectedRange(range)
    }
}

// MARK: - Comments

extension EditorController {
    func addComment() {
        guard canComment, let tv = bodyTextView, let st = tv.textStorage else { return }
        var r = tv.selectedRange()
        if r.length == 0 { r = tv.selectionRange(forProposedRange: r, granularity: .selectByWord) }
        guard r.length > 0 else { NSSound.beep(); return }
        let id = "c" + String(UUID().uuidString.prefix(8))
        tv.undoManager?.beginUndoGrouping()
        updateMeta("New Comment") { $0.comments[id] = CommentRec(author: author, initials: initials, date: Date().timeIntervalSince1970, text: "") }
        if tv.shouldChangeText(in: r, replacementString: nil) {
            st.addAttribute(.wcComment, value: id, range: r)
            tv.didChangeText()
        }
        tv.undoManager?.setActionName("New Comment")
        tv.undoManager?.endUndoGrouping()
        showReview = true
        reviewTab = 1
        editingCommentID = id
        selectedCommentID = id
        refreshReviewLists()
        scheduleMarkup()
    }

    func updateComment(_ id: String, _ f: (inout CommentRec) -> Void) {
        updateMeta("Edit Comment") { m in if var c = m.comments[id] { f(&c); m.comments[id] = c } }
        refreshReviewLists()
        scheduleMarkup()
    }

    func replyToComment(_ id: String, text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let reply = CommentReply(author: author, text: text, date: Date().timeIntervalSince1970)
        updateComment(id) { $0.replies.append(reply) }
    }

    func deleteComment(_ id: String) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        tv.undoManager?.beginUndoGrouping()
        var ranges: [NSRange] = []
        st.enumerateAttribute(.wcComment, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            if (v as? String) == id { ranges.append(r) }
        }
        for r in ranges where tv.shouldChangeText(in: r, replacementString: nil) {
            st.removeAttribute(.wcComment, range: r)
            tv.didChangeText()
        }
        updateMeta("Delete Comment") { $0.comments.removeValue(forKey: id) }
        tv.undoManager?.setActionName("Delete Comment")
        tv.undoManager?.endUndoGrouping()
        if editingCommentID == id { editingCommentID = nil }
        refreshReviewLists()
        scheduleMarkup()
    }

    func deleteAllComments() { for c in commentItems { deleteComment(c.id) } }

    func selectComment(_ id: String) {
        selectedCommentID = id
        if let item = commentItems.first(where: { $0.id == id }) { show(range: item.range) }
        scheduleMarkup()
    }

    func goToComment(next: Bool) {
        guard let tv = bodyTextView, !commentItems.isEmpty else { NSSound.beep(); return }
        let loc = tv.selectedRange().location
        let sorted = commentItems.sorted { $0.range.location < $1.range.location }
        let pick = next ? (sorted.first { $0.range.location > loc } ?? sorted[0]) : (sorted.last { $0.range.location < loc } ?? sorted[sorted.count - 1])
        showReview = true
        reviewTab = 1
        selectComment(pick.id)
    }

    /// Keeps the review pane's highlighted comment in step with the caret.
    func syncSelectedComment() {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        let loc = min(tv.selectedRange().location, max(0, st.length - 1))
        guard st.length > 0 else { return }
        let id = st.attribute(.wcComment, at: loc, effectiveRange: nil) as? String
        if id != selectedCommentID && (id != nil || selectedCommentID != nil) {
            selectedCommentID = id
            scheduleMarkup()
        }
    }
}

// MARK: - Protection

extension EditorController {
    func startProtection(_ mode: Protection.Mode, password: String) {
        updateMeta("Restrict Editing") { m in
            var p = Protection()
            p.mode = mode
            if mode != .none { p.setPassword(password) }
            m.protection = p
            if mode == .trackedChanges { m.trackChanges = true }
        }
        engine?.applyProtection()
    }

    /// Returns false when the password is wrong.
    func stopProtection(password: String) -> Bool {
        guard meta.protection.check(password) else { return false }
        updateMeta("Stop Protection") { $0.protection = Protection() }
        engine?.applyProtection()
        return true
    }
}

// MARK: - Proofing

extension EditorController {
    private func forEachView(_ f: (NSTextView) -> Void) { engine?.pagesView.textViews.forEach(f) }

    func toggleSpelling() { spellingOn.toggle(); forEachView { $0.isContinuousSpellCheckingEnabled = spellingOn } }
    func toggleGrammar() { grammarOn.toggle(); forEachView { $0.isGrammarCheckingEnabled = grammarOn } }
    func toggleAutoCorrect() { autoCorrectOn.toggle(); forEachView { $0.isAutomaticSpellingCorrectionEnabled = autoCorrectOn } }

    func showSpellingPanel() {
        guard let tv = bodyTextView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.showGuessPanel(nil)
        tv.checkSpelling(nil)
    }

    func nextMisspelling() {
        guard let tv = bodyTextView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.checkSpelling(nil)
    }

    var spellingLanguages: [String] { NSSpellChecker.shared.availableLanguages }

    func setSpellingLanguage(_ l: String?) {
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = (l == nil)
        if let l { NSSpellChecker.shared.setLanguage(l) }
    }

    func lookUp() {
        guard let tv = bodyTextView else { return }
        var r = tv.selectedRange()
        if r.length == 0 { r = tv.selectionRange(forProposedRange: r, granularity: .selectByWord) }
        guard r.length > 0 else { return }
        tv.showDefinition(for: tv.attributedSubstring(forProposedRange: r, actualRange: nil) ?? NSAttributedString(string: ""), at: tv.firstRect(forCharacterRange: r, actualRange: nil).origin)
    }

    // MARK: Thesaurus

    private func thesaurusEntry(_ word: String) -> String? {
        typealias CopyDicts = @convention(c) () -> Unmanaged<CFSet>?
        typealias GetName = @convention(c) (OpaquePointer?) -> Unmanaged<CFString>?
        typealias CopyDef = @convention(c) (OpaquePointer?, CFString, CFRange) -> Unmanaged<CFString>?
        guard let h = dlopen(nil, RTLD_NOW), let defSym = dlsym(h, "DCSCopyTextDefinition") else { return nil }
        let copyDef = unsafeBitCast(defSym, to: CopyDef.self)
        let range = CFRange(location: 0, length: (word as NSString).length)
        if let setSym = dlsym(h, "DCSCopyAvailableDictionaries"), let nameSym = dlsym(h, "DCSDictionaryGetName"),
           let set = unsafeBitCast(setSym, to: CopyDicts.self)()?.takeRetainedValue() {
            let getName = unsafeBitCast(nameSym, to: GetName.self)
            var count = CFSetGetCount(set)
            var values = [UnsafeRawPointer?](repeating: nil, count: count)
            CFSetGetValues(set, &values)
            count = values.count
            for v in values {
                guard let v else { continue }
                let d = OpaquePointer(v)
                if let n = getName(d)?.takeUnretainedValue() as String?, n.lowercased().contains("thesaurus"),
                   let t = copyDef(d, word as CFString, range)?.takeRetainedValue() as String? { return t }
            }
        }
        return copyDef(nil, word as CFString, range)?.takeRetainedValue() as String?
    }

    static func synonyms(from entry: String, word: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = [word.lowercased()]
        let cleaned = entry.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        for tok in cleaned.components(separatedBy: CharacterSet(charactersIn: ",;|:•▶●\n")) {
            let t = tok.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let words = t.split(separator: " ")
            guard (1...3).contains(words.count), t.count >= 2, t.count <= 24,
                  t.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" }), seen.insert(t).inserted else { continue }
            let stop: Set<String> = ["noun", "verb", "adjective", "adverb", "informal", "formal", "archaic", "see", "antonyms", "synonyms", "usage", "phrases", "origin", "derivatives", "plural", "british", "north american"]
            if stop.contains(t) { continue }
            out.append(t)
            if out.count >= 40 { break }
        }
        return out
    }

    func startThesaurus() {
        guard let tv = bodyTextView else { return }
        var r = tv.selectedRange()
        if r.length == 0 { r = tv.selectionRange(forProposedRange: r, granularity: .selectByWord) }
        guard r.length > 0 else { NSSound.beep(); return }
        let word = (tv.string as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = thesaurusEntry(word) ?? ""
        thesaurus = ThesaurusDraft(word: word, range: r, synonyms: Self.synonyms(from: entry, word: word), raw: entry)
    }

    func replaceWord(_ d: ThesaurusDraft, with s: String) {
        guard let tv = bodyTextView else { return }
        tv.insertText(s, replacementRange: d.range)
        thesaurus = nil
    }

    // MARK: Word count

    func countWords() -> WordCountInfo {
        var info = WordCountInfo()
        guard let tv = bodyTextView else { return info }
        let str = tv.string.replacingOccurrences(of: "\u{200B}", with: "")
        info.words = str.split(whereSeparator: { $0.isWhitespace }).count
        info.characters = str.count
        info.noSpaces = str.filter { !$0.isWhitespace }.count
        info.paragraphs = str.split(separator: "\n", omittingEmptySubsequences: true).count
        info.pages = engine?.pagesView.pageCount ?? 1
        if let lm = engine?.layoutManager {
            var idx = 0, lines = 0
            let n = lm.numberOfGlyphs
            while idx < n {
                var r = NSRange()
                lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &r)
                lines += 1
                idx = NSMaxRange(r)
                if r.length == 0 { break }
            }
            info.lines = lines
        }
        return info
    }
}

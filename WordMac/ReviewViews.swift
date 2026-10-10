import SwiftUI

// MARK: - Ribbon

struct ReviewRibbon: View {
    @EnvironmentObject var ed: EditorController

    private func toggleRow(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() })).toggleStyle(.checkbox).font(.caption)
    }

    var body: some View {
        RibbonGroup(title: "Proofing") {
            HStack(spacing: 6) {
                RibbonBigButton(symbol: "textformat.abc.dottedunderline", title: "Spelling") { ed.showSpellingPanel() }
                VStack(alignment: .leading, spacing: 2) {
                    toggleRow("Check spelling", ed.spellingOn) { ed.toggleSpelling() }
                    toggleRow("Check grammar", ed.grammarOn) { ed.toggleGrammar() }
                    toggleRow("Auto-correct", ed.autoCorrectOn) { ed.toggleAutoCorrect() }
                }
                RibbonBigButton(symbol: "books.vertical", title: "Thesaurus") { ed.startThesaurus() }
                RibbonBigButton(symbol: "character.book.closed", title: "Define") { ed.lookUp() }
                RibbonBigButton(symbol: "textformat.123", title: "Word Count") { ed.showWordCount = true }
                Menu {
                    Button("Detect automatically") { ed.setSpellingLanguage(nil) }
                    Divider()
                    ForEach(ed.spellingLanguages, id: \.self) { l in
                        Button(Locale.current.localizedString(forIdentifier: l) ?? l) { ed.setSpellingLanguage(l) }
                    }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "globe").font(.system(size: 22)); Text("Language").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 64, height: 54)
            }
        }
        RibbonGroup(title: "Tracking") {
            HStack(spacing: 6) {
                RibbonBigButton(symbol: ed.isTracking ? "pencil.and.list.clipboard" : "pencil.slash", title: ed.isTracking ? "Tracking On" : "Track") { ed.toggleTracking() }
                    .background(RoundedRectangle(cornerRadius: 6).fill(ed.isTracking ? Color.accentColor.opacity(0.25) : .clear))
                    .frame(width: 70)
                VStack(alignment: .leading, spacing: 2) {
                    toggleRow("Show markup", ed.showMarkup) { ed.setShowMarkup(!ed.showMarkup) }
                    toggleRow("Review pane", ed.showReview) { ed.showReview.toggle() }
                }
                Menu {
                    Button("Accept and Move to Next") { ed.resolveCurrent(accept: true) }
                    Button("Accept All Changes") { ed.acceptAll() }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "checkmark.circle").font(.system(size: 22)); Text("Accept").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 54, height: 54)
                Menu {
                    Button("Reject and Move to Next") { ed.resolveCurrent(accept: false) }
                    Button("Reject All Changes") { ed.rejectAll() }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "xmark.circle").font(.system(size: 22)); Text("Reject").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 54, height: 54)
                VStack(spacing: 2) {
                    RibbonButton(symbol: "chevron.up", help: "Previous Change") { ed.goToRevision(next: false) }
                    RibbonButton(symbol: "chevron.down", help: "Next Change") { ed.goToRevision(next: true) }
                }
            }
        }
        RibbonGroup(title: "Comments") {
            HStack(spacing: 6) {
                RibbonBigButton(symbol: "text.bubble", title: "New") { ed.addComment() }
                VStack(spacing: 2) {
                    RibbonButton(symbol: "chevron.up", help: "Previous Comment") { ed.goToComment(next: false) }
                    RibbonButton(symbol: "chevron.down", help: "Next Comment") { ed.goToComment(next: true) }
                }
                Menu {
                    Button("Delete Comment") { if let id = ed.selectedCommentID { ed.deleteComment(id) } }
                        .disabled(ed.selectedCommentID == nil)
                    Button("Delete All Comments") { ed.deleteAllComments() }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "trash").font(.system(size: 22)); Text("Delete").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 54, height: 54)
            }
        }
        RibbonGroup(title: "Compare") {
            RibbonBigButton(symbol: "doc.on.doc.fill", title: "Compare") { ed.compareWithOriginal() }
        }
        RibbonGroup(title: "Protect") {
            RibbonBigButton(symbol: ed.meta.protection.mode == .none ? "lock.open" : "lock.fill", title: "Restrict") { ed.showRestrict = true }
        }
    }
}

// MARK: - Review pane

struct ReviewPane: View {
    @EnvironmentObject var ed: EditorController
    @State private var replyText: [String: String] = [:]

    private static let dateFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $ed.reviewTab) {
                Text("Changes (\(ed.revisions.count))").tag(0)
                Text("Comments (\(ed.commentItems.count))").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                TextField("Your name", text: $ed.authorName).textFieldStyle(.roundedBorder).font(.caption)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if ed.reviewTab == 0 { changes } else { comments }
                }
                .padding(10)
            }
        }
        .frame(width: 290)
        .background(.bar)
    }

    @ViewBuilder private var changes: some View {
        if ed.revisions.isEmpty {
            Text(ed.isTracking ? "No changes yet. Edits you make are tracked." : "Turn on Track Changes in the Review tab, then edit.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(ed.revisions) { r in
            let color = Color(nsColor: RevisionInfo.color(for: r.info.author))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(r.info.kind == .insert ? "Inserted" : "Deleted").font(.caption.weight(.semibold)).foregroundStyle(color)
                    Text(r.info.author).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.dateFmt.localizedString(for: r.info.date, relativeTo: Date())).font(.caption2).foregroundStyle(.secondary)
                }
                Text(r.preview).font(.system(size: 12)).strikethrough(r.info.kind == .delete).lineLimit(3)
                HStack(spacing: 10) {
                    Button { ed.accept(r) } label: { Label("Accept", systemImage: "checkmark") }
                    Button { ed.reject(r) } label: { Label("Reject", systemImage: "xmark") }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4)))
            .contentShape(Rectangle())
            .onTapGesture { ed.show(range: r.range) }
        }
    }

    @ViewBuilder private var comments: some View {
        if ed.commentItems.isEmpty {
            Text("Select text and choose New Comment in the Review tab.").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(ed.commentItems) { c in
            let selected = ed.selectedCommentID == c.id
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(c.rec.initials).font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Circle().fill(Color(nsColor: RevisionInfo.color(for: c.rec.author))))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.rec.author).font(.caption.weight(.semibold))
                        Text(Self.dateFmt.localizedString(for: Date(timeIntervalSince1970: c.rec.date), relativeTo: Date())).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if c.rec.resolved { Text("Resolved").font(.caption2).foregroundStyle(.green) }
                }
                Text("“\(c.preview)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if ed.editingCommentID == c.id {
                    TextEditor(text: Binding(get: { c.rec.text }, set: { v in ed.updateComment(c.id) { $0.text = v } }))
                        .font(.system(size: 12)).frame(minHeight: 54).scrollContentBackground(.hidden)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    Button("Done") { ed.editingCommentID = nil }.buttonStyle(.borderless).font(.caption)
                } else {
                    Text(c.rec.text.isEmpty ? "Add a comment…" : c.rec.text)
                        .font(.system(size: 12)).foregroundStyle(c.rec.text.isEmpty ? .secondary : .primary)
                        .onTapGesture { ed.editingCommentID = c.id }
                }
                ForEach(Array(c.rec.replies.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.author).font(.caption2.weight(.semibold))
                        Text(r.text).font(.system(size: 12))
                    }
                    .padding(.leading, 12)
                }
                HStack {
                    TextField("Reply", text: Binding(get: { replyText[c.id] ?? "" }, set: { replyText[c.id] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit { ed.replyToComment(c.id, text: replyText[c.id] ?? ""); replyText[c.id] = "" }
                }
                HStack(spacing: 12) {
                    Button(c.rec.resolved ? "Reopen" : "Resolve") { ed.updateComment(c.id) { $0.resolved.toggle() } }
                    Button("Delete", role: .destructive) { ed.deleteComment(c.id) }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.yellow.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.yellow.opacity(0.7) : Color.clear))
            .opacity(c.rec.resolved ? 0.6 : 1)
            .onTapGesture { ed.selectComment(c.id) }
        }
    }
}

// MARK: - Sheets

struct RestrictSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var mode: Protection.Mode = .readOnly
    @State private var password = ""
    @State private var confirm = ""
    @State private var stopPassword = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restrict Editing").font(.headline)
            if ed.meta.protection.mode == .none {
                Picker("Allow only", selection: $mode) {
                    ForEach([Protection.Mode.readOnly, .comments, .trackedChanges]) { Text($0.title).tag($0) }
                }.pickerStyle(.radioGroup)
                Text("Optional password (needed to stop protection):").font(.caption).foregroundStyle(.secondary)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { ed.showRestrict = false }.keyboardShortcut(.cancelAction)
                    Button("Start Enforcing") {
                        guard password == confirm else { error = "The passwords don't match."; return }
                        ed.startProtection(mode, password: password)
                        ed.showRestrict = false
                    }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("This document is protected: \(ed.meta.protection.mode.title.lowercased()).").font(.callout)
                if ed.meta.protection.hasPassword {
                    SecureField("Password", text: $stopPassword).textFieldStyle(.roundedBorder)
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Close") { ed.showRestrict = false }.keyboardShortcut(.cancelAction)
                    Button("Stop Protection") {
                        if ed.stopProtection(password: stopPassword) { ed.showRestrict = false } else { error = "Incorrect password." }
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 400)
    }
}

struct WordCountSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var info = WordCountInfo()

    private func row(_ t: String, _ v: Int) -> some View {
        HStack { Text(t); Spacer(); Text("\(v)").monospacedDigit() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Word Count").font(.headline)
            row("Pages", info.pages)
            row("Words", info.words)
            row("Characters (no spaces)", info.noSpaces)
            row("Characters (with spaces)", info.characters)
            row("Paragraphs", info.paragraphs)
            row("Lines", info.lines)
            HStack { Spacer(); Button("Close") { ed.showWordCount = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 320)
        .onAppear { info = ed.countWords() }
    }
}

struct ThesaurusSheet: View {
    @EnvironmentObject var ed: EditorController
    let draft: ThesaurusDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thesaurus: “\(draft.word)”").font(.headline)
            if draft.synonyms.isEmpty {
                Text(draft.raw.isEmpty ? "No entry found for this word." : draft.raw).font(.callout).foregroundStyle(.secondary)
                    .frame(maxHeight: 160)
            } else {
                Text("Click a word to replace “\(draft.word)”:").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(draft.synonyms, id: \.self) { s in
                            Button(s) { ed.replaceWord(draft, with: s) }.buttonStyle(.bordered)
                        }
                    }
                }.frame(maxHeight: 200)
            }
            HStack { Spacer(); Button("Close") { ed.thesaurus = nil }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 460)
    }
}

import SwiftUI

// MARK: - Mailings tab

struct MailingsRibbon: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        RibbonGroup(title: "Start Mail Merge") {
            HStack(spacing: 6) {
                RibbonBigButton(symbol: "tray.and.arrow.down", title: "Recipients") { ed.importMergeData() }
                if ed.mergeCount > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ed.mergeCount) recipients").font(.caption)
                        Button("View list…") { ed.showMergeData = true }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        RibbonGroup(title: "Write & Insert Fields") {
            Menu {
                if ed.mergeColumns.isEmpty { Text("Choose recipients first") }
                ForEach(ed.mergeColumns, id: \.self) { c in Button(c) { ed.insertMergeField(c) } }
            } label: {
                VStack(spacing: 3) { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 22)); Text("Insert Field").font(.caption) }
            }
            .menuStyle(.borderlessButton).frame(width: 78, height: 54)
        }
        RibbonGroup(title: "Preview Results") {
            HStack(spacing: 6) {
                RibbonBigButton(symbol: ed.mergePreviewing ? "eye.fill" : "eye", title: "Preview") { ed.previewMerge(ed.mergePreviewing ? nil : ed.mergeIndex) }
                    .background(RoundedRectangle(cornerRadius: 6).fill(ed.mergePreviewing ? Color.accentColor.opacity(0.25) : .clear))
                if ed.mergeCount > 0 {
                    RibbonButton(symbol: "chevron.left", help: "Previous Record") { ed.stepMerge(-1) }
                    Text("\(ed.mergeIndex + 1) / \(ed.mergeCount)").font(.caption).monospacedDigit()
                    RibbonButton(symbol: "chevron.right", help: "Next Record") { ed.stepMerge(1) }
                }
            }
        }
        RibbonGroup(title: "Finish") {
            RibbonBigButton(symbol: "doc.on.doc", title: "Merge") { ed.finishMerge() }
        }
    }
}

// MARK: - References additions

struct ReferencesExtras: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        RibbonGroup(title: "Citations & Bibliography") {
            HStack(spacing: 6) {
                Menu {
                    if ed.meta.sources.isEmpty { Text("No sources yet") }
                    ForEach(ed.meta.sources) { s in Button("\(s.id) — \(s.title)") { ed.insertCitation(tag: s.id, page: "") } }
                    Divider()
                    Button("Manage Sources…") { ed.showSources = true }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "quote.opening").font(.system(size: 22)); Text("Citation").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 58, height: 54)
                RibbonBigButton(symbol: "books.vertical", title: "Sources") { ed.showSources = true }
                RibbonBigButton(symbol: "list.bullet.rectangle", title: "Bibliography") { ed.insertBibliography() }.frame(width: 80)
                Picker("", selection: Binding(get: { ed.citationStyle }, set: { ed.setCitationStyle($0) })) {
                    ForEach(CitationStyle.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
        }
        RibbonGroup(title: "Captions & Cross-references") {
            HStack(spacing: 6) {
                Menu {
                    Button("Figure") { ed.insertCaption(label: "Figure") }
                    Button("Table") { ed.insertCaption(label: "Table") }
                    Button("Equation") { ed.insertCaption(label: "Equation") }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "text.below.photo").font(.system(size: 22)); Text("Caption").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 58, height: 54)
                RibbonBigButton(symbol: "arrow.turn.down.right", title: "Cross-ref") { ed.showXref = true }
            }
        }
        RibbonGroup(title: "Index") {
            HStack(spacing: 6) {
                RibbonBigButton(symbol: "tag", title: "Mark Entry") { ed.showIndexMark = true }.frame(width: 70)
                RibbonBigButton(symbol: "list.bullet.indent", title: ed.blockRange(.wcIndexBlock) == nil ? "Insert Index" : "Update") { ed.insertIndex() }
                    .frame(width: 76)
            }
        }
        RibbonGroup(title: "Fields") {
            RibbonBigButton(symbol: "arrow.triangle.2.circlepath", title: "Update All") { ed.updateAllFields() }
        }
    }
}

// MARK: - Insert additions: forms

struct FormsGroup: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        RibbonGroup(title: "Forms") {
            HStack(spacing: 6) {
                Menu {
                    Button("Plain Text") { ed.insertControl(kind: "text") }
                    Button("Drop-Down List") { ed.insertControl(kind: "dropdown") }
                    Button("Date Picker") { ed.insertControl(kind: "date") }
                    Button("Check Box") { ed.insertControl(kind: "checkbox") }
                    Divider()
                    Button("Properties…") { ed.editControlProperties() }
                    Button("Remove Control") { ed.removeControl() }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "checklist").font(.system(size: 22)); Text("Controls").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 60, height: 54)
                RibbonBigButton(symbol: "bookmark", title: "Bookmark") { ed.showBookmark = true }
            }
        }
    }
}

// MARK: - Sheets

struct SourcesSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var selection: String?
    @State private var draft = Source(id: "")
    @State private var page = ""

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack { Text(LocalizedStringKey(title)).frame(width: 90, alignment: .trailing).font(.caption); TextField("", text: text).textFieldStyle(.roundedBorder) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading) {
                Text("Sources").font(.headline)
                List(ed.meta.sources, selection: $selection) { s in
                    VStack(alignment: .leading) { Text(s.id).bold(); Text(s.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.tag(s.id)
                }
                .frame(width: 190, height: 330)
                HStack {
                    Button("New") { draft = Source(id: "Source\(ed.meta.sources.count + 1)"); selection = nil }
                    Button("Delete") { if let id = selection { ed.deleteSource(id); selection = nil; draft = Source(id: "") } }.disabled(selection == nil)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.id.isEmpty ? "Select or create a source" : "Edit Source").font(.headline)
                if !draft.id.isEmpty {
                    Picker("Type", selection: $draft.kind) {
                        Text("Book").tag("book"); Text("Journal article").tag("article"); Text("Website").tag("website"); Text("Report").tag("report")
                    }.pickerStyle(.segmented).labelsHidden()
                    field("Tag", $draft.id)
                    field("Authors", $draft.authors)
                    Text("Format: Last, First; Last, First").font(.caption2).foregroundStyle(.secondary).padding(.leading, 96)
                    field("Title", $draft.title)
                    field("Year", $draft.year)
                    if draft.kind == "article" || draft.kind == "website" { field(draft.kind == "article" ? "Journal" : "Site", $draft.container) }
                    if draft.kind != "article" && draft.kind != "website" { field("Publisher", $draft.publisher); field("City", $draft.city) }
                    if draft.kind == "article" { field("Volume", $draft.volume); field("Issue", $draft.issue); field("Pages", $draft.pages) }
                    if draft.kind == "website" { field("URL", $draft.url) }
                    HStack {
                        Spacer()
                        Button("Save Source") { ed.saveSource(draft); selection = draft.id }.disabled(draft.id.isEmpty || draft.title.isEmpty)
                    }
                    Divider()
                    HStack {
                        TextField("Page (optional)", text: $page).textFieldStyle(.roundedBorder).frame(width: 130)
                        Button("Insert Citation") { ed.saveSource(draft); ed.insertCitation(tag: draft.id, page: page); ed.showSources = false }
                            .disabled(draft.id.isEmpty || draft.title.isEmpty)
                    }
                }
                Spacer()
                HStack { Spacer(); Button("Done") { ed.showSources = false }.keyboardShortcut(.defaultAction) }
            }
            .frame(width: 330)
        }
        .padding(20)
        .onChange(of: selection) { _, id in if let id, let s = ed.meta.sources.first(where: { $0.id == id }) { draft = s } }
    }
}

struct CrossRefSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var kind = 0
    @State private var picked: String?
    @State private var what = "text"
    @State private var items: [(id: String, title: String, range: NSRange)] = []

    private func load() {
        switch kind {
        case 0: items = ed.headings().map { ("h\($0.loc)", $0.title, NSRange(location: $0.loc, length: ($0.title as NSString).length)) }
        case 1: items = ed.bookmarks().map { ($0.name, $0.name + " — " + String($0.text.prefix(40)), $0.range) }
        default: items = ed.captions().map { ("c\($0.id)", $0.text, $0.range) }
        }
        picked = items.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cross-reference").font(.headline)
            Picker("", selection: $kind) { Text("Heading").tag(0); Text("Bookmark").tag(1); Text("Caption").tag(2) }
                .pickerStyle(.segmented).labelsHidden().onChange(of: kind) { _, _ in load() }
            List(items, id: \.id, selection: $picked) { Text($0.title).lineLimit(1).tag($0.id) }.frame(height: 180)
            Picker("Insert", selection: $what) { Text("Text").tag("text"); Text("Page number").tag("page") }.pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Cancel") { ed.showXref = false }.keyboardShortcut(.cancelAction)
                Button("Insert") {
                    guard let id = picked, let item = items.first(where: { $0.id == id }) else { return }
                    var name = id
                    if kind != 1 {
                        var range = item.range
                        if kind == 2, let c = ed.captions().first(where: { "c\($0.id)" == id }) { range = c.range }
                        guard let n = ed.ensureBookmark(over: range) else { return }
                        name = n
                    }
                    ed.insertCrossRef(name: name, what: what)
                    ed.showXref = false
                }.keyboardShortcut(.defaultAction).disabled(picked == nil)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear(perform: load)
    }
}

struct BookmarkSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var name = ""
    @State private var list: [EditorController.BookmarkInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmarks").font(.headline)
            HStack {
                TextField("Bookmark name", text: $name).textFieldStyle(.roundedBorder)
                Button("Add") { ed.addBookmark(name); name = ""; list = ed.bookmarks() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(list) { b in
                HStack {
                    Text(b.name).bold(); Text(String(b.text.prefix(30))).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Go to") { ed.goToBookmark(b.name); ed.showBookmark = false }.buttonStyle(.borderless)
                    Button("Delete") { ed.deleteBookmark(b.name); list = ed.bookmarks() }.buttonStyle(.borderless)
                }
            }.frame(height: 160)
            HStack { Spacer(); Button("Close") { ed.showBookmark = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 440)
        .onAppear { list = ed.bookmarks() }
    }
}

struct IndexMarkSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var main = ""
    @State private var sub = ""
    @State private var all = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mark Index Entry").font(.headline)
            TextField("Main entry", text: $main).textFieldStyle(.roundedBorder)
            TextField("Subentry (optional)", text: $sub).textFieldStyle(.roundedBorder)
            Toggle("Mark every occurrence of the main entry", isOn: $all)
            HStack {
                Button("Clear All Marks") { ed.clearIndexMarks(); ed.showIndexMark = false }
                Spacer()
                Button("Cancel") { ed.showIndexMark = false }.keyboardShortcut(.cancelAction)
                Button("Mark") { ed.markIndexEntry(main: main, sub: sub, all: all); ed.showIndexMark = false }
                    .keyboardShortcut(.defaultAction).disabled(main.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear {
            if let tv = ed.bodyTextView, tv.selectedRange().length > 0 { main = (tv.string as NSString).substring(with: tv.selectedRange()) }
        }
    }
}

struct ControlPropsSheet: View {
    @EnvironmentObject var ed: EditorController
    @State var draft: ControlProps
    @State private var optionsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Content Control Properties").font(.headline)
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            if draft.kind != "checkbox" { TextField("Placeholder text", text: $draft.placeholder).textFieldStyle(.roundedBorder) }
            if draft.kind == "dropdown" {
                Text("List items (one per line)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $optionsText).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            }
            HStack {
                Spacer()
                Button("Cancel") { ed.controlDraft = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    var d = draft
                    if d.kind == "dropdown" { d.options = optionsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ed.applyControlProperties(d)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { optionsText = draft.options.joined(separator: "\n") }
    }
}

struct MergeDataSheet: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mail Merge Recipients").font(.headline)
            if let d = ed.meta.mergeData {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow { ForEach(d.columns, id: \.self) { Text($0).bold() } }
                        Divider()
                        ForEach(Array(d.rows.prefix(200).enumerated()), id: \.offset) { _, row in
                            GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, v in Text(v).lineLimit(1) } }
                        }
                    }.padding(8)
                }.frame(height: 260).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("\(d.rows.count) recipients, \(d.columns.count) fields").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose Another File…") { ed.showMergeData = false; ed.importMergeData() }
                Spacer()
                Button("Close") { ed.showMergeData = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
    }
}

struct SaveTemplateSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var name = "My Template"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save as Template").font(.headline)
            TextField("Template name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { ed.showSaveTemplate = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let doc = ed.document { TemplateLibrary.saveUserTemplate(name: name, from: doc) }
                    ed.showSaveTemplate = false
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
    }
}

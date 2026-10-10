import SwiftUI

@main
struct WordMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { RichTextDocument() }) { file in
            DocumentWindow(document: file.document, fileURL: file.fileURL)
        }
        .defaultLaunchBehavior(.suppressed)          // no file-open panel at launch: the start screen takes its place
        .commands { WordCommands(); ToolMenus() }
        Window("WordCraft", id: "start") { StartView() }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.presented)
        Settings { SettingsView() }
    }
}

struct DocumentWindow: View {
    @ObservedObject var document: RichTextDocument
    var fileURL: URL?
    @StateObject private var editor = EditorController()
    @SceneStorage("zoom") private var savedZoom = 1.0
    @SceneStorage("showNav") private var savedNav = false
    @SceneStorage("showReview") private var savedReview = false

    var body: some View {
        VStack(spacing: 0) {
            if !editor.focusMode {
                RibbonView()
                Divider()
            }
            HStack(spacing: 0) {
                if editor.showNav && !editor.focusMode {
                    NavPane()
                    Divider()
                }
                EditorView(document: document, controller: editor)
                    .accessibilityLabel("Document pages")
                if editor.showReview && !editor.focusMode {
                    Divider()
                    ReviewPane()
                }
            }
            if !editor.focusMode {
                Divider()
                StatusBar()
            }
        }
        .overlay(alignment: .topTrailing) {
            if editor.focusMode {
                Button { editor.focusMode = false } label: { Label("Exit Focus Mode", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.borderedProminent).controlSize(.small).padding(10).opacity(0.85)
            }
        }
        .environmentObject(editor)
        .focusedSceneObject(editor)
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            if let fileURL { RecentStore.note(fileURL) }
            editor.showNav = savedNav
            editor.showReview = savedReview
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if abs(savedZoom - 1) > 0.01 { editor.setZoom(CGFloat(savedZoom)) } }
        }
        .onChange(of: fileURL) { _, u in if let u { RecentStore.note(u) } }
        .onChange(of: editor.zoom) { _, z in savedZoom = Double(z) }
        .onChange(of: editor.showNav) { _, v in savedNav = v }
        .onChange(of: editor.showReview) { _, v in savedReview = v }
        .touchBar {
            Group {
                Button { editor.toggleBold() } label: { Image(systemName: "bold") }
                Button { editor.toggleItalic() } label: { Image(systemName: "italic") }
                Button { editor.toggleUnderline() } label: { Image(systemName: "underline") }
                Button { editor.setAlignment(.left) } label: { Image(systemName: "text.alignleft") }
                Button { editor.setAlignment(.center) } label: { Image(systemName: "text.aligncenter") }
            }
            Group {
                Button { editor.setAlignment(.right) } label: { Image(systemName: "text.alignright") }
                Button { editor.toggleList(.bullet) } label: { Image(systemName: "list.bullet") }
                Button("H1") { editor.applyStyle("h1") }
                Button("H2") { editor.applyStyle("h2") }
                Button("Normal") { editor.applyStyle("normal") }
            }
        }
        .sheet(isPresented: $editor.showHeaderFooter) {
            HeaderFooterSheet().environmentObject(editor)
        }
        .sheet(isPresented: $editor.showSources) { SourcesSheet().environmentObject(editor) }
        .sheet(isPresented: $editor.showXref) { CrossRefSheet().environmentObject(editor) }
        .sheet(isPresented: $editor.showBookmark) { BookmarkSheet().environmentObject(editor) }
        .sheet(isPresented: $editor.showIndexMark) { IndexMarkSheet().environmentObject(editor) }
        .sheet(isPresented: $editor.showMergeData) { MergeDataSheet().environmentObject(editor) }
        .sheet(isPresented: $editor.showSaveTemplate) { SaveTemplateSheet().environmentObject(editor) }
        .sheet(item: $editor.controlDraft) { d in ControlPropsSheet(draft: d).environmentObject(editor) }
        .sheet(isPresented: $editor.showRestrict) { RestrictSheet().environmentObject(editor) }
        .sheet(isPresented: $editor.showWordCount) { WordCountSheet().environmentObject(editor) }
        .sheet(item: $editor.thesaurus) { d in ThesaurusSheet(draft: d).environmentObject(editor) }
        .sheet(item: $editor.equationDraft) { d in
            EquationSheet(draft: d).environmentObject(editor)
        }
        .sheet(item: $editor.linkDraft) { d in
            LinkSheet(draft: d).environmentObject(editor)
        }
        .sheet(isPresented: $editor.showFormula) {
            FormulaSheet().environmentObject(editor)
        }
        .sheet(isPresented: $editor.showTableSize) {
            TableSizeSheet().environmentObject(editor)
        }
        .sheet(isPresented: $editor.showNotes) {
            NotesSheet().environmentObject(editor)
        }
        .sheet(item: $editor.editingStyle) { def in
            StyleEditorSheet(def: def, isNew: editor.isNewStyle).environmentObject(editor)
        }
        #if DEBUG
        .onAppear {
            if let spec = ProcessInfo.processInfo.environment["WORDMAC_LAYOUT"] {
                // "cols,landscape" e.g. "2,1"
                let p = spec.split(separator: ",").map { Int($0) ?? 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    editor.updateLayout("Test") {
                        $0.columns = max(1, p.first ?? 1)
                        $0.landscape = p.count > 1 && p[1] == 1
                        $0.header.left = "WordCraft Test"
                        $0.footer.center = "Page {page} of {pages}"
                    }
                }
            }
            if let n = ProcessInfo.processInfo.environment["WORDMAC_SCENARIO"] { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { DebugScenario.run(editor, name: n) } }
            if ProcessInfo.processInfo.environment["WORDMAC_BREAK"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { editor.insertPageBreak() }
            }
            if ProcessInfo.processInfo.environment["WORDMAC_PDF"] != nil {
                let path = NSTemporaryDirectory() + "out-\(document.storage.length).pdf"
                print("PDF:", path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    editor.writePDF(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
        }
        #endif
    }
}

struct WordCommands: Commands {
    @FocusedObject private var editor: EditorController?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New from Template…") { StartState.shared.openWindow = { openWindow(id: "start") }; StartState.shared.show(tab: .new) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Start Screen") { StartState.shared.openWindow = { openWindow(id: "start") }; StartState.shared.show() }
            Button("Save as Template…") { editor?.showSaveTemplate = true }
        }
        CommandGroup(after: .importExport) {
            Menu("Export As") {
                Button("Word Document (.docx)…") { editor?.exportDocx() }
                Button("PDF…") { editor?.exportPDF() }
                Button("Rich Text (.rtf)…") { editor?.exportRTF() }
                Button("Web Page (.html)…") { editor?.exportHTML() }
                Button("Plain Text (.txt)…") { editor?.exportText() }
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { editor?.printDocument() }.keyboardShortcut("p")
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { editor?.showFind(replace: false) }.keyboardShortcut("f")
            Button("Find and Replace…") { editor?.showFind(replace: true) }.keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandMenu("Insert") {
            Button("Page Break") { editor?.insertPageBreak() }.keyboardShortcut(.return, modifiers: .command)
            Button("Column Break") { editor?.insertColumnBreak() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Header & Footer…") { editor?.showHeaderFooter = true }
            Button("Section Break") { editor?.insertSectionBreak() }
            Divider()
            Button("Hyperlink…") { editor?.startLink() }.keyboardShortcut("k")
            Button("Picture…") { editor?.insertPictureFromPanel() }
            Button("Equation…") { editor?.startEquation() }.keyboardShortcut("=", modifiers: [.command, .control])
            Button("Table…") { editor?.showTableSize = true }
            Button("Table of Contents") { editor?.insertTableOfContents() }
            Button("Update All Fields") { editor?.updateAllFields() }.keyboardShortcut(.init("u"), modifiers: [.command, .option, .shift])
            Button("Footnote") { editor?.insertNote(endnote: false) }.keyboardShortcut("f", modifiers: [.command, .option, .shift])
            Button("Endnote") { editor?.insertNote(endnote: true) }
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Navigation Pane") { editor?.showNav.toggle() }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("Review Pane") { editor?.showReview.toggle() }
            Button("Ruler") { editor?.rulerVisible.toggle() }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("Focus Mode") { editor?.focusMode.toggle() }.keyboardShortcut("f", modifiers: [.command, .control, .option])
        }
        CommandMenu("Format") {
            Button("Bold") { editor?.toggleBold() }.keyboardShortcut("b")
            Button("Italic") { editor?.toggleItalic() }.keyboardShortcut("i")
            Button("Underline") { editor?.toggleUnderline() }.keyboardShortcut("u")
            Button("Strikethrough") { editor?.toggleStrike() }.keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Button("Increase Font Size") { editor?.stepSize(1) }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Decrease Font Size") { editor?.stepSize(-1) }.keyboardShortcut(",", modifiers: [.command, .shift])
            Divider()
            Button("Align Left") { editor?.setAlignment(.left) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Center") { editor?.setAlignment(.center) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Align Right") { editor?.setAlignment(.right) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Justify") { editor?.setAlignment(.justified) }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Bulleted List") { editor?.toggleList(.bullet) }.keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { editor?.toggleList(.numbered) }.keyboardShortcut("7", modifiers: [.command, .shift])
            Divider()
            Button("Left-to-Right") { editor?.setDirection(rtl: false) }.keyboardShortcut(.rightArrow, modifiers: [.control, .shift])
            Button("Right-to-Left") { editor?.setDirection(rtl: true) }.keyboardShortcut(.leftArrow, modifiers: [.control, .shift])
            Divider()
            Button("Clear Formatting") { editor?.clearFormatting() }
            Divider()
            Button("Normal") { editor?.applyStyle("normal") }.keyboardShortcut("0", modifiers: [.command, .option])
            ForEach(1...3, id: \.self) { n in
                Button("Heading \(n)") { editor?.applyStyle("h\(n)") }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { if let e = editor { e.setZoom(e.zoom + 0.1) } }.keyboardShortcut("+", modifiers: [.command, .option])
            Button("Zoom Out") { if let e = editor { e.setZoom(e.zoom - 0.1) } }.keyboardShortcut("-", modifiers: [.command, .option])
            Button("Actual Size") { editor?.setZoom(1) }.keyboardShortcut("0", modifiers: [.command, .control])
        }
    }
}

/// Table, References, Mailings and Review menus (split out because a Commands body holds at most ten items).
struct ToolMenus: Commands {
    @FocusedObject private var editor: EditorController?

    var body: some Commands {
        CommandMenu("Table") {
            Button("Insert Row Above") { editor?.tableInsertRow(below: false) }
            Button("Insert Row Below") { editor?.tableInsertRow(below: true) }
            Button("Insert Column Left") { editor?.tableInsertColumn(right: false) }
            Button("Insert Column Right") { editor?.tableInsertColumn(right: true) }
            Divider()
            Button("Delete Row") { editor?.tableDeleteRow() }
            Button("Delete Column") { editor?.tableDeleteColumn() }
            Button("Delete Table") { editor?.tableDelete() }
            Divider()
            Button("Merge Cells") { editor?.tableMerge() }
            Button("Split Cell") { editor?.tableSplit() }
            Button("Header Row") { editor?.tableToggleHeader() }
            Divider()
            Button("Formula…") { editor?.showFormula = true }
            Button("Recalculate") { editor?.recalculateTables() }
        }
        CommandMenu("References") {
            Button("Footnote") { editor?.insertNote(endnote: false) }
            Button("Endnote") { editor?.insertNote(endnote: true) }
            Divider()
            Button("Manage Sources…") { editor?.showSources = true }
            Button("Bibliography") { editor?.insertBibliography() }
            Divider()
            Button("Insert Caption") { editor?.insertCaption(label: "Figure") }
            Button("Cross-reference…") { editor?.showXref = true }
            Button("Bookmarks…") { editor?.showBookmark = true }
            Divider()
            Button("Mark Index Entry…") { editor?.showIndexMark = true }
            Button("Insert Index") { editor?.insertIndex() }
        }
        CommandMenu("Mailings") {
            Button("Select Recipients…") { editor?.importMergeData() }
            Button("Preview Results") { if let e = editor { e.previewMerge(e.mergePreviewing ? nil : e.mergeIndex) } }
            Button("Next Record") { editor?.stepMerge(1) }
            Button("Previous Record") { editor?.stepMerge(-1) }
            Divider()
            Button("Finish & Merge") { editor?.finishMerge() }
        }
        CommandMenu("Review") {
            Button("Track Changes") { editor?.toggleTracking() }.keyboardShortcut("e", modifiers: [.command, .shift, .option])
            Button("New Comment") { editor?.addComment() }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("Next Change") { editor?.goToRevision(next: true) }
            Button("Previous Change") { editor?.goToRevision(next: false) }
            Divider()
            Button("Accept All Changes") { editor?.acceptAll() }
            Button("Reject All Changes") { editor?.rejectAll() }
            Divider()
            Button("Spelling and Grammar…") { editor?.showSpellingPanel() }.keyboardShortcut(";", modifiers: [.command, .shift])
            Button("Thesaurus…") { editor?.startThesaurus() }.keyboardShortcut("r", modifiers: [.command, .option, .shift])
            Button("Word Count…") { editor?.showWordCount = true }.keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }
}

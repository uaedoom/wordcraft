import SwiftUI
import AppKit

// MARK: - Building blocks

struct RibbonButton: View {
    let symbol: String
    let help: String
    var active = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Color.accentColor.opacity(0.28) : (hover ? Color.primary.opacity(0.08) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(LocalizedStringKey(help))
        .accessibilityLabel(LocalizedStringKey(help))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct RibbonBigButton: View {
    let symbol: String
    let title: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular))
                Text(LocalizedStringKey(title)).font(.caption)
            }
            .frame(width: 48, height: 54)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                content.frame(height: 56)
                Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            Divider().padding(.vertical, 4)
        }
    }
}

struct TabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
    }
}

// MARK: - Ribbon

struct RibbonView: View {
    @EnvironmentObject var ed: EditorController
    enum Tab: String, CaseIterable { case home = "Home", insert = "Insert", object = "Picture", table = "Table", layout = "Layout", references = "References", review = "Review", mailings = "Mailings", view = "View" }
    @SceneStorage("ribbonTab") private var tabRaw = "Home"
    private var tab: Tab {
        get { Tab(rawValue: tabRaw) ?? .home }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button(LocalizedStringKey(t.rawValue)) { tab = t }.buttonStyle(TabStyle(selected: tab == t))
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    switch tab {
                    case .home: HomeRibbon()
                    case .insert: InsertRibbon()
                    case .object: ObjectRibbon()
                    case .table: TableRibbon()
                    case .layout: LayoutRibbon()
                    case .references: ReferencesRibbon()
                    case .review: ReviewRibbon()
                    case .mailings: MailingsRibbon()
                    case .view: ViewRibbon()
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
            }
            .frame(height: 96)
        }
        .background(.bar)
    }
}

struct HomeRibbon: View {
    @EnvironmentObject var ed: EditorController

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()
    private static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]
    private static let highlights: [(String, NSColor?)] = [
        ("Yellow", .yellow), ("Green", .green), ("Cyan", .cyan), ("Pink", .systemPink),
        ("Orange", .orange), ("None", nil)]

    private var familyChoices: [String] {
        Self.families.contains(ed.format.fontFamily) ? Self.families : [ed.format.fontFamily] + Self.families
    }
    private var sizeChoices: [CGFloat] {
        Self.sizes.contains(ed.format.fontSize) ? Self.sizes : (Self.sizes + [ed.format.fontSize]).sorted()
    }

    var body: some View {
        let f = ed.format

        RibbonGroup(title: "Clipboard") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "doc.on.clipboard", title: "Paste") { ed.paste() }
                VStack(spacing: 2) {
                    RibbonButton(symbol: "scissors", help: "Cut (⌘X)") { ed.cut() }
                    RibbonButton(symbol: "doc.on.doc", help: "Copy (⌘C)") { ed.copy() }
                }
                VStack(spacing: 2) {
                    RibbonButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { ed.undo() }
                    RibbonButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { ed.redo() }
                }
            }
        }

        RibbonGroup(title: "Font") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Picker("", selection: Binding(get: { f.fontFamily }, set: { ed.setFamily($0) })) {
                        ForEach(familyChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                    Picker("", selection: Binding(get: { f.fontSize }, set: { ed.setSize($0) })) {
                        ForEach(sizeChoices, id: \.self) { Text(String(format: "%g", $0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 62)
                    RibbonButton(symbol: "textformat.size.larger", help: "Increase Font Size") { ed.stepSize(1) }
                    RibbonButton(symbol: "textformat.size.smaller", help: "Decrease Font Size") { ed.stepSize(-1) }
                }
                HStack(spacing: 2) {
                    RibbonButton(symbol: "bold", help: "Bold (⌘B)", active: f.bold) { ed.toggleBold() }
                    RibbonButton(symbol: "italic", help: "Italic (⌘I)", active: f.italic) { ed.toggleItalic() }
                    RibbonButton(symbol: "underline", help: "Underline (⌘U)", active: f.underline) { ed.toggleUnderline() }
                    RibbonButton(symbol: "strikethrough", help: "Strikethrough", active: f.strike) { ed.toggleStrike() }
                    RibbonButton(symbol: "textformat.subscript", help: "Subscript", active: f.subscriptOn) { ed.toggleSubscript() }
                    RibbonButton(symbol: "textformat.superscript", help: "Superscript", active: f.superscript) { ed.toggleSuperscript() }
                    Divider().frame(height: 18)
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: f.textColor) },
                        set: { ed.setTextColor(NSColor($0)) }), supportsOpacity: false)
                        .labelsHidden().help("Font Color")
                    Menu {
                        ForEach(Self.highlights, id: \.0) { name, color in
                            Button(name) { ed.setHighlight(color) }
                        }
                    } label: {
                        Image(systemName: "highlighter")
                    }
                    .menuStyle(.borderlessButton).frame(width: 36).help("Text Highlight Color")
                    RibbonButton(symbol: "eraser", help: "Clear Formatting") { ed.clearFormatting() }
                }
            }
        }

        RibbonGroup(title: "Paragraph") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    RibbonButton(symbol: "list.bullet", help: "Bullets", active: f.list == .bullet) { ed.toggleList(.bullet) }
                    RibbonButton(symbol: "list.number", help: "Numbering", active: f.list == .numbered) { ed.toggleList(.numbered) }
                    RibbonButton(symbol: "decrease.indent", help: "Decrease Indent") { ed.indent(-36) }
                    RibbonButton(symbol: "increase.indent", help: "Increase Indent") { ed.indent(36) }
                    Menu {
                        ForEach([1.0, 1.15, 1.5, 2.0, 2.5, 3.0], id: \.self) { v in
                            Button((f.lineSpacing == v ? "✓ " : "") + String(format: "%g", v)) { ed.setLineSpacing(v) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.and.down.text.horizontal")
                    }
                    .menuStyle(.borderlessButton).frame(width: 36).help("Line Spacing")
                }
                HStack(spacing: 2) {
                    RibbonButton(symbol: "text.alignleft", help: "Align Left", active: f.alignment == .left) { ed.setAlignment(.left) }
                    RibbonButton(symbol: "text.aligncenter", help: "Center", active: f.alignment == .center) { ed.setAlignment(.center) }
                    RibbonButton(symbol: "text.alignright", help: "Align Right", active: f.alignment == .right) { ed.setAlignment(.right) }
                    RibbonButton(symbol: "text.justify", help: "Justify", active: f.alignment == .justified) { ed.setAlignment(.justified) }
                    Divider().frame(height: 18)
                    RibbonButton(symbol: "arrow.right", help: "Left-to-Right", active: !f.rtl) { ed.setDirection(rtl: false) }
                    RibbonButton(symbol: "arrow.left", help: "Right-to-Left", active: f.rtl) { ed.setDirection(rtl: true) }
                }
            }
        }

        RibbonGroup(title: "Styles") {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(ed.styles.filter { $0.gallery }) { st in StyleTile(style: st) }
                    }
                }
                .frame(width: 340)
                Menu {
                    Button("Modify \"\(ed.style(ed.format.styleID)?.name ?? "Normal")\"…") { ed.editStyle(ed.format.styleID) }
                    Button("Update \"\(ed.style(ed.format.styleID)?.name ?? "Normal")\" to Match Selection") { ed.updateStyleToMatchSelection() }
                    Button("New Style from Selection…") { ed.newStyleFromSelection() }
                    if ed.style(ed.format.styleID)?.builtin == false {
                        Divider()
                        Button("Delete \"\(ed.style(ed.format.styleID)?.name ?? "")\"") { ed.deleteStyle(ed.format.styleID) }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton).frame(width: 34).help("Style options")
            }
        }

        RibbonGroup(title: "Editing") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "magnifyingglass", title: "Find") { ed.showFind(replace: false) }
                RibbonBigButton(symbol: "arrow.left.arrow.right", title: "Replace") { ed.showFind(replace: true) }
                RibbonBigButton(symbol: "character.textbox", title: "Select All") { ed.selectAll() }
            }
        }
    }
}

struct StyleTile: View {
    @EnvironmentObject var ed: EditorController
    let style: StyleDef
    @State private var hover = false

    var body: some View {
        let active = ed.format.styleID == style.id
        Button { ed.applyStyle(style.id) } label: {
            VStack(spacing: 2) {
                Text("AaBb")
                    .font(.system(size: min(style.size, 20), weight: style.bold ? .bold : .regular))
                    .italic(style.italic)
                    .foregroundStyle(style.color == [0, 0, 0] ? Color.primary : Color(nsColor: style.nsColor))
                Text(LocalizedStringKey(style.name)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 68, height: 52)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? Color.accentColor.opacity(0.25) : (hover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor : Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct InsertRibbon: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        RibbonGroup(title: "Pages") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "doc.badge.plus", title: "Page Break") { ed.insertPageBreak() }
                RibbonBigButton(symbol: "rectangle.split.2x1", title: "Col. Break") { ed.insertColumnBreak() }
                RibbonBigButton(symbol: "square.split.1x2", title: "Section") { ed.insertSectionBreak() }
            }
        }
        RibbonGroup(title: "Illustrations") {
            HStack(spacing: 4) {
                Menu {
                    Button("In Line with Text…") { ed.insertPictureFromPanel() }
                    Button("Floating – Square Wrap…") { ed.insertFloatingPicture(wrap: .square) }
                    Button("Floating – Behind Text…") { ed.insertFloatingPicture(wrap: .behind) }
                    Button("Floating – In Front of Text…") { ed.insertFloatingPicture(wrap: .front) }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "photo").font(.system(size: 22)); Text("Picture").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 56, height: 54)
                Menu {
                    ForEach(ShapeKind.allCases) { k in Button { ed.insertShape(k) } label: { Label(k.title, systemImage: k.symbol) } }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "square.on.circle").font(.system(size: 22)); Text("Shapes").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 56, height: 54)
                RibbonBigButton(symbol: "textbox", title: "Text Box") { ed.insertTextBox() }
                RibbonBigButton(symbol: "x.squareroot", title: "Equation") { ed.startEquation() }
            }
        }
        RibbonGroup(title: "Tables") {
            Menu {
                ForEach(Array([(2, 2), (3, 3), (4, 4), (5, 5), (3, 2), (2, 3), (4, 3), (6, 4)].enumerated()), id: \.offset) { _, rc in
                    Button("\(rc.0) × \(rc.1) table") { ed.insertTable(rows: rc.0, cols: rc.1) }
                }
                Divider()
                Button("Custom Size…") { ed.showTableSize = true }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "tablecells").font(.system(size: 22))
                    Text("Table").font(.caption)
                }
            }
            .menuStyle(.borderlessButton).frame(width: 56, height: 54)
        }
        RibbonGroup(title: "Links & Symbols") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "link", title: "Link") { ed.startLink() }
                if ed.format.link != nil {
                    RibbonBigButton(symbol: "link.badge.plus", title: "Unlink") { ed.removeLink() }
                }
                Menu {
                    ForEach(SymbolGroup.all) { g in
                        Menu(g.name) {
                            ForEach(g.items, id: \.self) { sym in Button(sym) { ed.insertSymbol(sym) } }
                        }
                    }
                    Divider()
                    Button("Character Viewer…") { ed.showCharacterViewer() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "omega").font(.system(size: 22))
                        Text("Symbol").font(.caption)
                    }
                }
                .menuStyle(.borderlessButton).frame(width: 56, height: 54)
            }
        }
        FormsGroup()
        RibbonGroup(title: "Header & Footer") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "rectangle.tophalf.inset.filled", title: "Header & Footer") { ed.showHeaderFooter = true }
                    .frame(width: 80)
                Menu {
                    Menu("Top of Page") {
                        Button("Left") { ed.setPageNumber(.headerLeft) }
                        Button("Center") { ed.setPageNumber(.headerCenter) }
                        Button("Right") { ed.setPageNumber(.headerRight) }
                    }
                    Menu("Bottom of Page") {
                        Button("Left") { ed.setPageNumber(.footerLeft) }
                        Button("Center") { ed.setPageNumber(.footerCenter) }
                        Button("Right") { ed.setPageNumber(.footerRight) }
                    }
                    Divider()
                    Button("Remove Page Numbers") { ed.setPageNumber(.none) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "number.square").font(.system(size: 22))
                        Text("Page Number").font(.caption)
                    }
                }
                .menuStyle(.borderlessButton).frame(width: 84, height: 54)
            }
        }
    }
}

struct InchStepper: View {
    let title: String
    let value: CGFloat
    var range: ClosedRange<CGFloat> = 0...4
    let set: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.caption).frame(width: 50, alignment: .trailing)
            Text(String(format: "%.2f\"", value / 72)).font(.caption).monospacedDigit().frame(width: 40)
            Stepper("", onIncrement: { set(min(range.upperBound * 72, value + 18)) },
                    onDecrement: { set(max(range.lowerBound * 72, value - 18)) })
                .labelsHidden()
        }
    }
}

struct PointStepper: View {
    let title: String
    let value: CGFloat
    var step: CGFloat = 6
    let set: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.caption).frame(width: 64, alignment: .trailing)
            Text(String(format: "%g pt", value)).font(.caption).monospacedDigit().frame(width: 44)
            Stepper("", onIncrement: { set(value + step) }, onDecrement: { set(value - step) }).labelsHidden()
        }
    }
}

struct LayoutRibbon: View {
    @EnvironmentObject var ed: EditorController

    private func menuLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 22))
            Text(LocalizedStringKey(title)).font(.caption)
        }
    }

    var body: some View {
        let l = ed.layout
        RibbonGroup(title: "Page Setup") {
            HStack(spacing: 6) {
                Menu {
                    Button("Normal (1\")") { ed.setMargins(top: 72, bottom: 72, left: 72, right: 72) }
                    Button("Narrow (0.5\")") { ed.setMargins(top: 36, bottom: 36, left: 36, right: 36) }
                    Button("Moderate") { ed.setMargins(top: 72, bottom: 72, left: 54, right: 54) }
                    Button("Wide") { ed.setMargins(top: 72, bottom: 72, left: 144, right: 144) }
                } label: { menuLabel("square.dashed.inset.filled", "Margins") }
                .menuStyle(.borderlessButton).frame(width: 64, height: 54)

                Menu {
                    Button((!l.landscape ? "✓ " : "") + "Portrait") { ed.updateLayout("Orientation") { $0.landscape = false } }
                    Button((l.landscape ? "✓ " : "") + "Landscape") { ed.updateLayout("Orientation") { $0.landscape = true } }
                } label: { menuLabel("rectangle.portrait.rotate", "Orientation") }
                .menuStyle(.borderlessButton).frame(width: 78, height: 54)

                Menu {
                    ForEach(PaperSize.all) { p in
                        Button((l.paperName == p.name ? "✓ " : "") + p.name) { ed.setPaper(p) }
                    }
                } label: { menuLabel("doc", "Size: " + l.paperName) }
                .menuStyle(.borderlessButton).frame(width: 90, height: 54)

                Menu {
                    ForEach(1...4, id: \.self) { n in
                        Button((l.columns == n ? "✓ " : "") + (n == 1 ? "One" : "\(n) Columns")) {
                            ed.updateLayout("Columns") { $0.columns = n }
                        }
                    }
                } label: { menuLabel("rectangle.split.3x1", "Columns") }
                .menuStyle(.borderlessButton).frame(width: 64, height: 54)

                Menu {
                    Button("Page Break") { ed.insertPageBreak() }
                    Button("Column Break") { ed.insertColumnBreak() }
                    Divider()
                    Button("Section Break (Next Page)") { ed.insertSectionBreak() }
                } label: { menuLabel("scissors", "Breaks") }
                .menuStyle(.borderlessButton).frame(width: 52, height: 54)
            }
        }
        RibbonGroup(title: "Margins") {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    InchStepper(title: "Top", value: l.top) { v in ed.updateLayout("Margins") { $0.top = v } }
                    InchStepper(title: "Bottom", value: l.bottom) { v in ed.updateLayout("Margins") { $0.bottom = v } }
                }
                VStack(alignment: .trailing, spacing: 2) {
                    InchStepper(title: "Left", value: l.left) { v in ed.updateLayout("Margins") { $0.left = v } }
                    InchStepper(title: "Right", value: l.right) { v in ed.updateLayout("Margins") { $0.right = v } }
                }
            }
        }
        RibbonGroup(title: "Paragraph") {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    InchStepper(title: "Left", value: ed.format.leftIndent) { ed.setLeftIndent($0) }
                    InchStepper(title: "Right", value: ed.format.rightIndent) { ed.setRightIndent($0) }
                }
                VStack(alignment: .trailing, spacing: 2) {
                    PointStepper(title: "Before", value: ed.format.spaceBefore) { ed.setSpaceBefore($0) }
                    PointStepper(title: "After", value: ed.format.spaceAfter) { ed.setSpaceAfter($0) }
                }
            }
        }
    }
}

struct HeaderFooterSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var header = HeaderFooter()
    @State private var footer = HeaderFooter()
    @State private var headerDistance: CGFloat = 36
    @State private var footerDistance: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Header & Footer").font(.headline)
            Text("Use {page} for the page number and {pages} for the total page count.")
                .font(.caption).foregroundStyle(.secondary)
            section("Header", $header)
            section("Footer", $footer)
            HStack {
                Button("Page X of Y") { footer.center = "Page {page} of {pages}" }
                Spacer()
                Button("Cancel") { ed.showHeaderFooter = false }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    ed.updateLayout("Header & Footer") { $0.header = header; $0.footer = footer }
                    ed.showHeaderFooter = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { header = ed.layout.header; footer = ed.layout.footer }
    }

    private func section(_ title: String, _ hf: Binding<HeaderFooter>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold))
            HStack {
                TextField("Left", text: hf.left)
                TextField("Center", text: hf.center)
                TextField("Right", text: hf.right)
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

struct ReferencesRibbon: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        RibbonGroup(title: "Table of Contents") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "list.bullet.indent", title: ed.hasTOC ? "Update" : "Insert") { ed.insertTableOfContents() }
                if ed.hasTOC {
                    RibbonBigButton(symbol: "trash", title: "Remove") { ed.removeTableOfContents() }
                }
            }
        }
        RibbonGroup(title: "Footnotes") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "text.append", title: "Footnote") { ed.insertNote(endnote: false) }
                RibbonBigButton(symbol: "text.insert", title: "Endnote") { ed.insertNote(endnote: true) }
                RibbonBigButton(symbol: "list.number", title: "Edit Notes") { ed.showNotes = true }
                    .frame(width: 64)
            }
        }
        ReferencesExtras()
    }
}

struct StyleEditorSheet: View {
    @EnvironmentObject var ed: EditorController
    @State var def: StyleDef
    let isNew: Bool
    private static let families = NSFontManager.shared.availableFontFamilies.sorted()

    private func number(_ title: String, _ v: Binding<CGFloat>, step: CGFloat = 1, range: ClosedRange<CGFloat> = 0...400) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).frame(width: 110, alignment: .leading)
            Text(String(format: "%g", v.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
            Stepper("", value: v, in: range, step: step).labelsHidden()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New Style" : "Modify Style").font(.headline)
            HStack {
                Text("Name").frame(width: 110, alignment: .leading)
                TextField("Name", text: $def.name).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Font").frame(width: 110, alignment: .leading)
                Picker("", selection: $def.family) {
                    ForEach(Self.families.contains(def.family) ? Self.families : [def.family] + Self.families, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            number("Size", $def.size, range: 6...120)
            HStack {
                Text("Format").frame(width: 110, alignment: .leading)
                Toggle("Bold", isOn: $def.bold)
                Toggle("Italic", isOn: $def.italic)
                Toggle("Underline", isOn: $def.underline)
                ColorPicker("", selection: Binding(get: { Color(nsColor: def.nsColor) },
                                                    set: { def.nsColor = NSColor($0) }), supportsOpacity: false).labelsHidden()
            }
            HStack {
                Text("Alignment").frame(width: 110, alignment: .leading)
                Picker("", selection: $def.alignment) {
                    Text("Left").tag(0); Text("Center").tag(2); Text("Right").tag(1); Text("Justify").tag(3)
                }.pickerStyle(.segmented).labelsHidden()
            }
            number("Space before (pt)", $def.spaceBefore, step: 2)
            number("Space after (pt)", $def.spaceAfter, step: 2)
            number("Line spacing", $def.lineMultiple, step: 0.05, range: 0.8...4)
            number("Left indent (pt)", $def.leftIndent, step: 6)
            number("Right indent (pt)", $def.rightIndent, step: 6)
            HStack {
                Text("Outline level").frame(width: 110, alignment: .leading)
                Picker("", selection: $def.outline) {
                    Text("Body text").tag(0)
                    ForEach(1...6, id: \.self) { Text("Level \($0)").tag($0) }
                }.labelsHidden()
            }
            HStack {
                Text("Next paragraph").frame(width: 110, alignment: .leading)
                Picker("", selection: $def.next) {
                    ForEach(ed.styles) { Text($0.name).tag($0.id) }
                    if isNew { Text(def.name).tag(def.id) }
                }.labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel") { ed.editingStyle = nil }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Done") { ed.commitStyle(def) }.keyboardShortcut(.defaultAction)
                    .disabled(def.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 440)
    }
}

struct NotesSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var notes: [String: String] = [:]
    @State private var entries: [NoteEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Footnotes & Endnotes").font(.headline)
            if entries.isEmpty {
                Text("No notes yet. Use References › Footnote or Endnote to add one at the caret.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { e in
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                TextField("Note text", text: Binding(get: { notes[e.id] ?? "" }, set: { notes[e.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                Button { ed.deleteNote(e.id); entries.removeAll { $0.id == e.id } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(maxHeight: 300)
            }
            HStack {
                Spacer()
                Button("Cancel") { ed.showNotes = false }.keyboardShortcut(.cancelAction)
                Button("Done") { ed.setNotes(notes.merging(ed.meta.notes.filter { notes[$0.key] == nil }) { a, _ in a }); ed.showNotes = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { notes = ed.meta.notes; entries = ed.noteEntries() }
    }
}

struct NavPane: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Navigation").font(.headline).padding(10)
            Divider()
            if ed.outline.isEmpty {
                Text("Apply Heading styles (Home › Styles) and your outline appears here.")
                    .font(.callout).foregroundStyle(.secondary).padding(12)
                Spacer()
            } else {
                List(ed.outline) { h in
                    Button { ed.go(to: h.loc) } label: {
                        Text(h.title)
                            .font(.system(size: 12, weight: h.level == 1 ? .semibold : .regular))
                            .lineLimit(2)
                            .padding(.leading, CGFloat(h.level - 1) * 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 230)
        .background(.bar)
    }
}

struct TableRibbon: View {
    @EnvironmentObject var ed: EditorController
    @State private var borderWidth: CGFloat = 0.5
    @State private var borderColor = Color(white: 0.45)
    @State private var shade = Color.yellow.opacity(0.35)

    var body: some View {
        let on = ed.format.inTable
        Group {
            RibbonGroup(title: "Rows & Columns") {
                HStack(spacing: 4) {
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            RibbonButton(symbol: "arrow.up.to.line", help: "Insert Row Above") { ed.tableInsertRow(below: false) }
                            RibbonButton(symbol: "arrow.down.to.line", help: "Insert Row Below") { ed.tableInsertRow(below: true) }
                            RibbonButton(symbol: "arrow.left.to.line", help: "Insert Column Left") { ed.tableInsertColumn(right: false) }
                            RibbonButton(symbol: "arrow.right.to.line", help: "Insert Column Right") { ed.tableInsertColumn(right: true) }
                        }
                        HStack(spacing: 2) {
                            RibbonButton(symbol: "minus.rectangle", help: "Delete Row") { ed.tableDeleteRow() }
                            RibbonButton(symbol: "rectangle.split.1x2", help: "Delete Column") { ed.tableDeleteColumn() }
                            RibbonButton(symbol: "trash", help: "Delete Table") { ed.tableDelete() }
                        }
                    }
                }
            }
            RibbonGroup(title: "Merge") {
                HStack(spacing: 4) {
                    RibbonBigButton(symbol: "rectangle.compress.vertical", title: "Merge") { ed.tableMerge() }
                    RibbonBigButton(symbol: "rectangle.expand.vertical", title: "Split") { ed.tableSplit() }
                }
            }
            RibbonGroup(title: "Borders & Shading") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Menu {
                            Button("All Borders") { ed.tableBorders(.all) }
                            Button("Outside Borders") { ed.tableBorders(.outside) }
                            Button("Inside Borders") { ed.tableBorders(.inside) }
                            Button("No Borders") { ed.tableBorders(.none) }
                        } label: { Label("Borders", systemImage: "squareshape.split.2x2.dotted") }
                        .menuStyle(.borderlessButton).frame(width: 90)
                        Picker("", selection: $borderWidth) {
                            ForEach([0.5, 1, 2, 3] as [CGFloat], id: \.self) { Text("\(String(format: "%g", $0)) pt").tag($0) }
                        }.labelsHidden().frame(width: 70)
                            .onChange(of: borderWidth) { _, w in ed.tableBorderStyle(width: w, color: NSColor(borderColor)) }
                        ColorPicker("", selection: $borderColor, supportsOpacity: false).labelsHidden()
                            .onChange(of: borderColor) { _, c in ed.tableBorderStyle(width: borderWidth, color: NSColor(c)) }
                            .help("Border color")
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "paintbucket").frame(width: 20)
                        ColorPicker("", selection: $shade, supportsOpacity: false).labelsHidden()
                            .onChange(of: shade) { _, c in ed.tableShade(NSColor(c)) }
                            .help("Cell shading")
                        Button("No Shading") { ed.tableShade(nil) }.buttonStyle(.link).font(.caption)
                        Button("Header Row") { ed.tableToggleHeader() }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            RibbonGroup(title: "Formulas") {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Σ Sum above") { ed.tableFormula("=SUM(ABOVE)") }.buttonStyle(.link).font(.caption)
                        Button("Σ Sum left") { ed.tableFormula("=SUM(LEFT)") }.buttonStyle(.link).font(.caption)
                        Button("x̄ Average above") { ed.tableFormula("=AVERAGE(ABOVE)") }.buttonStyle(.link).font(.caption)
                    }
                    RibbonBigButton(symbol: "function", title: "Formula…") { ed.showFormula = true }
                        .frame(width: 60)
                    RibbonBigButton(symbol: "arrow.triangle.2.circlepath", title: "Recalc") { ed.recalculateTables() }
                }
            }
        }
        .disabled(!on)
        .opacity(on ? 1 : 0.45)
    }
}

/// Alt text editor: commits on Return or when focus leaves, so each keystroke isn't an undo step.
struct AltTextField: View {
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        RibbonGroup(title: "Alt Text") {
            TextField("Describe this picture", text: $text, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder).frame(width: 190)
                .focused($focused)
                .onSubmit { commit(text) }
                .onChange(of: focused) { _, f in if !f && text != value { commit(text) } }
                .onAppear { text = value }
                .onChange(of: value) { _, v in if !focused { text = v } }
                .accessibilityLabel("Alt Text")
        }
    }
}

struct ObjectRibbon: View {
    @EnvironmentObject var ed: EditorController

    private func inches(_ title: String, _ v: CGFloat, _ set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.caption).frame(width: 46, alignment: .trailing)
            Text(String(format: "%.2f\"", v / 72)).font(.caption).monospacedDigit().frame(width: 44)
            Stepper("", onIncrement: { set(v + 7.2) }, onDecrement: { set(v - 7.2) }).labelsHidden()
        }
    }

    private func percent(_ title: String, _ edge: Int, _ p: ImageProps) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.caption).frame(width: 46, alignment: .trailing)
            Text("\(Int((p.crop[edge] * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 36)
            Stepper("", onIncrement: { ed.setImageCrop(edge, p.crop[edge] + 0.02) },
                    onDecrement: { ed.setImageCrop(edge, p.crop[edge] - 0.02) }).labelsHidden()
        }
    }

    private func colorBinding(_ get: @escaping (FloatingObject) -> [CGFloat]?, _ set: @escaping (inout FloatingObject, [CGFloat]?) -> Void, fallback: Color) -> Binding<Color> {
        Binding(get: { ed.selectedObject.flatMap { FloatingObject.color(get($0)) }.map { Color(nsColor: $0) } ?? fallback },
                set: { c in ed.updateObject("Object Color") { set(&$0, FloatingObject.components(NSColor(c))) } })
    }

    @ViewBuilder private var floatingBody: some View {
        if let o = ed.selectedObject {
            RibbonGroup(title: "Arrange") {
                HStack(spacing: 4) {
                    Menu {
                        ForEach(WrapMode.allCases) { w in
                            Button((o.wrap == w ? "✓ " : "") + w.title) { ed.updateObject("Wrap") { $0.wrap = w } }
                        }
                        if o.kind == .image { Divider(); Button("In Line with Text") { ed.makeInline() } }
                    } label: {
                        VStack(spacing: 3) { Image(systemName: "text.redaction").font(.system(size: 22)); Text("Wrap").font(.caption) }
                    }
                    .menuStyle(.borderlessButton).frame(width: 50, height: 54)
                    VStack(spacing: 2) {
                        RibbonButton(symbol: "square.3.layers.3d.top.filled", help: "Bring to Front") { ed.bringToFront() }
                        RibbonButton(symbol: "square.3.layers.3d.bottom.filled", help: "Send to Back") { ed.sendToBack() }
                    }
                    RibbonButton(symbol: "trash", help: "Delete Object") { ed.deleteSelectedObject() }
                }
            }
            if o.kind == .image || o.kind == .shape {
                AltTextField(value: o.image?.alt ?? o.alt) { v in ed.updateObject("Alt Text") { if $0.kind == .image { $0.image?.alt = v } else { $0.alt = v } } }
            }
            RibbonGroup(title: "Size & Position") {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        inches("Width", o.w) { v in ed.updateObject("Size") { $0.w = max(12, v) } }
                        inches("Height", o.h) { v in ed.updateObject("Size") { $0.h = max(12, v) } }
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        inches("Left", o.x) { v in ed.updateObject("Move") { $0.x = max(0, v) } }
                        inches("Top", o.y) { v in ed.updateObject("Move") { $0.y = max(0, v) } }
                    }
                }
            }
            if o.kind != .image {
                RibbonGroup(title: "Style") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "paintbucket").frame(width: 18)
                            ColorPicker("", selection: colorBinding({ $0.fill }, { $0.fill = $1 }, fallback: .white), supportsOpacity: true).labelsHidden()
                            Button("No Fill") { ed.updateObject("Fill") { $0.fill = nil } }.buttonStyle(.link).font(.caption)
                            Menu {
                                ForEach([ShapeKind.rect, .rounded, .ellipse, .triangle, .diamond, .line, .arrow, .star]) { k in
                                    if o.kind != .textbox || k == .rect || k == .rounded {
                                        Button(k.title) { ed.updateObject("Shape") { $0.shape = k } }
                                    }
                                }
                            } label: { Label("Shape", systemImage: "square.on.circle") }
                            .menuStyle(.borderlessButton).frame(width: 74)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "pencil.line").frame(width: 18)
                            ColorPicker("", selection: colorBinding({ $0.stroke }, { $0.stroke = $1 }, fallback: .black), supportsOpacity: false).labelsHidden()
                            Picker("", selection: Binding(get: { o.strokeWidth }, set: { w in ed.updateObject("Outline") { $0.strokeWidth = w } })) {
                                ForEach([0, 0.5, 1, 2, 3, 5] as [CGFloat], id: \.self) { Text($0 == 0 ? "None" : "\(String(format: "%g", $0)) pt").tag($0) }
                            }.labelsHidden().frame(width: 76)
                        }
                    }
                }
            } else if let p = o.image {
                RibbonGroup(title: "Crop") {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) { objectCrop("Left", 0, p); objectCrop("Right", 2, p) }
                        VStack(alignment: .trailing, spacing: 2) { objectCrop("Top", 1, p); objectCrop("Bottom", 3, p) }
                    }
                }
            }
        }
    }

    private func objectCrop(_ title: String, _ edge: Int, _ p: ImageProps) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.caption).frame(width: 46, alignment: .trailing)
            Text("\(Int((p.crop[edge] * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 36)
            Stepper("", onIncrement: { ed.setObjectCrop(edge, p.crop[edge] + 0.02) },
                    onDecrement: { ed.setObjectCrop(edge, p.crop[edge] - 0.02) }).labelsHidden()
        }
    }

    var body: some View {
        if ed.selectedObject != nil {
            floatingBody
        } else if let p = ed.selectedImage {
            RibbonGroup(title: "Wrap") {
                Menu {
                    Button("✓ In Line with Text") {}.disabled(true)
                    ForEach(WrapMode.allCases) { w in Button(w.title) { ed.makeFloating(wrap: w) } }
                } label: {
                    VStack(spacing: 3) { Image(systemName: "text.redaction").font(.system(size: 22)); Text("Wrap").font(.caption) }
                }
                .menuStyle(.borderlessButton).frame(width: 50, height: 54)
            }
            RibbonGroup(title: "Size") {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        inches("Width", p.width) { ed.setImageWidth($0) }
                        inches("Height", p.height) { ed.setImageHeight($0) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Lock aspect", isOn: Binding(get: { p.lockAspect }, set: { v in ed.updateImage { $0.lockAspect = v } }))
                            .toggleStyle(.checkbox).font(.caption)
                        HStack(spacing: 4) {
                            Button("−10%") { ed.scaleImage(by: 0.9) }
                            Button("+10%") { ed.scaleImage(by: 1.1) }
                            Button("Reset") { ed.resetImage() }
                        }.font(.caption)
                    }
                }
            }
            AltTextField(value: p.alt) { v in ed.updateImage { $0.alt = v } }
            RibbonGroup(title: "Crop") {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) { percent("Left", 0, p); percent("Right", 2, p) }
                    VStack(alignment: .trailing, spacing: 2) { percent("Top", 1, p); percent("Bottom", 3, p) }
                }
            }
        } else if ed.selectedEquation != nil {
            RibbonGroup(title: "Equation") {
                RibbonBigButton(symbol: "pencil", title: "Edit") { ed.startEquation() }
            }
        } else {
            Text("Select a picture, shape, text box or equation to format it. Double-click an equation to edit it.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 18)
        }
    }
}

struct EquationSheet: View {
    @EnvironmentObject var ed: EditorController
    @State var draft: EquationDraft

    private let templates: [(String, String)] = [
        ("a/b", "\\frac{a}{b}"), ("x²", "x^{2}"), ("xₙ", "x_{n}"), ("√", "\\sqrt{x}"), ("ⁿ√", "\\sqrt[n]{x}"),
        ("Σ", "\\sum_{i=1}^{n} i"), ("∫", "\\int_{a}^{b} f(x)\\,dx"), ("Π", "\\prod_{i=1}^{n} i"),
        ("( )", "\\left( x \\right)"), ("±", "\\pm"), ("≤", "\\le"), ("≥", "\\ge"), ("≠", "\\ne"), ("∞", "\\infty"),
        ("π", "\\pi"), ("α", "\\alpha"), ("β", "\\beta"), ("θ", "\\theta"), ("Δ", "\\Delta"), ("→", "\\to"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.range == nil ? "Insert Equation" : "Edit Equation").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(templates, id: \.1) { t in
                        Button(t.0) { draft.source += (draft.source.isEmpty || draft.source.hasSuffix(" ") ? "" : " ") + t.1 }
                    }
                }
            }
            TextEditor(text: $draft.source)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            HStack {
                Text("Size").font(.caption)
                Stepper("\(Int(draft.size)) pt", value: $draft.size, in: 8...72, step: 1)
            }
            let r = MathRenderer.render(draft.source, fontSize: draft.size)
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: r.image).padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 130)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            Text("Type LaTeX-style input: \\frac{a}{b}, x^2, x_i, \\sqrt{x}, \\sum_{i=1}^{n}, \\int_a^b, \\alpha, \\left( … \\right)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { ed.equationDraft = nil }.keyboardShortcut(.cancelAction)
                Button(draft.range == nil ? "Insert" : "Update") { ed.applyEquation(draft) }
                    .keyboardShortcut(.defaultAction).disabled(draft.source.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }
}

struct LinkSheet: View {
    @EnvironmentObject var ed: EditorController
    @State var draft: LinkDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hyperlink").font(.headline)
            HStack {
                Text("Text to display").frame(width: 110, alignment: .leading)
                TextField("Text", text: $draft.text).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Address").frame(width: 110, alignment: .leading)
                TextField("https://… or name@example.com", text: $draft.address).textFieldStyle(.roundedBorder)
            }
            Text("⌘-click a link to open it.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { ed.linkDraft = nil }.keyboardShortcut(.cancelAction)
                Button("OK") { ed.applyLink(draft) }.keyboardShortcut(.defaultAction)
                    .disabled(EditorController.normalizedURL(draft.address) == nil)
            }
        }
        .padding(20).frame(width: 460)
    }
}

struct FormulaSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var formula = "=SUM(ABOVE)"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Formula").font(.headline)
            TextField("=SUM(ABOVE)", text: $formula).textFieldStyle(.roundedBorder)
            Text("Functions: SUM, AVERAGE, MIN, MAX, COUNT, PRODUCT. Ranges: ABOVE, BELOW, LEFT, RIGHT, A1:B3. Cells: A1 + B2 * 2.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { ed.showFormula = false }.keyboardShortcut(.cancelAction)
                Button("OK") { ed.tableFormula(formula); ed.showFormula = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }
}

struct TableSizeSheet: View {
    @EnvironmentObject var ed: EditorController
    @State private var rows = 3
    @State private var cols = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Table").font(.headline)
            Stepper("Rows: \(rows)", value: $rows, in: 1...50)
            Stepper("Columns: \(cols)", value: $cols, in: 1...12)
            HStack {
                Spacer()
                Button("Cancel") { ed.showTableSize = false }.keyboardShortcut(.cancelAction)
                Button("Insert") { ed.insertTable(rows: rows, cols: cols); ed.showTableSize = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 300)
    }
}

struct ViewRibbon: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        RibbonGroup(title: "Show") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Ruler", isOn: $ed.rulerVisible).toggleStyle(.checkbox)
                Toggle("Navigation Pane", isOn: $ed.showNav).toggleStyle(.checkbox)
            }
        }
        RibbonGroup(title: "Zoom") {
            HStack(spacing: 4) {
                RibbonBigButton(symbol: "1.magnifyingglass", title: "100%") { ed.setZoom(1) }
                RibbonBigButton(symbol: "arrow.left.and.right", title: "Page Width") { ed.fitWidth() }
                ForEach([0.5, 0.75, 1.5, 2.0], id: \.self) { z in
                    Button("\(Int(z * 100))%") { ed.setZoom(z) }
                }
            }
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var ed: EditorController

    var body: some View {
        HStack(spacing: 14) {
            if ed.stats.selectedWords > 0 { Text("\(ed.stats.selectedWords) of \(ed.stats.words) words") }
            else { Text("\(ed.stats.words) words") }
            Text("\(ed.stats.characters) characters")
            Text("Page \(ed.stats.currentPage) of \(ed.stats.pages)")
            Text("Section \(ed.currentSectionIndex + 1)")
            Spacer()
            Button { ed.setZoom(ed.zoom - 0.1) } label: { Image(systemName: "minus") }.buttonStyle(.plain)
                .accessibilityLabel("Zoom Out")
            Slider(value: Binding(get: { ed.zoom }, set: { ed.setZoom($0) }), in: 0.5...3.0).frame(width: 140)
                .accessibilityLabel("Zoom")
            Button { ed.setZoom(ed.zoom + 0.1) } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                .accessibilityLabel("Zoom In")
            Text("\(Int((ed.zoom * 100).rounded()))%").frame(width: 44, alignment: .trailing).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.bar)
    }
}

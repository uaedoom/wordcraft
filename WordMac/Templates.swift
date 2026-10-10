import AppKit
import SwiftUI

struct TemplateDef: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let build: () -> (NSAttributedString, DocMeta)
}

/// Small helper for writing template content with the document's own styles.
private final class TB {
    var meta = DocMeta()
    let out = NSMutableAttributedString()

    func style(_ id: String) -> StyleDef { meta.style(id) ?? StyleDef.make(id, id) }

    @discardableResult
    func p(_ text: String, _ styleID: String = "normal", align: NSTextAlignment? = nil, bold: Bool? = nil, italic: Bool? = nil,
           size: CGFloat? = nil, color: NSColor? = nil, before: CGFloat? = nil, after: CGFloat? = nil, extra: [NSAttributedString.Key: Any] = [:]) -> TB {
        var d = style(styleID)
        if let bold { d.bold = bold }
        if let italic { d.italic = italic }
        if let size { d.size = size }
        if let color { d.nsColor = color }
        var a = d.attributes(preserving: nil)
        if let ps = a[.paragraphStyle] as? NSMutableParagraphStyle {
            if let align { ps.alignment = align }
            if let before { ps.paragraphSpacingBefore = before }
            if let after { ps.paragraphSpacing = after }
        }
        for (k, v) in extra { a[k] = v }
        out.append(NSAttributedString(string: text + "\n", attributes: a))
        return self
    }

    func pageBreak() { out.append(NSAttributedString(string: "\u{000C}", attributes: style("normal").attributes(preserving: nil))) }

    func field(_ name: String) -> NSAttributedString {
        var a = style("normal").attributes(preserving: nil)
        a[.wcMerge] = name
        a[.backgroundColor] = NSColor(calibratedWhite: 0.86, alpha: 1)
        return NSAttributedString(string: "«\(name)»", attributes: a)
    }

    func table(_ rows: [[String]], header: Bool = true, widths: [CGFloat]? = nil, borders: Bool = true, formulas: [String: String] = [:], align: [NSTextAlignment] = []) {
        var g = TableGrid()
        g.rows = rows.count; g.cols = rows.first?.count ?? 1
        if let widths { g.columnWidths = widths }
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() {
                var d = style("normal"); d.spaceAfter = 0; d.lineMultiple = 1
                if header && r == 0 { d.bold = true }
                var a = d.attributes(preserving: nil)
                if let ps = a[.paragraphStyle] as? NSMutableParagraphStyle, c < align.count { ps.alignment = align[c] }
                if let f = formulas["\(r),\(c)"] { a[.wcFormula] = f }
                var cell = TableCell(row: r, col: c, content: NSAttributedString(string: text + "\n", attributes: a))
                if header && r == 0 { cell.shading = NSColor(white: 0.88, alpha: 1) }
                if !borders { cell.borders = [0, 0, 0, 0] }
                g.cells.append(cell)
            }
        }
        // evaluate formulas
        for (key, f) in formulas {
            let p = key.split(separator: ",").compactMap { Int($0) }
            guard p.count == 2, let i = g.cell(covering: p[0], p[1]), let v = FormulaEvaluator.evaluate(f, grid: g, row: p[0], col: p[1]) else { continue }
            let a = g.cells[i].content.attributes(at: 0, effectiveRange: nil)
            g.cells[i].content = NSAttributedString(string: FormulaEvaluator.format(v) + "\n", attributes: a)
        }
        out.append(g.render().text)
        p("", "normal")
    }
}

enum TemplateLibrary {
    static let builtin: [TemplateDef] = [
        TemplateDef(id: "blank", name: "Blank Document", detail: "Start from scratch", symbol: "doc") {
            (NSAttributedString(string: "\n", attributes: DocMeta().style("normal")!.attributes(preserving: nil)), DocMeta())
        },
        TemplateDef(id: "letter", name: "Letter", detail: "Formal business letter", symbol: "envelope") {
            let t = TB()
            t.p("Your Name", "normal", align: .right, bold: true, after: 0)
            t.p("123 Main Street", "normal", align: .right, after: 0)
            t.p("City, State 12345", "normal", align: .right, after: 18)
            t.p("October 9, 2026", "normal", after: 18)
            t.p("Recipient Name", "normal", after: 0)
            t.p("Company Name", "normal", after: 0)
            t.p("Address", "normal", after: 18)
            t.p("Dear Recipient,", "normal", after: 12)
            t.p("Write the opening of your letter here. State the purpose clearly in the first paragraph.", "normal", after: 12)
            t.p("Add supporting details in the following paragraphs.", "normal", after: 12)
            t.p("Sincerely,", "normal", after: 36)
            t.p("Your Name", "normal")
            return (t.out, t.meta)
        },
        TemplateDef(id: "merge", name: "Mail Merge Letter", detail: "Letter with merge fields and sample recipients", symbol: "envelope.badge") {
            let t = TB()
            t.meta.mergeData = MergeData(columns: ["FirstName", "LastName", "Company", "City"],
                                         rows: [["Amina", "Khalid", "Acme Trading", "Dubai"], ["Omar", "Hassan", "Blue Sea Co.", "Abu Dhabi"], ["Lina", "Saleh", "Nova Labs", "Sharjah"]])
            t.p("Your Company", "normal", bold: true, size: 16, after: 18)
            t.p("October 9, 2026", "normal", after: 18)
            let name = NSMutableAttributedString()
            name.append(t.field("FirstName")); name.append(NSAttributedString(string: " ", attributes: t.style("normal").attributes(preserving: nil))); name.append(t.field("LastName"))
            name.append(NSAttributedString(string: "\n", attributes: t.style("normal").attributes(preserving: nil)))
            t.out.append(name)
            let co = NSMutableAttributedString(attributedString: t.field("Company"))
            co.append(NSAttributedString(string: "\n", attributes: t.style("normal").attributes(preserving: nil)))
            t.out.append(co)
            let city = NSMutableAttributedString(attributedString: t.field("City"))
            city.append(NSAttributedString(string: "\n\n", attributes: t.style("normal").attributes(preserving: nil)))
            t.out.append(city)
            let dear = NSMutableAttributedString(string: "Dear ", attributes: t.style("normal").attributes(preserving: nil))
            dear.append(t.field("FirstName"))
            dear.append(NSAttributedString(string: ",\n", attributes: t.style("normal").attributes(preserving: nil)))
            t.out.append(dear)
            t.p("Thank you for your interest in our services. We would be glad to arrange a visit to your office in", "normal", after: 12)
            t.p("Please reply to this letter to confirm a convenient time.", "normal", after: 18)
            t.p("Kind regards,", "normal", after: 30)
            t.p("Your Name", "normal")
            return (t.out, t.meta)
        },
        TemplateDef(id: "resume", name: "Résumé", detail: "One-page résumé", symbol: "person.text.rectangle") {
            let t = TB()
            t.p("Your Name", "title", align: .left, after: 2)
            t.p("email@example.com  •  +971 50 000 0000  •  City", "normal", color: NSColor(white: 0.35, alpha: 1), after: 14)
            t.p("Summary", "h2")
            t.p("Two or three sentences about your experience, strengths and goals.", "normal")
            t.p("Experience", "h2")
            t.p("Job Title — Company", "normal", bold: true, after: 0)
            t.p("2022 – Present", "normal", italic: true, color: NSColor(white: 0.4, alpha: 1), after: 4)
            t.p("Describe your responsibilities and achievements with measurable results.", "normal")
            t.p("Education", "h2")
            t.p("Degree — University", "normal", bold: true, after: 0)
            t.p("2018 – 2022", "normal", italic: true, color: NSColor(white: 0.4, alpha: 1))
            t.p("Skills", "h2")
            t.p("Skill one, skill two, skill three", "normal")
            t.meta.layout.top = 54; t.meta.layout.bottom = 54
            return (t.out, t.meta)
        },
        TemplateDef(id: "report", name: "Report", detail: "Title page and numbered-style headings", symbol: "doc.richtext") {
            let t = TB()
            for _ in 0..<5 { t.p("", "normal") }
            t.p("Report Title", "title", align: .center, size: 34, after: 10)
            t.p("Subtitle or description", "subtitle", align: .center, after: 30)
            t.p("Author Name", "normal", align: .center, after: 0)
            t.p("October 9, 2026", "normal", align: .center)
            t.pageBreak()
            t.p("Introduction", "h1")
            t.p("Introduce the topic, the question you are answering, and how the report is organised.", "normal")
            t.p("Method", "h1")
            t.p("Explain how you gathered and analysed information.", "normal")
            t.p("Results", "h1")
            t.p("Present the findings. Use tables and figures with captions where helpful.", "normal")
            t.p("Conclusion", "h1")
            t.p("Summarise what you found and what should happen next.", "normal")
            t.meta.layout.footer.center = "{page}"
            return (t.out, t.meta)
        },
        TemplateDef(id: "memo", name: "Memo", detail: "Internal memorandum", symbol: "note.text") {
            let t = TB()
            t.p("MEMORANDUM", "normal", bold: true, size: 20, after: 14)
            t.table([["To:", "Recipient"], ["From:", "Your Name"], ["Date:", "October 9, 2026"], ["Subject:", "Subject line"]], header: false, widths: [18, 82], borders: false)
            t.p("Write the message here. Lead with the main point, then give the details.", "normal")
            return (t.out, t.meta)
        },
        TemplateDef(id: "minutes", name: "Meeting Minutes", detail: "Agenda, attendees and actions", symbol: "person.3") {
            let t = TB()
            t.p("Meeting Minutes", "title", size: 26)
            t.p("Date: October 9, 2026     Time: 10:00     Location: Room 1", "normal", color: NSColor(white: 0.35, alpha: 1), after: 12)
            t.p("Attendees", "h2")
            t.p("Name 1, Name 2, Name 3", "normal")
            t.p("Agenda and Discussion", "h2")
            t.p("1. Topic one — summary of discussion.", "normal", after: 2)
            t.p("2. Topic two — summary of discussion.", "normal")
            t.p("Action Items", "h2")
            t.table([["Action", "Owner", "Due"], ["Describe the action", "Name", "Date"], ["", "", ""]], widths: [60, 20, 20])
            return (t.out, t.meta)
        },
        TemplateDef(id: "invoice", name: "Invoice", detail: "Line items with formulas", symbol: "doc.plaintext") {
            let t = TB()
            t.p("INVOICE", "title", size: 30, after: 4)
            t.p("Invoice #1001   •   October 9, 2026", "normal", color: NSColor(white: 0.35, alpha: 1), after: 14)
            t.p("Bill to: Customer Name, Address", "normal", after: 14)
            t.table([["Item", "Qty", "Unit price", "Amount"],
                     ["Service or product", "2", "50", ""],
                     ["Another item", "1", "120", ""],
                     ["Third item", "3", "15", ""],
                     ["Total", "", "", ""]],
                    widths: [46, 14, 20, 20],
                    formulas: ["1,3": "=B2*C2", "2,3": "=B3*C3", "3,3": "=B4*C4", "4,3": "=SUM(ABOVE)"],
                    align: [.left, .right, .right, .right])
            t.p("Payment due within 30 days. Thank you for your business.", "normal", italic: true)
            return (t.out, t.meta)
        },
        TemplateDef(id: "newsletter", name: "Newsletter", detail: "Two-column layout", symbol: "newspaper") {
            let t = TB()
            t.p("The Weekly Bulletin", "title", align: .center, size: 30, after: 4)
            t.p("Issue 1  •  October 2026", "subtitle", align: .center, after: 14)
            t.p("Lead Story", "h2")
            t.p("Write your main story here. The text flows from one column to the next automatically, just like a printed newsletter.", "normal")
            t.p("Upcoming Events", "h2")
            t.p("List dates and details of events your readers should know about.", "normal")
            t.p("Announcements", "h2")
            t.p("Short notices, reminders and thank-yous.", "normal")
            t.meta.layout.columns = 2
            t.meta.layout.left = 54; t.meta.layout.right = 54
            return (t.out, t.meta)
        },
    ]

    static var userDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WordCraft/Templates")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func userTemplates() -> [TemplateDef] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "wmdoc" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            TemplateDef(id: "user-" + url.lastPathComponent, name: url.deletingPathExtension().lastPathComponent, detail: "My template", symbol: "star") {
                if let w = try? FileWrapper(url: url, options: []), let l = try? RichTextDocument.load(w) {
                    let m = NSMutableAttributedString(attributedString: l.attributed)
                    PendingDocument.userAssets = l.assets
                    return (m, l.meta)
                }
                return (NSAttributedString(string: "\n"), DocMeta())
            }
        }
    }

    /// Opens a template as a new untitled document.
    static func create(_ t: TemplateDef) {
        PendingDocument.userAssets = [:]
        let (text, meta) = t.build()
        PendingDocument.payload = (text, meta, PendingDocument.userAssets)
        NSDocumentController.shared.newDocument(nil)
    }

    static func saveUserTemplate(name: String, from doc: RichTextDocument) {
        guard let snap = try? doc.snapshot(contentType: .wordMac) else { return }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        try? RichTextDocument.wrapper(snap).write(to: userDirectory.appendingPathComponent(safe + ".wmdoc"), options: .atomic, originalContentsURL: nil)
    }

    static func deleteUserTemplate(_ t: TemplateDef) {
        try? FileManager.default.removeItem(at: userDirectory.appendingPathComponent(String(t.id.dropFirst(5))))
    }
}

extension PendingDocument {
    static var userAssets: [String: Data] = [:]
}

struct TemplateGallery: View {
    @Environment(\.dismiss) private var dismiss
    @State private var user = TemplateLibrary.userTemplates()

    private func card(_ t: TemplateDef, deletable: Bool = false) -> some View {
        Button {
            TemplateLibrary.create(t)
            dismiss()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: t.symbol).font(.system(size: 34)).foregroundStyle(Color.accentColor).frame(height: 44)
                Text(LocalizedStringKey(t.name)).font(.headline).lineLimit(1)
                Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: 150, height: 130).padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .contextMenu { if deletable { Button("Delete Template") { TemplateLibrary.deleteUserTemplate(t); user = TemplateLibrary.userTemplates() } } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New from Template").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(TemplateLibrary.builtin) { card($0) }
                }
                if !user.isEmpty {
                    Text("My Templates").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(user) { card($0, deletable: true) }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

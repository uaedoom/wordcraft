import AppKit
import AppIntents

// MARK: - Registry and macro API shared by AppleScript and Shortcuts

enum EditorRegistry {
    private struct Box { weak var value: EditorController? }
    private static var boxes: [Box] = []

    static func register(_ c: EditorController) {
        boxes.removeAll { $0.value == nil || $0.value === c }
        boxes.append(Box(value: c))
    }

    /// The editor of the key window, or the most recently opened one.
    static var current: EditorController? {
        let live = boxes.compactMap(\.value)
        return live.first { $0.bodyTextView?.window?.isKeyWindow == true }
            ?? live.first { $0.bodyTextView?.window?.isMainWindow == true }
            ?? live.last
    }
}

enum MacroError: LocalizedError {
    case noDocument, notEditable, unknown(String)
    var errorDescription: String? {
        switch self {
        case .noDocument: "There is no open WordCraft document."
        case .notEditable: "The document is protected against editing."
        case .unknown(let s): s
        }
    }
}

@MainActor
enum MacroAPI {
    static func editor() throws -> EditorController {
        guard let e = EditorRegistry.current, e.bodyTextView != nil else { throw MacroError.noDocument }
        return e
    }

    static func text() throws -> String { try editor().plainText() }

    static func insert(_ s: String) throws {
        let e = try editor()
        guard e.canEditText || e.meta.protection.mode == .forms, let tv = e.bodyTextView, tv.isEditable else { throw MacroError.notEditable }
        tv.insertText(s, replacementRange: tv.selectedRange())
    }

    static func append(_ s: String) throws {
        let e = try editor()
        guard let tv = e.bodyTextView, tv.isEditable else { throw MacroError.notEditable }
        let end = NSRange(location: (tv.string as NSString).length, length: 0)
        tv.insertText(s, replacementRange: end)
    }

    @discardableResult
    static func replace(_ find: String, with repl: String, caseSensitive: Bool = false) throws -> Int {
        let e = try editor()
        guard let tv = e.bodyTextView, tv.isEditable, !find.isEmpty else { throw MacroError.notEditable }
        let ns = tv.string as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: find, options: caseSensitive ? [] : [.caseInsensitive], range: search)
            if r.location == NSNotFound { break }
            ranges.append(r)
            search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
        }
        for r in ranges.reversed() { tv.insertText(repl, replacementRange: r) }
        return ranges.count
    }

    static func applyStyle(_ name: String) throws {
        let e = try editor()
        guard let s = e.styles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw MacroError.unknown("There is no style named “\(name)”.")
        }
        e.applyStyle(s.id)
    }

    static func wordCount() throws -> Int { try editor().countWords().words }

    static func updateFields() throws { try editor().updateAllFields() }

    static func setTracking(_ on: Bool) throws {
        let e = try editor()
        if e.isTracking != on { e.toggleTracking() }
    }

    static func acceptAll() throws { try editor().acceptAll() }
    static func rejectAll() throws { try editor().rejectAll() }

    static func newDocument(text: String) {
        let m = DocMeta()
        let attrs = m.style("normal")?.attributes(preserving: nil) ?? [:]
        PendingDocument.payload = (NSAttributedString(string: text.isEmpty ? "\n" : text + (text.hasSuffix("\n") ? "" : "\n"), attributes: attrs), m, [:])
        NSDocumentController.shared.newDocument(nil)
    }

    /// Writes the document in the given format. Paths outside the app's sandbox may be refused by macOS.
    static func export(format: String, path: String) throws {
        let e = try editor()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        switch format.lowercased() {
        case "docx", "word": guard let d = e.docxData() else { throw MacroError.unknown("Could not build the document.") }; try d.write(to: url)
        case "pdf": e.writePDF(to: url)
        case "txt", "text": try e.plainText().write(to: url, atomically: true, encoding: .utf8)
        case "rtf":
            guard let st = e.document?.storage else { return }
            let a = AttachmentBuilder.stripped(st)
            try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        default: throw MacroError.unknown("Unknown format “\(format)”. Use docx, pdf, rtf or txt.")
        }
    }
}

// MARK: - AppleScript commands (see WordCraft.sdef)

private func scriptError(_ cmd: NSScriptCommand, _ error: Error) -> Any? {
    cmd.scriptErrorNumber = -10000
    cmd.scriptErrorString = error.localizedDescription
    return nil
}

@objc(WCGetTextCommand) final class WCGetTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { do { return try MacroAPI.text() } catch { return scriptError(self, error) } }
    }
}

@objc(WCInsertTextCommand) final class WCInsertTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do { try MacroAPI.insert((directParameter as? String) ?? ""); return nil } catch { return scriptError(self, error) }
        }
    }
}

@objc(WCAppendTextCommand) final class WCAppendTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do { try MacroAPI.append((directParameter as? String) ?? ""); return nil } catch { return scriptError(self, error) }
        }
    }
}

@objc(WCReplaceTextCommand) final class WCReplaceTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let args = evaluatedArguments ?? [:]
            do {
                return try MacroAPI.replace((directParameter as? String) ?? (args["find"] as? String) ?? "", with: (args["with"] as? String) ?? "",
                                            caseSensitive: (args["caseSensitive"] as? Bool) ?? false)
            } catch { return scriptError(self, error) }
        }
    }
}

@objc(WCApplyStyleCommand) final class WCApplyStyleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do { try MacroAPI.applyStyle((directParameter as? String) ?? ""); return nil } catch { return scriptError(self, error) }
        }
    }
}

@objc(WCWordCountCommand) final class WCWordCountCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { do { return try MacroAPI.wordCount() } catch { return scriptError(self, error) } }
    }
}

@objc(WCUpdateFieldsCommand) final class WCUpdateFieldsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { do { try MacroAPI.updateFields(); return nil } catch { return scriptError(self, error) } }
    }
}

@objc(WCTrackChangesCommand) final class WCTrackChangesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { do { try MacroAPI.setTracking((directParameter as? Bool) ?? true); return nil } catch { return scriptError(self, error) } }
    }
}

@objc(WCReviewAllCommand) final class WCReviewAllCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do {
                if (evaluatedArguments?["accept"] as? Bool) ?? ((directParameter as? Bool) ?? true) { try MacroAPI.acceptAll() } else { try MacroAPI.rejectAll() }
                return nil
            } catch { return scriptError(self, error) }
        }
    }
}

@objc(WCNewDocumentCommand) final class WCNewDocumentCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { MacroAPI.newDocument(text: (directParameter as? String) ?? ""); return nil }
    }
}

@objc(WCExportCommand) final class WCExportCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let args = evaluatedArguments ?? [:]
            do { try MacroAPI.export(format: (args["format"] as? String) ?? "docx", path: (directParameter as? String) ?? (args["path"] as? String) ?? ""); return nil }
            catch { return scriptError(self, error) }
        }
    }
}

// MARK: - Shortcuts (App Intents)

struct InsertTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Insert Text"
    static var description = IntentDescription("Inserts text at the cursor in the front WordCraft document.")
    static var openAppWhenRun = true
    @Parameter(title: "Text") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        try MacroAPI.insert(text)
        return .result()
    }
}

struct AppendTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Append Text"
    static var description = IntentDescription("Adds text to the end of the front WordCraft document.")
    static var openAppWhenRun = true
    @Parameter(title: "Text") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        try MacroAPI.append(text)
        return .result()
    }
}

struct GetTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Document Text"
    static var description = IntentDescription("Returns the text of the front WordCraft document.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try MacroAPI.text())
    }
}

struct ReplaceTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Find and Replace"
    static var description = IntentDescription("Replaces every occurrence of some text in the front WordCraft document.")
    static var openAppWhenRun = true
    @Parameter(title: "Find") var find: String
    @Parameter(title: "Replace With") var replacement: String
    @Parameter(title: "Match Case", default: false) var matchCase: Bool
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try MacroAPI.replace(find, with: replacement, caseSensitive: matchCase))
    }
}

struct ApplyStyleIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Style"
    static var description = IntentDescription("Applies a paragraph style such as Heading 1 to the selected paragraphs.")
    static var openAppWhenRun = true
    @Parameter(title: "Style Name") var styleName: String
    @MainActor func perform() async throws -> some IntentResult {
        try MacroAPI.applyStyle(styleName)
        return .result()
    }
}

struct WordCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Count Words"
    static var description = IntentDescription("Returns the number of words in the front WordCraft document.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try MacroAPI.wordCount())
    }
}

struct NewDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "New Document"
    static var description = IntentDescription("Creates a new WordCraft document, optionally with some starting text.")
    static var openAppWhenRun = true
    @Parameter(title: "Text", default: "") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        MacroAPI.newDocument(text: text)
        return .result()
    }
}

struct WordCraftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewDocumentIntent(), phrases: ["New \(.applicationName) document"], shortTitle: "New Document", systemImageName: "doc.badge.plus")
        AppShortcut(intent: WordCountIntent(), phrases: ["Count words in \(.applicationName)"], shortTitle: "Count Words", systemImageName: "textformat.123")
    }
}

import AppKit
import UniformTypeIdentifiers

extension EditorController {
    private func askForURL(_ type: UTType, ext: String, completion: @escaping (URL) -> Void) {
        guard let window = textView?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let base = window.title.replacingOccurrences(of: " — Edited", with: "")
        panel.nameFieldStringValue = ((base as NSString).deletingPathExtension.isEmpty ? "Untitled" : (base as NSString).deletingPathExtension) + "." + ext
        panel.beginSheetModal(for: window) { resp in
            if resp == .OK, let url = panel.url { completion(url) }
        }
    }

    func docxData() -> Data? {
        guard let doc = document else { return nil }
        refreshFields()
        return DocxWriter(storage: doc.storage, meta: meta, assets: doc.assets).write()
    }

    func exportDocx() {
        askForURL(.docx, ext: "docx") { [weak self] url in
            guard let data = self?.docxData() else { return }
            try? data.write(to: url)
        }
    }

    /// Text without object-replacement characters, markers and breaks.
    func plainText() -> String {
        guard let st = document?.storage else { return "" }
        var out = ""
        let full = NSRange(location: 0, length: st.length)
        st.enumerateAttributes(in: full, options: []) { a, r, _ in
            let sub = (st.string as NSString).substring(with: r)
            if a[.wcObject] != nil || a[.wcImage] != nil { return }
            if a[.wcFootnote] != nil || a[.wcEndnote] != nil { out += "[note]"; return }
            if let eq = EquationProps.decode(a[.wcEquation]) { out += eq.source; return }
            out += sub.replacingOccurrences(of: "\u{000C}", with: "\n").replacingOccurrences(of: "\u{200B}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        return out
    }

    func exportText() {
        askForURL(.plainText, ext: "txt") { [weak self] url in
            try? self?.plainText().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func richCopy() -> NSAttributedString? {
        guard let st = document?.storage else { return nil }
        let m = NSMutableAttributedString(attributedString: AttachmentBuilder.stripped(st))
        // swap marker characters for something readable
        var loc = 0
        while loc < m.length {
            let a = m.attributes(at: loc, effectiveRange: nil)
            if a[.wcObject] != nil || a[.wcSection] != nil {
                m.replaceCharacters(in: NSRange(location: loc, length: 1), with: a[.wcSection] != nil ? "\u{000C}" : "")
            } else { loc += 1 }
        }
        return m
    }

    func exportRTF() {
        askForURL(.rtf, ext: "rtf") { [weak self] url in
            guard let a = self?.richCopy(),
                  let d = try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
            try? d.write(to: url)
        }
    }

    func exportHTML() {
        askForURL(.html, ext: "html") { [weak self] url in
            guard let a = self?.richCopy(),
                  let d = try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) else { return }
            try? d.write(to: url)
        }
    }
}

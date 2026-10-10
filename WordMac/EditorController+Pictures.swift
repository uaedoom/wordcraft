import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EquationDraft: Identifiable {
    let id = UUID()
    var source: String
    var size: CGFloat
    var range: NSRange?
}

// MARK: - Inline pictures

extension EditorController {
    var assets: AssetStore? { document?.assets }

    func insertPictureFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture to insert"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        insertPicture(data: data)
    }

    /// Adds the image file to the document and inserts it inline at the caret.
    func insertPicture(data: Data) {
        guard let assets, NSImage(data: data) != nil else { return }
        let id = assets.add(data)
        let nat = assets.naturalSize(id)
        let maxW = max(72, layout.columnWidth)
        var w = nat.width, h = nat.height
        if w > maxW { h *= maxW / w; w = maxW }
        insertInline(ImageProps(asset: id, width: w, height: h))
    }

    func insertInline(_ props: ImageProps) {
        guard let tv = textView, let assets else { return }
        let att = AttachmentBuilder.imageAttachment(props, assets: assets)
        let a = NSMutableAttributedString(attachment: att)
        var attrs = tv.typingAttributes
        attrs[.wcImage] = props.json
        a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
        tv.insertText(a, replacementRange: tv.selectedRange())
        sanitizeTypingAttributes(tv)
        tv.window?.makeFirstResponder(tv)
    }

    private func selectedImageRange() -> NSRange? {
        guard let tv = textView, tv.selectedRange().length == 1 else { return nil }
        return tv.selectedRange()
    }

    func updateImage(_ transform: (inout ImageProps) -> Void) {
        guard let tv = textView, let st = tv.textStorage, let assets, let r = selectedImageRange(),
              var p = ImageProps.decode(st.attribute(.wcImage, at: r.location, effectiveRange: nil)) else { return }
        let old = p
        transform(&p)
        guard p != old, tv.shouldChangeText(in: r, replacementString: nil) else { return }
        st.addAttributes([.attachment: AttachmentBuilder.imageAttachment(p, assets: assets), .wcImage: p.json], range: r)
        tv.didChangeText()
        tv.undoManager?.setActionName("Format Picture")
        refresh()
    }

    func setImageWidth(_ w: CGFloat) {
        updateImage { p in
            let nw = max(8, w)
            if p.lockAspect { p.height = p.height * nw / p.width }
            p.width = nw
        }
    }

    func setImageHeight(_ h: CGFloat) {
        updateImage { p in
            let nh = max(8, h)
            if p.lockAspect { p.width = p.width * nh / p.height }
            p.height = nh
        }
    }

    func scaleImage(by f: CGFloat) {
        updateImage { p in p.width = max(8, p.width * f); p.height = max(8, p.height * f) }
    }

    func resetImage() {
        guard let assets else { return }
        updateImage { p in
            let nat = assets.naturalSize(p.asset)
            p.crop = [0, 0, 0, 0]
            let maxW = max(72, layout.columnWidth)
            var w = nat.width, h = nat.height
            if w > maxW { h *= maxW / w; w = maxW }
            p.width = w; p.height = h
        }
    }

    /// Crops by edge index (0 left, 1 top, 2 right, 3 bottom); the picture keeps its scale.
    func setImageCrop(_ edge: Int, _ value: CGFloat) {
        guard let assets else { return }
        updateImage { p in
            let nat = assets.naturalSize(p.asset)
            let oc = p.crop
            let sx = p.width / (nat.width * max(0.05, 1 - oc[0] - oc[2]))
            let sy = p.height / (nat.height * max(0.05, 1 - oc[1] - oc[3]))
            var c = oc
            c[edge] = min(max(0, value), 0.45)
            if c[0] + c[2] > 0.9 || c[1] + c[3] > 0.9 { return }
            p.crop = c
            p.width = nat.width * (1 - c[0] - c[2]) * sx
            p.height = nat.height * (1 - c[1] - c[3]) * sy
        }
    }

    /// Pasted or dropped pictures become document assets so they survive saving.
    func normalizeAttachments() {
        guard let st = textView?.textStorage, let assets else { return }
        var found: [(NSRange, NSTextAttachment)] = []
        st.enumerateAttribute(.attachment, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            guard let att = v as? NSTextAttachment,
                  st.attribute(.wcImage, at: r.location, effectiveRange: nil) == nil,
                  st.attribute(.wcEquation, at: r.location, effectiveRange: nil) == nil else { return }
            found.append((r, att))
        }
        guard !found.isEmpty else { return }
        st.beginEditing()
        for (r, att) in found {
            var img = att.image
            if img == nil, let d = att.fileWrapper?.regularFileContents ?? att.contents { img = NSImage(data: d) }
            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let id = assets.add(png)
            let nat = assets.naturalSize(id)
            let maxW = max(72, layout.columnWidth)
            var w = att.bounds.width > 0 ? att.bounds.width : nat.width
            var h = att.bounds.height > 0 ? att.bounds.height : nat.height
            if w > maxW { h *= maxW / w; w = maxW }
            let p = ImageProps(asset: id, width: w, height: h)
            st.addAttributes([.attachment: AttachmentBuilder.imageAttachment(p, assets: assets), .wcImage: p.json], range: r)
        }
        st.endEditing()
    }

    func editAttachment(at index: Int) {
        guard let tv = textView else { return }
        tv.setSelectedRange(NSRange(location: index, length: 1))
        refresh()
        if selectedEquation != nil { startEquation() }
    }
}

// MARK: - Equations

extension EditorController {
    func startEquation() {
        if let eq = selectedEquation, let tv = textView {
            equationDraft = EquationDraft(source: eq.source, size: eq.size, range: tv.selectedRange())
        } else {
            equationDraft = EquationDraft(source: "\\frac{a}{b}", size: max(10, format.fontSize), range: nil)
        }
    }

    func applyEquation(_ d: EquationDraft) {
        guard let tv = textView else { return }
        let p = EquationProps(source: d.source, size: d.size)
        let a = NSMutableAttributedString(attachment: AttachmentBuilder.equationAttachment(p))
        var attrs = tv.typingAttributes
        attrs[.wcEquation] = p.json
        a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
        tv.insertText(a, replacementRange: d.range ?? tv.selectedRange())
        sanitizeTypingAttributes(tv)
        tv.window?.makeFirstResponder(tv)
        equationDraft = nil
        refresh()
    }
}

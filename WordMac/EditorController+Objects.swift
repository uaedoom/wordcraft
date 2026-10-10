import AppKit
import SwiftUI

extension EditorController {
    var selectedObject: FloatingObject? { selectedObjectID.flatMap { meta.objects[$0] } }

    func wireOverlay(_ o: ObjectOverlay) {
        o.onSelect = { [weak self] id in self?.selectedObjectID = id }
        o.onBegin = { [weak self] in self?.dragStartMeta = self?.meta }
        o.onLive = { [weak self] id, f in self?.liveUpdate(id, f) }
        o.onCommit = { [weak self] in self?.commitLive() }
        o.onDelete = { [weak self] id in self?.deleteObject(id) }
        o.onText = { [weak self] id, data in
            guard let self, var obj = self.meta.objects[id] else { return }
            obj.rtf = data
            self.meta.objects[id] = obj
            self.document?.meta = self.meta
        }
        o.onTextEvent = { [weak self] in self?.refresh() }
    }

    func selectObject(_ id: String?) {
        selectedObjectID = id
        engine?.pagesView.overlay.selectedID = id
    }

    func deselectObjectIfNeeded() {
        if selectedObjectID != nil, !(engine?.pagesView.overlay.window?.firstResponder is ObjectOverlay) { selectObject(nil) }
    }

    // MARK: Live editing (dragging)

    private func liveUpdate(_ id: String, _ f: (inout FloatingObject) -> Void) {
        guard var o = meta.objects[id] else { return }
        f(&o)
        meta.objects[id] = o
        document?.meta = meta
        engine?.refreshObjects()
    }

    private func commitLive() {
        guard let old = dragStartMeta, old != meta, let um = bodyTextView?.undoManager else { dragStartMeta = nil; return }
        let new = meta
        um.registerUndo(withTarget: self) { $0.setMeta(old, undoTo: new, name: "Move Object") }
        um.setActionName("Move Object")
        dragStartMeta = nil
    }

    /// Undoable edit of the selected object from the ribbon.
    func updateObject(_ name: String = "Format Object", _ f: (inout FloatingObject) -> Void) {
        guard let id = selectedObjectID else { return }
        updateMeta(name) { m in
            if var o = m.objects[id] { f(&o); m.objects[id] = o }
        }
    }

    // MARK: Creating

    private func addObject(_ proto: FloatingObject) {
        guard let tv = bodyTextView, let engine else { return }
        var obj = proto
        let pos = engine.placement(for: tv, size: CGSize(width: obj.w, height: obj.h))
        obj.x = pos.x; obj.y = pos.y
        obj.z = (meta.objects.values.map(\.z).max() ?? 0) + 1
        var attrs = tv.typingAttributes
        attrs[.wcObject] = obj.id
        tv.undoManager?.beginUndoGrouping()
        updateMeta("Insert Object") { $0.objects[obj.id] = obj }
        tv.insertText(NSAttributedString(string: "\u{200B}", attributes: attrs), replacementRange: tv.selectedRange())
        sanitizeTypingAttributes(tv)
        tv.undoManager?.setActionName("Insert Object")
        tv.undoManager?.endUndoGrouping()
        selectObject(obj.id)
        engine.refreshObjects()
    }

    private func newID() -> String { String(UUID().uuidString.prefix(8)) }

    func insertShape(_ kind: ShapeKind) {
        var o = FloatingObject(id: newID(), kind: .shape, shape: kind, x: 0, y: 0, w: kind == .line || kind == .arrow ? 160 : 140, h: kind == .line || kind == .arrow ? 24 : 100)
        o.wrap = .front
        o.fill = (kind == .line || kind == .arrow) ? nil : [0.36, 0.58, 0.86, 1]
        o.stroke = [0.12, 0.27, 0.5, 1]
        o.strokeWidth = 2
        addObject(o)
    }

    func insertTextBox() {
        var o = FloatingObject(id: newID(), kind: .textbox, shape: .rect, x: 0, y: 0, w: 220, h: 90)
        o.wrap = .square
        o.fill = [1, 1, 1, 1]
        o.stroke = [0.3, 0.3, 0.3, 1]
        o.strokeWidth = 1
        addObject(o)
        if let id = selectedObjectID { DispatchQueue.main.async { self.engine?.pagesView.overlay.focusTextBox(id) } }
    }

    func insertFloatingPicture(wrap: WrapMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to insert"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              NSImage(data: data) != nil, let assets else { return }
        let id = assets.add(data)
        addFloatingImage(ImageProps(asset: id, width: 0, height: 0), wrap: wrap)
    }

    func addFloatingImage(_ p: ImageProps, wrap: WrapMode) {
        guard let assets else { return }
        var props = p
        let nat = assets.naturalSize(props.asset)
        if props.width <= 0 {
            let maxW = max(72, layout.columnWidth * 0.7)
            var w = nat.width, h = nat.height
            if w > maxW { h *= maxW / w; w = maxW }
            props.width = w; props.height = h
        }
        var o = FloatingObject(id: newID(), kind: .image, x: 0, y: 0, w: props.width, h: props.height)
        o.image = props
        o.wrap = wrap
        o.stroke = nil
        o.strokeWidth = 0
        addObject(o)
    }

    // MARK: Deleting, wrapping, z-order

    func deleteObject(_ id: String) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        tv.undoManager?.beginUndoGrouping()
        var ranges: [NSRange] = []
        st.enumerateAttribute(.wcObject, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in
            if (v as? String) == id { ranges.append(r) }
        }
        for r in ranges.reversed() where tv.shouldChangeText(in: r, replacementString: "") {
            st.deleteCharacters(in: r)
            tv.didChangeText()
        }
        updateMeta("Delete Object") { $0.objects.removeValue(forKey: id) }
        tv.undoManager?.setActionName("Delete Object")
        tv.undoManager?.endUndoGrouping()
        selectObject(nil)
        tv.window?.makeFirstResponder(tv)
    }

    func deleteSelectedObject() { if let id = selectedObjectID { deleteObject(id) } }

    func bringToFront() { let top = (meta.objects.values.map(\.z).max() ?? 0) + 1; updateObject("Bring to Front") { $0.z = top } }
    func sendToBack() { let low = (meta.objects.values.map(\.z).min() ?? 0) - 1; updateObject("Send to Back") { $0.z = low } }

    /// Turns the selected inline picture into a floating one.
    func makeFloating(wrap: WrapMode) {
        guard let tv = bodyTextView, let st = tv.textStorage, let p = selectedImage, tv.selectedRange().length == 1 else { return }
        let r = tv.selectedRange()
        tv.undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: r, replacementString: "") {
            st.deleteCharacters(in: r)
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: r.location, length: 0))
        addFloatingImage(p, wrap: wrap)
        tv.undoManager?.setActionName("Wrap Picture")
        tv.undoManager?.endUndoGrouping()
    }

    /// Puts a floating picture back in the text line.
    func makeInline() {
        guard let o = selectedObject, o.kind == .image, var p = o.image, let tv = bodyTextView, let st = tv.textStorage else { return }
        var loc: Int?
        st.enumerateAttribute(.wcObject, in: NSRange(location: 0, length: st.length), options: []) { v, r, stop in
            if (v as? String) == o.id { loc = r.location; stop.pointee = true }
        }
        guard let at = loc else { return }
        p.width = o.w; p.height = o.h
        tv.undoManager?.beginUndoGrouping()
        deleteObject(o.id)
        tv.setSelectedRange(NSRange(location: min(at, st.length), length: 0))
        insertInline(p)
        tv.undoManager?.setActionName("Inline Picture")
        tv.undoManager?.endUndoGrouping()
    }

    func setObjectCrop(_ edge: Int, _ value: CGFloat) {
        guard let assets, let o = selectedObject, var p = o.image else { return }
        let nat = assets.naturalSize(p.asset)
        let oc = p.crop
        let sx = o.w / (nat.width * max(0.05, 1 - oc[0] - oc[2]))
        let sy = o.h / (nat.height * max(0.05, 1 - oc[1] - oc[3]))
        var c = oc
        c[edge] = min(max(0, value), 0.45)
        if c[0] + c[2] > 0.9 || c[1] + c[3] > 0.9 { return }
        p.crop = c
        updateObject("Crop Picture") {
            $0.image = p
            $0.w = nat.width * (1 - c[0] - c[2]) * sx
            $0.h = nat.height * (1 - c[1] - c[3]) * sy
        }
    }
}

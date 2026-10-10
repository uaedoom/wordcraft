import AppKit
import SwiftUI

private final class MenuPicker: NSObject {
    var handler: (String) -> Void
    init(_ h: @escaping (String) -> Void) { handler = h }
    @objc func pick(_ item: NSMenuItem) { handler(item.title) }
}

private struct DateChooser: View {
    @State var date: Date
    let done: (Date) -> Void
    var body: some View {
        DatePicker("", selection: $date, displayedComponents: .date)
            .datePickerStyle(.graphical).labelsHidden().padding(8)
            .onChange(of: date) { _, d in done(d) }
    }
}

extension EditorController {
    func controlRun(at loc: Int) -> (range: NSRange, props: ControlProps)? {
        guard let st = engine?.storage, st.length > 0 else { return nil }
        for probe in [min(loc, st.length - 1), max(0, min(loc, st.length) - 1)] {
            var r = NSRange()
            if let v = st.attribute(.wcControl, at: probe, longestEffectiveRange: &r, in: NSRange(location: 0, length: st.length)),
               let p = ControlProps.decode(v), loc >= r.location, loc <= NSMaxRange(r) { return (r, p) }
        }
        return nil
    }

    func insertControl(kind: String) {
        guard let tv = bodyTextView else { return }
        var p = ControlProps(id: String(UUID().uuidString.prefix(8)), kind: kind)
        switch kind {
        case "dropdown": p.placeholder = "Choose an item"; p.options = ["Option 1", "Option 2", "Option 3"]
        case "date": p.placeholder = "Click to enter a date"
        case "checkbox": p.placeholder = "☐"
        default: break
        }
        let sel = tv.selectedRange()
        let text = (kind == "text" && sel.length > 0) ? (tv.string as NSString).substring(with: sel) : p.placeholder
        var a = tv.typingAttributes
        a[.wcControl] = p.json
        tv.insertText(NSAttributedString(string: text, attributes: a), replacementRange: sel)
        sanitizeTypingAttributes(tv)
        scheduleMarkup()
    }

    func setControlText(_ r: NSRange, _ text: String) {
        guard let tv = bodyTextView, let st = tv.textStorage else { return }
        var a = st.attributes(at: r.location, effectiveRange: nil)
        a.removeValue(forKey: .foregroundColor)
        let was = applyingTracked
        applyingTracked = true
        defer { applyingTracked = was }
        if tv.shouldChangeText(in: r, replacementString: text) {
            st.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: a))
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: r.location + (text as NSString).length, length: 0))
        scheduleMarkup()
    }

    /// Called when the user clicks into text; opens a control's picker.
    func controlClicked(_ tv: NSTextView) {
        guard tv.selectedRange().length == 0, let (r, p) = controlRun(at: tv.selectedRange().location),
              let st = tv.textStorage else { return }
        let current = (st.string as NSString).substring(with: r)
        let screenRect = tv.firstRect(forCharacterRange: r, actualRange: nil)
        switch p.kind {
        case "checkbox":
            setControlText(r, current == "☒" ? "☐" : "☒")
        case "dropdown":
            let picker = MenuPicker { [weak self] t in self?.setControlText(r, t) }
            let menu = NSMenu()
            for o in p.options {
                let item = NSMenuItem(title: o, action: #selector(MenuPicker.pick(_:)), keyEquivalent: "")
                item.target = picker
                menu.addItem(item)
            }
            withExtendedLifetime(picker) { menu.popUp(positioning: nil, at: NSPoint(x: screenRect.minX, y: screenRect.minY), in: nil) }
        case "date":
            let pop = NSPopover()
            pop.behavior = .transient
            let fmt = DateFormatter(); fmt.dateStyle = .medium
            var range = r
            pop.contentViewController = NSHostingController(rootView: DateChooser(date: fmt.date(from: current) ?? Date()) { [weak self] d in
                let t = fmt.string(from: d)
                self?.setControlText(range, t)
                range = NSRange(location: range.location, length: (t as NSString).length)
            })
            let inWindow = tv.window?.convertFromScreen(screenRect) ?? .zero
            pop.show(relativeTo: tv.convert(inWindow, from: nil), of: tv, preferredEdge: .maxY)
        default:
            if current == p.placeholder { tv.setSelectedRange(r) }
        }
    }

    func editControlProperties() {
        guard let tv = bodyTextView, let (_, p) = controlRun(at: tv.selectedRange().location) else { NSSound.beep(); return }
        controlDraft = p
    }

    func applyControlProperties(_ new: ControlProps) {
        guard let tv = bodyTextView, let st = tv.textStorage, let (r, old) = controlRun(at: tv.selectedRange().location) else { controlDraft = nil; return }
        let current = (st.string as NSString).substring(with: r)
        tv.undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: r, replacementString: nil) {
            st.addAttribute(.wcControl, value: new.json, range: r)
            tv.didChangeText()
        }
        if current == old.placeholder && old.placeholder != new.placeholder { setControlText(r, new.placeholder) }
        tv.undoManager?.setActionName("Content Control")
        tv.undoManager?.endUndoGrouping()
        controlDraft = nil
        scheduleMarkup()
    }

    func removeControl() {
        guard let tv = bodyTextView, let st = tv.textStorage, let (r, _) = controlRun(at: tv.selectedRange().location),
              tv.shouldChangeText(in: r, replacementString: nil) else { return }
        st.removeAttribute(.wcControl, range: r)
        tv.didChangeText()
        scheduleMarkup()
    }
}

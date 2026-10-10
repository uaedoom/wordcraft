import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    let document: RichTextDocument
    let controller: EditorController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 3.0
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.80, alpha: 1)
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.hasHorizontalRuler = true
        scroll.hasVerticalRuler = false

        let engine = PageEngine(storage: document.storage, document: document, controller: controller)
        scroll.documentView = engine.pagesView
        engine.track(clipView: scroll.contentView)
        controller.attach(engine: engine, scrollView: scroll, document: document)
        NotificationCenter.default.addObserver(
            engine, selector: #selector(PageEngine.magnifyEnded(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        DispatchQueue.main.async {
            if let tv = engine.layoutManager.firstTextView { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

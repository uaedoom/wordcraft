# WordCraft architecture

## Layers

```
SwiftUI shell (ribbon, panes, sheets, start screen)  ── RibbonView, PowerViews, ReviewViews, StartView, WordMacApp
        │ EditorController (ObservableObject, one per document window)
        ▼
AppKit editor ── PageEngine (pages, columns, sections, footnotes, floating-object wrap)
        │        PagesView (draws pages/headers/footers/footnotes) + ObjectOverlay (shapes, pictures, text boxes)
        ▼
NSTextStorage  ── characters + custom attributes ── RichTextDocument (ReferenceFileDocument) + DocMeta
```

## Text and attributes

`RichTextDocument.storage` is the single source of truth. Custom attribute keys (see `Styles.swift`, `Objects.swift`, `Review.swift`, `Power.swift`) mark structure:

| Key | Meaning |
|---|---|
| `.wcStyle` | paragraph style id (looked up in `DocMeta.styles`) |
| `.wcSection` | section break character; value keys the page setup in `DocMeta.sectionLayouts` |
| `.wcObject` | anchor of a floating picture/shape/text box (`DocMeta.objects`) |
| `.wcImage`, `.wcEquation` | inline picture / equation props; attachments are rebuilt on load |
| `.wcFootnote`, `.wcEndnote` | note markers (text in `DocMeta.notes`) |
| `.wcRevision`, `.wcComment` | track-changes and comment anchors |
| `.wcCite`, `.wcXref`, `.wcBookmark`, `.wcCaption`, `.wcIndex`, `.wcMerge`, `.wcControl` | citations, cross-references, bookmarks, captions, index marks, merge fields, content controls |

Tables use `NSTextTable` blocks; `Tables.swift` parses a table into a grid, edits it, and re-renders it.

## Pages

TextKit 1: one `NSLayoutManager`, one container/text view per column per page. `PageEngine.reconcileOnce()` repeatedly adds/removes pages per section, switches off unused trailing columns (`PageContainer.skipped`), reserves room for footnotes, and applies exclusion paths for wrapped objects. `PagesView.dataWithPDF` renders each page for PDF export.

## Files

- `.wmdoc` package: `content.archive` (attributed string), `content.rtf` (fallback), `meta.json`, `assets/`.
- `.docx`: `DocxWriter` and `DocxReader` (own ZIP + XML in `Zip.swift`), math via `OMML.swift`, `MathRenderer.swift` draws equations.
- Other formats are imports; `File ▸ Export As` writes them.

## Review and fields

`EditorController+Review.swift` intercepts edits (`shouldAllowEdit`) to record tracked changes; markup is drawn with temporary attributes (and written into the text temporarily for PDF/print). `updateAllFields()` refreshes captions, citations, bibliography, cross-references, index and the table of contents.

## Automation

`Scripting.swift` exposes `MacroAPI` through AppleScript (`WordCraft.sdef`) and App Intents (Shortcuts).

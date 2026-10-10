# Notes for AI coding agents and new contributors

Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Essentials:

- Build: `xcodegen generate` then `xcodebuild -project WordMac.xcodeproj -scheme WordMac -configuration Debug -derivedDataPath build build`. The project file is generated; edit `project.yml`.
- The document text lives in one `NSTextStorage` (`RichTextDocument.storage`). Everything special (styles, comments, track changes, fields, equations, objects) is stored as **custom attributes on characters** (`NSAttributedString.Key` extensions such as `.wcStyle`, `.wcRevision`, `.wcComment`, `.wcObject`). Document-wide data (styles, notes, sources, section layouts, floating objects) lives in `DocMeta`.
- Pages are a layer on top of TextKit 1: `PageEngine` owns one `NSTextContainer` and `NSTextView` per page column and adds/removes pages as text flows.
- Edits that should be undoable go through `tv.shouldChangeText(in:replacementString:)` / `didChangeText()`; generated content (TOC, bibliography, fields) is rewritten with `applyingTracked = true` so it is not recorded as a tracked change.
- Scripted test scenarios (`DebugScenario.swift`, DEBUG only) let you exercise features headlessly; see `CONTRIBUTING.md`.
- **Never kill or restart other running copies of the app while testing**: launch your own instance (`open -n`) and stop only that process.
- Keep UI strings localizable (`Text("…")` literals) and add Arabic translations in `ar.lproj`.

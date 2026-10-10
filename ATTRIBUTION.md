# Attribution and third-party notes

- **No third-party code is bundled in the app.** ZIP reading/writing, the XML tree, the `.docx` reader/writer, the math renderer and the page engine are written from scratch on top of Apple frameworks (SwiftUI, AppKit/TextKit, Compression, CryptoKit, PDFKit, AppIntents).
- **Build tools** (not shipped): [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates the Xcode project; [dmgbuild](https://github.com/dmgbuild/dmgbuild) can be used to lay out the disk image (`dist/dmg-settings.py`).
- **Fonts:** the equation editor uses the system-provided STIX fonts; no fonts are embedded.
- **Microsoft:** "Microsoft" and "Word" are trademarks of Microsoft Corporation. WordCraft is independent and not endorsed by Microsoft. It reads and writes the published Office Open XML (ECMA-376 / ISO 29500) formats and contains no Microsoft code or assets.
- **App icon and name:** the WordCraft name and icon are not covered by the MIT/Apache-2.0 licenses.

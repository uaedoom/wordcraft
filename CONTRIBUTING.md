# Contributing to WordCraft

Thanks for helping! Bug reports, features, translations and documentation fixes are all welcome.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project WordMac.xcodeproj -scheme WordMac -configuration Debug -derivedDataPath build build
```

Requires macOS 15+ and Xcode 16+. The `.xcodeproj` is generated from `project.yml`; don't commit it.

## Testing without clicking

Debug builds include scripted scenarios (`WordMac/DebugScenario.swift`) that drive the editor and write a PDF or a log:

```bash
WORDMAC_SCENARIO=4 open -n build/Build/Products/Debug/WordCraft.app some.rtf   # 3 tables, 4 pictures/equations, 5 floating objects,
                                                                              # 8 track changes, 9 citations/index/merge, 10 AppleScript
```

Results are written to the app container's `tmp` folder (`~/Library/Containers/com.gamemagic.wordmac/Data/tmp/`). When testing, **start your own instance with `open -n` and only stop that process**; never kill other running copies of the app.

## Reporting bugs

Please include macOS version, what you did, what you expected, and a screenshot. For file-compatibility bugs, attach a minimal `.docx` (no private content) if you can.

## Pull requests

- Keep changes focused; match the surrounding Swift style.
- Add or update the strings in `WordMac/ar.lproj/Localizable.strings` when you add visible UI text.
- Don't add third-party code without noting it in `ATTRIBUTION.md`, and don't include Microsoft code, fonts or assets.
- By contributing you agree to license your work under the same MIT OR Apache-2.0 terms as the project.

## Translations

UI strings live in `WordMac/<lang>.lproj/Localizable.strings`. Copy `ar.lproj`, translate the right-hand sides, add the language code to `CFBundleLocalizations` in `project.yml`, and send a PR.

# Shipping WordCraft to the Mac App Store

## One-time setup
1. Join the Apple Developer Program and note your **Team ID** (Membership page).
2. In App Store Connect create a new macOS app with bundle ID `com.gamemagic.wordmac`
   (change it in `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER` if you prefer another).
3. In the developer portal enable **iCloud (CloudKit/iCloud Documents)** for the App ID and create the container
   `iCloud.com.gamemagic.wordmac`. The `AppStore` build configuration already carries the iCloud entitlements
   (`WordMac/WordCraft-AppStore.entitlements`); Debug and Release builds do not, so they run without a provisioning profile.
4. Install the *Apple Distribution* and *Mac Installer Distribution* certificates (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates).

## Build, archive, upload
```
scripts/archive-appstore.sh YOURTEAMID
```
This regenerates the Xcode project, archives with the `AppStore` configuration (hardened runtime, sandbox, iCloud),
exports a signed `.pkg` into `build/export/`, and prints the upload command. You can also open the archive in Xcode's
Organizer and press *Distribute App*.

## What is already in place
- App Sandbox with user-selected file access and printing; no network access.
- Hardened runtime in Release/AppStore.
- `PrivacyInfo.xcprivacy` (no tracking, no data collection; UserDefaults and file-timestamp reasons declared).
- `ITSAppUsesNonExemptEncryption = NO` (SHA-512 is used only to check document passwords).
- Localisations: English and Arabic (right-to-left layout). Add a language by creating `<lang>.lproj/Localizable.strings`
  and listing it in `CFBundleLocalizations` in `project.yml`.
- App icon set (16–512 pt at 1x/2x), category *Productivity*, minimum macOS 15.
- Documents: native `.wmdoc` packages; Word, RTF, text and HTML open as imports; iCloud Drive works through the standard
  Open/Save panels (the container above adds a "WordCraft" folder in iCloud Drive).
- AppleScript dictionary (`WordCraft.sdef`) and Shortcuts actions (App Intents).

## App Store Connect checklist
- Screenshots: 1280×800, 1440×900, 2560×1600 or 2880×1800 (at least one; up to ten). Suggested shots: page view with ribbon,
  track changes with review pane, mail merge preview, Arabic right-to-left document, equation editor, template gallery.
- Subtitle: "Write, review and publish documents".
- Keywords: word processor, documents, docx, writing, mail merge, citations, track changes, Arabic, RTL.
- Description (short): A full-featured word processor for the Mac with real page layout, styles, tables, equations,
  track changes, comments, citations, mail merge and Word (.docx) import and export.
- Age rating: 4+. Price/availability: set in App Store Connect.
- Review notes: "No account is needed. File ▸ New from Template… shows sample documents. Word files open as copies and are
  exported with File ▸ Export As."
- Privacy: "Data Not Collected".

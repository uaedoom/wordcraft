import SwiftUI

struct SettingsView: View {
    @AppStorage("wc.author") private var author = NSFullUserName()
    @AppStorage("wc.defaultFont") private var font = "Helvetica Neue"
    @AppStorage("wc.defaultSize") private var size = 12.0
    @AppStorage("wc.citationStyle") private var citation = "apa"
    private let families = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        TabView {
            Form {
                Section("Author") {
                    TextField("Author name", text: $author)
                    Text("Used for tracked changes and comments.").font(.caption).foregroundStyle(.secondary)
                }
                Section("New documents") {
                    Picker("Default font", selection: $font) {
                        ForEach(families.contains(font) ? families : [font] + families, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper(value: $size, in: 8...36, step: 1) { Text("Default size") + Text(": \(Int(size)) pt") }
                    Picker("Default citation style", selection: $citation) {
                        ForEach(CitationStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Text("Applies to documents you create from now on.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 340)
    }
}

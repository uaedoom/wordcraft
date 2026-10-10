import SwiftUI

/// Shared state for the start screen (shown at launch instead of the file-open panel).
final class StartState: ObservableObject {
    static let shared = StartState()
    enum Tab { case home, new }
    @Published var tab: Tab = .home
    @Published var selected = "blank"
    @Published var showFavorites = false
    @Published var recents: [RecentStore.Entry] = []
    /// Set by the start window once SwiftUI gives us `openWindow`, so the app delegate can bring it back.
    var openWindow: (() -> Void)?

    var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey: "wc.favorites") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "wc.favorites"); objectWillChange.send() }
    }

    func refreshRecents() { recents = RecentStore.entries() }

    func show(tab: Tab = .home) {
        self.tab = tab
        refreshRecents()
        openWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { StartState.shared.show() }
        return false
    }
}

struct StartView: View {
    @ObservedObject private var state = StartState.shared
    @Environment(\.openWindow) private var openWindow

    private var templates: [TemplateDef] { TemplateLibrary.builtin + TemplateLibrary.userTemplates() }
    private var featured: [TemplateDef] {
        let ids = ["blank", "letter", "report", "resume", "invoice"]
        return ids.compactMap { id in TemplateLibrary.builtin.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                Group {
                    if state.tab == .home { home } else { newTab }
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { closeWindow() }.keyboardShortcut(.cancelAction)
                    Button("Create") { create() }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(width: 1000, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            state.openWindow = { openWindow(id: "start") }
            state.refreshRecents()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { state.refreshRecents() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in state.refreshRecents() }
    }

    // MARK: Sidebar

    private func sideButton(_ symbol: String, _ title: LocalizedStringKey, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 22))
                Text(title).font(.caption)
            }
            .frame(width: 72, height: 62)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.primary.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                Text("WordCraft").font(.caption.weight(.semibold))
            }
            .padding(.top, 18).padding(.bottom, 8)
            sideButton("house", "Home", active: state.tab == .home) { state.tab = .home }
            sideButton("plus.circle", "New", active: state.tab == .new) { state.tab = .new }
            sideButton("folder", "Open") { closeWindow(); NSDocumentController.shared.openDocument(nil) }
            Spacer()
        }
        .frame(width: 96)
        .background(Color.primary.opacity(0.06))
    }

    // MARK: Home

    private func card(_ t: TemplateDef) -> some View {
        let sel = state.selected == t.id
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                if t.id != "blank" {
                    Image(systemName: t.symbol).font(.system(size: 34)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 130, height: 150)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? Color.accentColor : .clear, lineWidth: 3))
            Text(LocalizedStringKey(t.name)).font(.callout).multilineTextAlignment(.center).lineLimit(2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(sel ? Color.accentColor : .clear))
                .foregroundStyle(sel ? Color.white : Color.primary)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.selected = t.id; create() }
        .onTapGesture { state.selected = t.id }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Templates").font(.title2.weight(.semibold))
                Spacer()
                Button("More templates") { state.tab = .new }.buttonStyle(.link)
            }
            .padding(.horizontal, 24).padding(.top, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) { ForEach(featured) { card($0) } }
                    .padding(.horizontal, 24).padding(.vertical, 14)
            }
            .frame(height: 230)
            Divider().padding(.horizontal, 24)
            HStack(spacing: 8) {
                tabButton("Recents", on: !state.showFavorites) { state.showFavorites = false }
                tabButton("Favorites", on: state.showFavorites) { state.showFavorites = true }
            }
            .padding(.horizontal, 24).padding(.top, 14)
            recentsList
        }
    }

    private func tabButton(_ title: LocalizedStringKey, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.title3.weight(on ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.primary.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
    }

    private func prettyPath(_ url: URL) -> String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .split(separator: "/").joined(separator: " » ")
    }

    private var recentsList: some View {
        let items = state.showFavorites ? state.recents.filter { state.favorites.contains($0.url.path) } : state.recents
        return Group {
            if items.isEmpty {
                VStack { Spacer(); Text(state.showFavorites ? "Star a document to keep it here." : "No recent documents").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                List(items, id: \.url) { entry in
                    let url = entry.url
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.deletingPathExtension().lastPathComponent).font(.body)
                            Text(prettyPath(url)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                        Button {
                            var f = state.favorites
                            if let i = f.firstIndex(of: url.path) { f.remove(at: i) } else { f.append(url.path) }
                            state.favorites = f
                        } label: { Image(systemName: state.favorites.contains(url.path) ? "star.fill" : "star") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { open(entry) }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: New tab

    private var newTab: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], alignment: .leading, spacing: 18) {
                ForEach(templates) { card($0) }
            }
            .padding(24)
        }
    }

    // MARK: Actions

    private func closeWindow() {
        NSApp.windows.first { $0.identifier?.rawValue.contains("start") == true }?.close()
    }

    private func create() {
        let t = templates.first { $0.id == state.selected } ?? TemplateLibrary.builtin[0]
        closeWindow()
        TemplateLibrary.create(t)
    }

    private func open(_ entry: RecentStore.Entry) {
        closeWindow()
        let url = RecentStore.access(entry)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if error != nil { NSSound.beep() }
        }
    }
}


/// Documents opened or saved in WordCraft, remembered with security-scoped bookmarks so the start screen can reopen them.
enum RecentStore {
    struct Entry { var url: URL; var date: Date; var bookmark: Data? }

    private static let key = "wc.recentDocs"
    private static let limit = 30

    static func note(_ url: URL) {
        var list = (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? []
        list.removeAll { ($0["path"] as? String) == url.path }
        var item: [String: Any] = ["path": url.path, "date": Date()]
        if let b = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) { item["bookmark"] = b }
        list.insert(item, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func entries() -> [Entry] {
        var out: [Entry] = []
        var seen = Set<String>()
        for d in (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? [] {
            guard let path = d["path"] as? String else { continue }
            var url = URL(fileURLWithPath: path)
            let bookmark = d["bookmark"] as? Data
            if let bookmark {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) { url = u }
            }
            let scoped = bookmark != nil && url.startAccessingSecurityScopedResource()
            let exists = FileManager.default.fileExists(atPath: url.path)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard exists, seen.insert(url.path).inserted else { continue }
            out.append(Entry(url: url, date: d["date"] as? Date ?? .distantPast, bookmark: bookmark))
        }
        for u in NSDocumentController.shared.recentDocumentURLs where seen.insert(u.path).inserted {
            out.append(Entry(url: u, date: (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast, bookmark: nil))
        }
        return out
    }

    /// Starts security-scoped access (kept for the app's lifetime) and returns the URL to open.
    static func access(_ entry: Entry) -> URL {
        _ = entry.url.startAccessingSecurityScopedResource()
        return entry.url
    }
}

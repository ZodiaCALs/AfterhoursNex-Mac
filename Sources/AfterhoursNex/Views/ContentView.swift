import SwiftUI
import UniformTypeIdentifiers

/// Renaming, grouping, covers and feed addresses, asked for from any show's menu and answered here.
@Observable @MainActor
final class ShelfEditor {
    var renaming: Show?
    var name = ""
    var grouping: Show?
    var group = ""
    var covering: Show?
    var feeding: Show?
    var feed = ""
}

/// Where the window is: the page chosen in the sidebar, and the pages opened from it, with Back.
@Observable @MainActor
final class Navigator {
    var root: Page = .listenNow
    var stack: [Page] = []
    var current: Page { stack.last ?? root }
    func go(_ page: Page) { stack = []; root = page }
    func open(_ page: Page) { if stack.last != page { stack.append(page) } }
    func back() { if !stack.isEmpty { stack.removeLast() } }
}

/// 1.2.0's motion: Fluent's ease-out.
let fluent = Animation.timingCurve(0.1, 0.9, 0.2, 1, duration: 0.46)

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(Player.self) private var player
    @State private var editor = ShelfEditor()
    @State private var nav = Navigator()
    @State private var query = ""
    @State private var nowPlaying = false
    @State private var problem: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(nav: nav)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 330)
        } detail: {
            ZStack {
                page(nav.current)
                    .id(nav.current)
                    .transition(nav.current.drills
                        ? .asymmetric(insertion: .scale(scale: 0.965, anchor: .top).combined(with: .opacity), removal: .opacity)
                        : .asymmetric(insertion: .offset(y: 22).combined(with: .opacity), removal: .opacity))
            }
            .animation(fluent, value: nav.current)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if player.episode != nil {
                    PlayerBar(nowPlaying: $nowPlaying).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: player.episode != nil)
            .toolbar {
                if !nav.stack.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button { nav.back() } label: { Label(L("Back"), systemImage: "chevron.backward") }
                            .keyboardShortcut("[", modifiers: .command).help(L("Back"))
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: L("Shows, episodes or a link"))
        .onChange(of: query) { _, q in
            // searching starts as you type: open the Search page as soon as there's something to look for
            if !q.trimmingCharacters(in: .whitespaces).isEmpty, nav.current != .search { nav.go(.search) }
        }
        .onSubmit(of: .search) { nav.go(.search) }
        .overlay {
            if nowPlaying {
                NowPlayingView(shown: $nowPlaying)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: nowPlaying)
        .toolbar(nowPlaying ? .hidden : .visible, for: .windowToolbar)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) ?? false) }
            guard !files.isEmpty else { return false }
            nav.go(.show(store.importFiles(files).id))
            return true
        }
        .environment(editor)
        .environment(nav)
        .alert(L("Rename Show"), isPresented: Binding(get: { editor.renaming != nil }, set: { if !$0 { editor.renaming = nil } })) {
            TextField(L("Name"), text: $editor.name)
            Button(L("Rename")) {
                if let s = editor.renaming { let n = editor.name.trimmingCharacters(in: .whitespaces); store.update(s.id) { $0.alias = n == $0.title ? "" : n } }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { Text(L("Leave it empty to use the show’s own name.")) }
        .alert(L("Move to Group"), isPresented: Binding(get: { editor.grouping != nil }, set: { if !$0 { editor.grouping = nil } })) {
            TextField(L("Group name, such as Commute"), text: $editor.group)
            Button(L("Move")) { if let s = editor.grouping { store.update(s.id) { $0.group = editor.group.trimmingCharacters(in: .whitespaces) } } }
            Button(L("Cancel"), role: .cancel) {}
        } message: { Text(L("Leave it empty for no group.")) }
        .alert(L("Change Feed Address"), isPresented: Binding(get: { editor.feeding != nil }, set: { if !$0 { editor.feeding = nil } })) {
            TextField(L("Feed address"), text: $editor.feed)
            Button(L("Change")) {
                guard let s = editor.feeding else { return }
                let address = editor.feed.trimmingCharacters(in: .whitespaces)
                Task { do { try await store.changeFeed(s.id, to: address) } catch { problem = error.localizedDescription } }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { Text(L("Your name, cover, pin and group stay as they are.")) }
        .alert(L("Couldn’t change the feed"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button(L("OK")) {} } message: { Text(problem ?? "") }
        .sheet(item: $editor.covering) { CoverEditor(show: $0) }
    }

    @ViewBuilder private func page(_ p: Page) -> some View {
        switch p {
        case .listenNow: ListenNowView()
        case .discover: DiscoverView()
        case .library: LibraryView()
        case .radio: RadioView()
        case .search: SearchView(query: query)
        case .show(let id): ShowView(showID: id)
        case .preview(let preview): PreviewPage(preview: preview)
        case .episode(let hit): EpisodePage(hit: hit)
        }
    }
}

/// The sidebar, as in 1.2.0: your library, your shows (pinned, grouped, in your order), and Auto captions at the bottom.
struct Sidebar: View {
    @Environment(Store.self) private var store
    let nav: Navigator
    @AppStorage("autoCaptions") private var autoCaptions = false

    var body: some View {
        VStack(spacing: 0) {
        List(selection: Binding(get: { selection }, set: { if let p = $0 { nav.go(p) } })) {
            Section(L("Library")) {
                Label(L("Listen Now"), systemImage: "play.circle").tag(Page.listenNow)
                Label(L("Discover"), systemImage: "sparkles").tag(Page.discover)
                Label(L("Library"), systemImage: "square.stack").tag(Page.library)
                Label(L("Radio"), systemImage: "dot.radiowaves.left.and.right").tag(Page.radio)
            }
            ForEach(store.sections) { section in
                Section(section.title) {
                    ForEach(section.shows) { s in
                        Label { Text(s.name).lineLimit(1) } icon: { CoverView(show: s, size: 20) }
                            .tag(Page.show(s.id))
                            .contextMenu { ShowMenu(show: s) }
                    }
                    .onMove { from, to in store.move(section.shows.map(\.id), from: from, to: to) }
                }
            }
        }
        .listStyle(.sidebar)
        // the list ends above the switch, so the two never overlap
        Divider().padding(.horizontal, 14)
        HStack {
            Label(L("Auto captions"), systemImage: "waveform")
            Spacer()
            Toggle("", isOn: $autoCaptions).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 18).padding(.top, 9).padding(.bottom, 12)
        .help(L("Make captions on this Mac when an episode has none"))
        }
    }

    private var selection: Page? {
        switch nav.current {
        case .listenNow, .discover, .library, .radio, .show: return nav.current
        default: return nil
        }
    }
}

/// A show's menu, the same in the sidebar and the Library: rename, cover, pin, group, feed, remove (with Undo).
struct ShowMenu: View {
    let show: Show
    @Environment(Store.self) private var store
    @Environment(ShelfEditor.self) private var editor
    @Environment(Navigator.self) private var nav
    @Environment(\.undoManager) private var undo

    var body: some View {
        Button(L("Rename…")) { editor.name = show.name; editor.renaming = show }
        Button(L("Change Cover…")) { editor.covering = show }
        Button(show.pinned ? L("Unpin") : L("Pin to Top")) { store.update(show.id) { $0.pinned.toggle() } }
        Button(L("Move to Group…")) { editor.group = show.group; editor.grouping = show }
        if show.source == .rss { Button(L("Change Feed Address…")) { editor.feed = show.feedURL; editor.feeding = show } }
        Divider()
        Button(L("Remove from Library"), role: .destructive) {
            if nav.current == .show(show.id) { nav.go(.library) }
            guard let result = store.remove(show.id) else { return }
            let (removed, index) = result
            undo?.registerUndo(withTarget: store) { s in Task { @MainActor in s.restore(removed, at: index) } }
            undo?.setActionName(L("Remove Show"))
        }
    }
}

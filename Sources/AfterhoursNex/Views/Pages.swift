import SwiftUI

/// A page, as Apple Music sets them: a large title over a scrolling column, the window title hidden.
struct PageScroll<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(title).font(.system(size: 34, weight: .bold)).padding(.top, 4)
                content
            }
            .padding(.horizontal, 32).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar(removing: .title)
    }
}

/// A row of artwork that scrolls sideways and snaps to each item.
struct Shelf<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 20) { content }.scrollTargetLayout().padding(.vertical, 8)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

struct ListenNowView: View {
    @Environment(Store.self) private var store
    @Environment(Player.self) private var player
    @Environment(Navigator.self) private var nav

    var body: some View {
        PageScroll(title: L("Listen Now")) {
            if let r = store.newRelease {
                HStack {
                    Label(String(format: L("AfterhoursNex %@ is available."), r.version), systemImage: "arrow.down.circle.fill").font(.headline)
                    Spacer()
                    Button(L("Download")) { NSWorkspace.shared.open(r.url) }.glassButton(prominent: true)
                }
                .padding(16).glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
            }
            if let setup = store.setup {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("Setting up your shelf"), systemImage: "sparkles").font(.headline)
                    ProgressView(value: Double(setup.done), total: Double(max(setup.total, 1)))
                    Text(String(format: L("%d of %d shows found"), setup.done, setup.total)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(16).glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
            }
            if store.shows.isEmpty && store.setup == nil {
                ContentUnavailableView {
                    Label(L("Your shelf is empty"), systemImage: "square.stack")
                } description: {
                    Text(L("Find shows in Discover or Search, paste a feed in the Library, or drop audio files here."))
                } actions: {
                    Button(L("Discover Shows")) { nav.go(.discover) }.glassButton(prominent: true)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            }
            if !store.upNext.isEmpty {
                SectionHeader(title: L("Up Next"), subtitle: L("Pick up where you left off."))
                Shelf {
                    ForEach(store.upNext) { e in
                        let show = store.show(e.showID)
                        let spot = store.listening[e.id]
                        ArtworkCard(show: show, url: e.image, title: show?.name ?? e.title, size: 200, onPlay: { player.play(e) }, onOpen: { player.play(e) }) {
                            Text(e.title).font(.callout.weight(.semibold)).lineLimit(2)
                            Text(show?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let spot, spot.duration > 0 {
                                ProgressView(value: min(spot.position, spot.duration), total: spot.duration).tint(.nex)
                                Text(String(format: L("%@ left"), Fmt.length(spot.duration - spot.position))).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !store.shows.isEmpty && !store.pickedForYou.isEmpty {
                SectionHeader(title: L("Picked for You"), subtitle: L("Shows like the ones on your shelf."))
                Shelf { ForEach(store.pickedForYou) { PickCard(pick: $0) } }
            }
            if !store.latest.isEmpty {
                SectionHeader(title: L("Latest Episodes"))
                LazyVStack(spacing: 2) { ForEach(store.latest) { EpisodeRow(episode: $0, list: store.latest, showCover: true) } }
            }
        }
    }
}

// ---- Discover: a shelf for each category of the catalogue ----

struct DiscoverView: View {
    var body: some View {
        PageScroll(title: L("Discover")) {
            ForEach(Catalog.data.categories) { category in
                let picks = Catalog.all.filter { $0.cat == category.id }
                if !picks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: L(category.label))
                        Shelf { ForEach(picks) { PickCard(pick: $0) } }
                    }
                }
            }
        }
    }
}

struct PickCard: View {
    let pick: CatalogPick
    @Environment(Navigator.self) private var nav
    @State private var hit: ShowHit?
    @AppStorage("covers") private var covers: Data = Data()

    var body: some View {
        ArtworkCard(url: hit?.artwork ?? "", title: pick.title, size: 170,
                    onOpen: { nav.open(.preview(Preview(title: pick.title, feedURL: hit?.feedURL ?? "", term: pick.searchTerm, image: hit?.artwork ?? ""))) }) {
            Text(pick.title).font(.callout.weight(.semibold)).lineLimit(1)
            Text(pick.why ?? pick.author ?? hit?.author ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .task {
            if let cached { hit = cached; return }
            if let found = (try? await Directory.shows(pick.searchTerm, country: pick.country, limit: 4))?.first(where: { related($0.title, pick.title) }) { hit = found; remember(found) }
        }
    }

    private var cached: ShowHit? {
        guard let all = try? JSONSerialization.jsonObject(with: covers) as? [String: [String]], let v = all[pick.key], v.count == 3 else { return nil }
        return ShowHit(title: pick.title, author: v[1], artwork: v[0], feedURL: v[2], genre: "")
    }
    private func remember(_ h: ShowHit) {
        var all = (try? JSONSerialization.jsonObject(with: covers) as? [String: [String]]) ?? [:]
        all[pick.key] = [h.artwork, h.author, h.feedURL]
        covers = (try? JSONSerialization.data(withJSONObject: all)) ?? covers
    }
}

// ---- Library ----

struct LibraryView: View {
    @Environment(Store.self) private var store
    @Environment(Player.self) private var player
    @Environment(VideoTool.self) private var video
    @Environment(Navigator.self) private var nav
    @State private var address = ""
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        PageScroll(title: L("Library")) {
            HStack(spacing: 10) {
                TextField(L("Feed, website or video channel address"), text: $address).textFieldStyle(.roundedBorder).onSubmit(add)
                Button(L("Add"), action: add).glassButton(prominent: true).disabled(address.isEmpty || adding)
                Button {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK, !panel.urls.isEmpty { nav.go(.show(store.importFiles(panel.urls).id)) }
                } label: { Label(L("Import Audio Files…"), systemImage: "square.and.arrow.down") }
                .glassButton()
            }
            .frame(maxWidth: 760)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 22)], alignment: .leading, spacing: 26) {
                ForEach(store.shows) { s in
                    ArtworkCard(show: s, title: s.name, size: 170, onPlay: s.episodes.first.map { e -> () -> Void in { player.play(e, in: s.episodes) } }, onOpen: { nav.go(.show(s.id)) }) {
                        Text(s.name).font(.callout.weight(.semibold)).lineLimit(2)
                        Text(s.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contextMenu { ShowMenu(show: s) }
                }
            }
        }
        .alert(L("Couldn’t add that show"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button(L("OK")) {} } message: { Text(problem ?? "") }
    }

    private func add() {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        adding = true
        Task {
            do {
                let s: Show
                if VideoTool.handles(a) { s = try await video.show(for: a); store.add(s) } else { s = try await store.add(a) }
                address = ""; nav.go(.show(s.id))
            } catch { problem = error.localizedDescription }
            adding = false
        }
    }
}

// ---- Search: live as you type; shows, or single episodes about a topic ----

struct SearchView: View {
    let query: String
    @Environment(VideoTool.self) private var video
    @Environment(Navigator.self) private var nav
    @State private var mode = 0
    @State private var shows: [ShowHit] = []
    @State private var episodes: [EpisodeHit] = []
    @State private var videos: [EpisodeHit] = []
    @State private var busy = false
    @State private var searched = ""
    @State private var problem: String?

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        PageScroll(title: L("Search")) {
            HStack {
                Picker("", selection: $mode) { Text(L("Shows")).tag(0); Text(L("Episodes & Topics")).tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
                if busy { ProgressView().controlSize(.small).padding(.leading, 6) }
            }
            if q.isEmpty {
                ContentUnavailableView(L("Search for shows and episodes"), systemImage: "magnifyingglass", description: Text(L("Type in the search field in the sidebar.")))
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if q.hasPrefix("http") {
                Button { nav.open(.preview(Preview(title: q, feedURL: q))) } label: { Label(L("Look at this feed"), systemImage: "link") }.glassButton(prominent: true)
            } else if let problem {
                ContentUnavailableView(L("Search isn’t working right now"), systemImage: "wifi.exclamationmark", description: Text(problem)).frame(maxWidth: .infinity, minHeight: 260)
            } else if !busy && searched == "\(q)|\(mode)" && shows.isEmpty && episodes.isEmpty && videos.isEmpty {
                ContentUnavailableView.search(text: q).frame(maxWidth: .infinity, minHeight: 260)
            } else if mode == 0 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 22)], alignment: .leading, spacing: 26) {
                    ForEach(shows) { h in
                        ArtworkCard(url: h.artwork, title: h.title, size: 170, onOpen: { nav.open(.preview(Preview(title: h.title, feedURL: h.feedURL, image: h.artwork))) }) {
                            Text(h.title).font(.callout.weight(.semibold)).lineLimit(2)
                            Text([h.author, h.genre].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                if !episodes.isEmpty {
                    SectionHeader(title: L("Episodes"))
                    LazyVStack(spacing: 2) { ForEach(episodes) { HitRow(hit: $0) } }
                }
                if !videos.isEmpty {
                    SectionHeader(title: L("Videos"), subtitle: L("Played as audio."))
                    LazyVStack(spacing: 2) { ForEach(videos) { HitRow(hit: $0) } }
                }
            }
        }
        .task(id: "\(q)|\(mode)") {
            guard !q.isEmpty, !q.hasPrefix("http") else { return }
            try? await Task.sleep(for: .milliseconds(320))
            if Task.isCancelled { return }
            busy = true; problem = nil
            defer { busy = false }
            do {
                if mode == 0 { shows = try await Directory.shows(q) }
                else {
                    episodes = try await Directory.episodes(q)
                    if video.executable != nil { videos = await video.search(q) } else { videos = [] }
                }
                searched = "\(q)|\(mode)"
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
    }
}

/// An episode found by a search: click it for its page, or play it from here.
struct HitRow: View {
    let hit: EpisodeHit
    @Environment(Navigator.self) private var nav
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(show: nil, url: hit.artwork, title: hit.show, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text([hit.show, Fmt.day(hit.date), Fmt.length(hit.duration)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(hit.title).font(.body.weight(.semibold)).lineLimit(2)
                if !hit.summary.isEmpty { Text(hit.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 12)
            PlayButton(episode: hit.episode, list: [hit.episode])
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture { nav.open(.episode(hit)) }
    }
}

// ---- Radio ----

let REGIONS: [(String, String)] = [("JP", "日本"), ("CN", "中国"), ("TW", "台灣"), ("HK", "香港"), ("KR", "한국"), ("US", "United States"), ("GB", "United Kingdom"),
                                   ("FR", "France"), ("DE", "Deutschland"), ("IT", "Italia"), ("ES", "España"), ("CA", "Canada"), ("AU", "Australia")]

struct RadioView: View {
    @State private var region = Locale.current.region?.identifier ?? "US"
    @State private var term = ""
    @State private var stations: [Station] = []
    @State private var busy = false

    var body: some View {
        PageScroll(title: L("Radio")) {
            HStack(spacing: 10) {
                Picker(L("Region"), selection: $region) {
                    if !REGIONS.contains(where: { $0.0 == region }) { Text(L("Near You")).tag(region) }
                    ForEach(REGIONS.indices, id: \.self) { i in Text(REGIONS[i].1).tag(REGIONS[i].0) }
                }
                .frame(maxWidth: 240)
                TextField(L("Find a station"), text: $term).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if busy { ProgressView().controlSize(.small) }
            }
            LazyVStack(spacing: 2) { ForEach(stations) { StationRow(station: $0) } }
            Text(L("Stations come from Radio Browser, a free directory of public radio streams.")).font(.caption).foregroundStyle(.tertiary)
        }
        .task(id: "\(region)|\(term)") {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            busy = true; defer { busy = false }
            stations = (try? await Radio.stations(country: region, name: term)) ?? []
        }
    }
}

struct StationRow: View {
    let station: Station
    @State private var hovering = false
    var body: some View {
        let s = station
        HStack(spacing: 14) {
            CoverView(show: nil, url: s.favicon ?? "", title: s.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name.trimmingCharacters(in: .whitespaces)).font(.body.weight(.semibold)).lineLimit(1)
                Text(s.episode.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text([s.codec ?? "", (s.bitrate ?? 0) > 0 ? "\(s.bitrate!) kbps" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
            PlayButton(episode: s.episode, list: [s.episode])
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

// ---- previews: a show or an episode, before adding ----

struct PreviewPage: View {
    let preview: Preview
    @Environment(Store.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var show: Show?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            if let show {
                VStack(alignment: .leading, spacing: 0) {
                    ShowHeader(show: show, kicker: L("Preview")) {
                        if store.show(show.id) != nil {
                            Button { nav.go(.show(show.id)) } label: { Label(L("Open"), systemImage: "square.stack") }.glassButton(prominent: true).controlSize(.large)
                        } else {
                            Button { store.add(show); nav.go(.show(show.id)) } label: { Label(L("Add to Library"), systemImage: "plus") }.glassButton(prominent: true).controlSize(.large)
                        }
                    }
                    EpisodeList(episodes: Array(show.episodes.prefix(60)), all: show.episodes, show: show)
                }
            } else if let problem {
                ContentUnavailableView(L("Couldn’t load this show"), systemImage: "exclamationmark.triangle", description: Text(problem)).frame(maxWidth: .infinity, minHeight: 420)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar(removing: .title)
        .task {
            do {
                var feed = preview.feedURL
                if feed.isEmpty, !preview.term.isEmpty { feed = try await Directory.shows(preview.term, limit: 3).first?.feedURL ?? "" }
                guard !feed.isEmpty else { throw NexError.noFeed }
                let loaded = try await Feeds.show(from: feed)
                withAnimation(fluent) { show = loaded }
            } catch { problem = error.localizedDescription }
        }
    }
}

struct EpisodePage: View {
    let hit: EpisodeHit
    @Environment(Player.self) private var player
    @Environment(Navigator.self) private var nav

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 28) {
                    CoverView(show: nil, url: hit.artwork, title: hit.show, size: 220).shadow(color: .black.opacity(0.3), radius: 22, y: 10)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Episode")).font(.caption.weight(.semibold)).foregroundStyle(.tint).textCase(.uppercase)
                        if !hit.feedURL.isEmpty {
                            Button(hit.show) { nav.open(.preview(Preview(title: hit.show, feedURL: hit.feedURL, image: hit.artwork))) }.buttonStyle(.link).font(.title3.weight(.medium))
                        } else { Text(hit.show).font(.title3.weight(.medium)).foregroundStyle(.secondary) }
                        Text(hit.title).font(.system(size: 30, weight: .bold)).lineLimit(4)
                        Text([Fmt.day(hit.date), Fmt.length(hit.duration)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button { player.play(hit.episode, in: [hit.episode]) } label: { Label(L("Play"), systemImage: "play.fill") }.glassButton(prominent: true).controlSize(.large)
                            if !hit.feedURL.isEmpty {
                                Button { nav.open(.preview(Preview(title: hit.show, feedURL: hit.feedURL, image: hit.artwork))) } label: { Label(L("Open Show"), systemImage: "square.stack") }
                                    .glassButton().controlSize(.large)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                if !hit.summary.isEmpty { Text(hit.summary).font(.body).foregroundStyle(.secondary).frame(maxWidth: 720, alignment: .leading) }
            }
            .padding(.horizontal, 32).padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar(removing: .title)
    }
}

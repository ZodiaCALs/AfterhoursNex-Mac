import SwiftUI

struct ShowView: View {
    let showID: String
    @Environment(Store.self) private var store
    @Environment(Player.self) private var player
    @Environment(VideoTool.self) private var video
    @State private var newestFirst = true

    var body: some View {
        if let show = store.show(showID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ShowHeader(show: show) {
                        if let first = show.episodes.first {
                            Button { player.play(first, in: show.episodes) } label: { Label(L("Play Latest"), systemImage: "play.fill") }
                                .glassButton(prominent: true).controlSize(.large)
                        }
                        if show.source != .local {
                            Button {
                                Task {
                                    if show.source == .video, let fresh = try? await video.show(for: show.feedURL) { store.update(show.id) { $0.episodes = fresh.episodes } }
                                    else { await store.refresh(show.id) }
                                }
                            } label: { Image(systemName: "arrow.clockwise") }
                            .glassButton().controlSize(.large).help(L("Refresh")).disabled(store.refreshing.contains(show.id))
                        }
                        if let link = URL(string: show.link), !show.link.isEmpty {
                            Link(destination: link) { Image(systemName: "safari") }.glassButton().controlSize(.large).help(L("Website"))
                        }
                        Menu { ShowMenu(show: show) } label: { Image(systemName: "ellipsis") }.menuStyle(.button).menuIndicator(.hidden).glassButton().controlSize(.large).fixedSize()
                    }
                    HStack {
                        Text(String(format: L("%d Episodes"), show.episodes.count)).font(.title3.bold())
                        Spacer()
                        Picker("", selection: $newestFirst) { Text(L("Newest First")).tag(true); Text(L("Oldest First")).tag(false) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .padding(.horizontal, 32).padding(.top, 6).padding(.bottom, 4)
                    EpisodeList(episodes: newestFirst ? show.episodes : Array(show.episodes.reversed()), all: show.episodes, show: show)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbar(removing: .title)
        } else {
            ContentUnavailableView(L("This show isn’t in your library"), systemImage: "square.stack")
        }
    }
}

/// A show's header, as Apple Music sets an album: the artwork, the title and maker, and the actions, over a wash of the
/// cover's own colour that reaches under the sidebar.
struct ShowHeader<Actions: View>: View {
    let show: Show
    var kicker: String? = nil
    @ViewBuilder var actions: Actions
    @State private var tint: Color?

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            CoverView(show: show, size: 220).shadow(color: .black.opacity(0.3), radius: 22, y: 10)
            VStack(alignment: .leading, spacing: 8) {
                if let kicker { Text(kicker).font(.caption.weight(.semibold)).foregroundStyle(.tint).textCase(.uppercase) }
                Text(show.name).font(.system(size: 34, weight: .bold)).lineLimit(3)
                if !show.author.isEmpty { Text(show.author).font(.title3.weight(.medium)).foregroundStyle(.tint) }
                if !show.summary.isEmpty { Text(show.summary).font(.callout).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: 640, alignment: .leading) }
                HStack(spacing: 10) { actions }.padding(.top, 8)
            }
        }
        .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(colors: [(tint ?? .clear).opacity(0.5), (tint ?? .clear).opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .backgroundExtensionEffect()
        }
        .task(id: show.id) {
            if let d = Design(show.coverDesign) { withAnimation(.easeOut(duration: 0.4)) { tint = DESIGNS[d.gradient % DESIGNS.count][0] }; return }
            let address = show.coverFile.isEmpty ? show.image : AppFolder.dir("covers").appendingPathComponent(show.coverFile).absoluteString
            if let c = await ArtColors.shared.color(for: address) { withAnimation(.easeOut(duration: 0.45)) { tint = c } }
        }
    }
}

/// A show's episodes, as rows.
struct EpisodeList: View {
    let episodes: [Episode]
    let all: [Episode]
    var show: Show? = nil
    var body: some View {
        LazyVStack(spacing: 2) { ForEach(episodes) { EpisodeRow(episode: $0, list: all, show: show) } }
            .padding(.horizontal, 20).padding(.bottom, 24)
    }
}

/// An episode: its day and length, title, notes, how far through, and a play button; highlighted while it plays.
struct EpisodeRow: View {
    let episode: Episode
    var list: [Episode] = []
    var show: Show? = nil
    var showCover = false
    @Environment(Store.self) private var store
    @Environment(Player.self) private var player
    @State private var hovering = false

    var body: some View {
        let s = show ?? store.show(episode.showID)
        let spot = store.listening[episode.id]
        let current = player.episode?.id == episode.id
        HStack(alignment: .center, spacing: 14) {
            if showCover { CoverView(show: s, url: episode.image, title: s?.name ?? "", size: 52) }
            VStack(alignment: .leading, spacing: 3) {
                Text([showCover ? s?.name ?? "" : "", Fmt.day(episode.date), Fmt.length(episode.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.weight(.medium)).foregroundStyle(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(episode.title).font(.body.weight(.semibold)).lineLimit(2)
                if !episode.summary.isEmpty { Text(episode.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if let spot, spot.done { Label(L("Played"), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                else if let spot, spot.duration > 0, spot.position > 30 {
                    Text(String(format: L("%@ left"), Fmt.length(spot.duration - spot.position))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            PlayButton(episode: episode, list: list, show: s)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(current ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0))))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture(count: 2) { player.play(episode, in: list, show: s) }
        .contextMenu {
            Button(L("Play")) { player.play(episode, in: list, show: s) }
            Divider()
            Button(L("Mark as Played")) { store.markPlayed(episode, true) }
            Button(L("Mark as Unplayed")) { store.markPlayed(episode, false) }
        }
    }
}

/// Play or pause, with a ring showing how far through the episode is.
struct PlayButton: View {
    let episode: Episode
    var list: [Episode] = []
    var show: Show? = nil
    @Environment(Player.self) private var player
    @Environment(Store.self) private var store

    var body: some View {
        let current = player.episode?.id == episode.id
        let spot = store.listening[episode.id]
        Button {
            if current { player.toggle() } else { player.play(episode, in: list, show: show) }
        } label: {
            ZStack {
                Circle().fill(.tint.opacity(current ? 0.2 : 0.12))
                if let spot, spot.duration > 0, !spot.done, spot.position > 30 {
                    Circle().trim(from: 0, to: min(1, spot.position / spot.duration)).stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(Pressable())
        .help(current && player.isPlaying ? L("Pause") : L("Play"))
    }
}

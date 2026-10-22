import SwiftUI

/// The player at the bottom of the window, as in 1.2.0: what's playing, the transport and a slim scrubber, and speed,
/// captions, sleep and Now Playing, on a floating bar of glass.
struct PlayerBar: View {
    @Binding var nowPlaying: Bool
    @Environment(Player.self) private var player
    @Environment(Store.self) private var store
    @AppStorage("showCaptions") private var showCaptions = true

    var body: some View {
        if let e = player.episode {
            HStack(spacing: 16) {
                Button { nowPlaying = true } label: {
                    HStack(spacing: 11) {
                        CoverView(show: store.show(e.showID), url: e.image, title: player.showName, size: 44)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(player.status.isEmpty ? player.showName : player.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
                .help(L("Now Playing"))

                VStack(spacing: 5) {
                    HStack(spacing: 22) {
                        control("gobackward.15", L("Back 15 Seconds"), 16) { player.skip(by: -15) }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white).frame(width: 36, height: 36).background(Circle().fill(.tint))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(Pressable()).help(player.isPlaying ? L("Pause") : L("Play"))
                        control("goforward.30", L("Forward 30 Seconds"), 16) { player.skip(by: 30) }
                    }
                    if player.isLive {
                        Label(L("Live"), systemImage: "dot.radiowaves.left.and.right").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    } else {
                        SlimScrubber()
                    }
                }
                .frame(maxWidth: 440)

                HStack(spacing: 4) {
                    Menu {
                        Picker(L("Playback Speed"), selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                            ForEach(SPEEDS, id: \.self) { s in Text(s == 1 ? speedLabel(s) + " · " + L("Normal") : speedLabel(s)).tag(s) }
                        }
                        .pickerStyle(.inline)
                    } label: { Text(speedLabel(player.speed)).font(.callout.weight(.semibold).monospacedDigit()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Playback Speed"))
                    control(showCaptions ? "captions.bubble.fill" : "captions.bubble", L("Captions"), 15, tint: showCaptions) { showCaptions.toggle() }
                    SleepMenu(compact: true)
                    control("arrow.up.left.and.arrow.down.right", L("Now Playing"), 14) { nowPlaying = true }
                }
                .frame(minWidth: 170, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: false)
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 14)
        }
    }

    private func control(_ symbol: String, _ help: String, _ size: CGFloat, tint: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 30, height: 30)
                .foregroundStyle(tint ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)).contentShape(Rectangle())
        }
        .buttonStyle(Pressable()).help(help)
    }
}

/// A slim scrubber, with the time either side: drag it to seek, and the playing place stays put until you let go.
struct SlimScrubber: View {
    @Environment(Player.self) private var player
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        let length = max(player.duration, 1)
        let at = dragging ?? player.position
        HStack(spacing: 8) {
            Text(Fmt.clock(at)).frame(width: 46, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.14))
                    Capsule().fill(.primary.opacity(0.75)).frame(width: max(0, min(1, at / length)) * geo.size.width)
                }
                .frame(height: hovering || dragging != nil ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in dragging = max(0, min(1, g.location.x / geo.size.width)) * length }
                    .onEnded { _ in if let d = dragging { player.seek(to: d) }; dragging = nil })
            }
            .frame(height: 14)
            .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
            Text("-" + Fmt.clock(max(0, length - at))).frame(width: 52, alignment: .leading)
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
}

/// The sleep timer: off, a set time, or the end of the episode.
struct SleepMenu: View {
    var compact = false
    @Environment(Player.self) private var player
    @State private var minutes = 0

    var body: some View {
        Menu {
            Picker(L("Sleep Timer"), selection: Binding(get: { player.sleepAtEnd ? -1 : (player.sleepEnd == nil ? 0 : minutes) }, set: { m in
                minutes = m
                if m == -1 { player.sleepAtEndOfEpisode() } else { player.sleep(minutes: m == 0 ? nil : m) }
            })) {
                Text(L("Off")).tag(0)
                ForEach([15, 30, 45, 60], id: \.self) { m in Text(String(format: L("%d minutes"), m)).tag(m) }
                Text(L("End of This Episode")).tag(-1)
            }
            .pickerStyle(.inline)
        } label: {
            if compact {
                Image(systemName: player.sleepEnd != nil || player.sleepAtEnd ? "moon.zzz.fill" : "moon.zzz").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(player.sleepEnd != nil || player.sleepAtEnd ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            } else {
                Label(label, systemImage: "moon.zzz")
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Sleep Timer"))
    }

    private var label: String {
        if player.sleepAtEnd { return L("End of Episode") }
        if let end = player.sleepEnd { return String(format: L("%d min left"), max(1, Int(end.timeIntervalSinceNow / 60))) }
        return L("Sleep")
    }
}

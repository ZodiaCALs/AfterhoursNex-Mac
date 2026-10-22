import SwiftUI
import Translation
import UniformTypeIdentifiers

/// The languages captions can be translated into.
let LANGUAGES: [(String, String)] = [("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"), ("ko", "한국어"),
                                     ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"), ("pt", "Português")]

/// Now Playing over the whole window, as in 1.2.0 and Apple Music: the cover blurred behind everything, the artwork,
/// title and controls on the left, and the captions rolling on the right.
struct NowPlayingView: View {
    @Binding var shown: Bool
    @Environment(Player.self) private var player
    @Environment(Store.self) private var store
    @AppStorage("showCaptions") private var showCaptions = true

    @AppStorage("translate") private var translate = false

    var body: some View {
        let e = player.episode
        let show = e.flatMap { store.show($0.showID) }
        let art = e.map { $0.image.isEmpty ? (show?.image ?? "") : $0.image } ?? ""
        GeometryReader { geo in
            let cover = max(180, min(340, geo.size.height - 440, geo.size.width * 0.3))
            HStack(alignment: .center, spacing: 48) {
                VStack(alignment: .leading, spacing: 18) {
                    CoverView(show: show, url: e?.image ?? "", title: player.showName, size: cover)
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                        .scaleEffect(player.isPlaying ? 1 : 0.93)
                        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: player.isPlaying)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e?.title ?? "").font(.title2.bold()).lineLimit(3)
                        Text(player.status.isEmpty ? player.showName : player.status).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if player.isLive {
                        Label(L("Live"), systemImage: "dot.radiowaves.left.and.right").font(.callout.weight(.semibold)).foregroundStyle(.red)
                    } else {
                        SlimScrubber()
                    }
                    BigTransport()
                    HStack {
                        Menu {
                            Picker(L("Playback Speed"), selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                                ForEach(SPEEDS, id: \.self) { s in Text(s == 1 ? speedLabel(s) + " · " + L("Normal") : speedLabel(s)).tag(s) }
                            }
                            .pickerStyle(.inline)
                        } label: { Label(speedLabel(player.speed), systemImage: "gauge.with.dots.needle.33percent") }
                        .menuStyle(.button).glassButton().fixedSize()
                        Spacer()
                        SleepMenu().glassButton()
                    }
                }
                .frame(width: max(cover, 320))
                Group {
                    if showCaptions {
                        CaptionsPanel()
                    } else {
                        ScrollView { Text(e?.summary ?? "").font(.title3).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .frame(maxWidth: 680, maxHeight: .infinity)
            }
            .padding(.horizontal, 52).padding(.top, 78).padding(.bottom, 40)
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .top) { topBar }
        }
        .background {
            ZStack {
                Color.black
                CachedImage(address: art, points: 160).scaleEffect(1.4).blur(radius: 80).saturation(1.6).opacity(0.9)
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    /// Back to the window on the left; translation and captions on the right.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { shown = false } label: {
                Label(L("Back"), systemImage: "chevron.down").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.plain).glass(in: Capsule()).keyboardShortcut(.cancelAction).help(L("Close Now Playing"))
            Spacer()
            Button { translate.toggle() } label: {
                Label(L("Translate"), systemImage: "character.bubble").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(translate ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain).glass(in: Capsule()).help(L("Translate captions"))
            Button { withAnimation(fluent) { showCaptions.toggle() } } label: {
                Label(L("Captions"), systemImage: showCaptions ? "captions.bubble.fill" : "captions.bubble").font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(showCaptions ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain).glass(in: Capsule()).help(L("Captions"))
        }
        .padding(.horizontal, 22).padding(.top, 18)
    }
}

/// The transport: round controls of glass that come together into one surface, the play button larger and tinted.
struct BigTransport: View {
    @Environment(Player.self) private var player
    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                round("gobackward.15", L("Back 15 Seconds"), 48) { player.skip(by: -15) }
                round(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? L("Pause") : L("Play"), 66, tint: true) { player.toggle() }
                round("goforward.30", L("Forward 30 Seconds"), 48) { player.skip(by: 30) }
                round("forward.end.fill", L("Next Episode"), 42) { player.next() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func round(_ symbol: String, _ help: String, _ size: CGFloat, tint: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.36, weight: .semibold)).frame(width: size, height: size)
                .foregroundStyle(tint ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background { if tint { Circle().fill(.tint) } }
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .glass(in: Circle())
        .help(help)
    }
}

/// The captions, rolling as the episode plays: the spoken line bright, the rest dimmed, translations underneath.
struct CaptionsPanel: View {
    @Environment(Captions.self) private var captions
    @Environment(Player.self) private var player
    @AppStorage("translate") private var translate = false
    @AppStorage("translateTo") private var target = "ja"
    @State private var config: TranslationSession.Configuration?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(L("Captions")).font(.headline)
                Spacer()
                Toggle(L("Translate"), isOn: $translate).toggleStyle(.switch).controlSize(.small)
                Picker("", selection: $target) { ForEach(LANGUAGES.indices, id: \.self) { i in Text(LANGUAGES[i].1).tag(LANGUAGES[i].0) } }
                    .labelsHidden().fixedSize().disabled(!translate)
                Menu {
                    Button(L("Load Captions…")) { importing = true }
                    if let e = player.episode {
                        Button(captions.cues.isEmpty ? L("Make Captions") : L("Make Captions Again")) { captions.forget(e.id); captions.make(e) }
                    }
                    if captions.working { Button(L("Stop Making Captions")) { captions.stop() } }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if !captions.status.isEmpty {
                HStack(spacing: 8) {
                    if captions.progress >= 0 { ProgressView(value: captions.progress).frame(width: 120) } else { ProgressView().controlSize(.small) }
                    Text(captions.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if captions.cues.isEmpty {
                Spacer()
                Text(L("No captions for this episode yet. Load a caption file, or make captions on this Mac from the ⋯ menu.")).font(.title3).foregroundStyle(.secondary)
                Spacer()
            } else {
                rolling
            }
        }
        .translationTask(config) { session in await translateNearby(session) }
        .onChange(of: translate) { refresh() }
        .onChange(of: target) { captions.translations = [:]; config = nil; refresh() }
        .onChange(of: captions.active) { if translate { config?.invalidate() } }
        .onAppear { refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "vtt") ?? .text, UTType(filenameExtension: "srt") ?? .text, .json, .plainText]) { result in
            if case .success(let url) = result { captions.importFile(url) }
        }
    }

    private var rolling: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(captions.cues.enumerated()), id: \.offset) { i, cue in
                        let on = i == captions.active
                        VStack(alignment: .leading, spacing: 5) {
                            if !cue.speaker.isEmpty, i == 0 || captions.cues[i - 1].speaker != cue.speaker {
                                Text(cue.speaker).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(cue.text).font(.system(size: 26, weight: .bold)).foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            if translate, let t = captions.translations[cue.text] {
                                Text(t).font(.title3.weight(.medium)).foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                            }
                        }
                        .scaleEffect(on ? 1 : 0.975, anchor: .leading)
                        .id(i)
                        .contentShape(Rectangle())
                        .onTapGesture { player.seek(to: cue.start) }
                        .animation(.easeOut(duration: 0.4), value: on)
                    }
                }
                .padding(.vertical, 180)
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: captions.active) { _, i in
                guard i >= 0 else { return }
                withAnimation(.smooth(duration: 0.65)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.32)) }
            }
            .onChange(of: captions.translations.count) {
                guard captions.active >= 0 else { return }
                proxy.scrollTo(captions.active, anchor: UnitPoint(x: 0, y: 0.32))
            }
        }
    }

    private func refresh() { config = translate ? TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: target)) : nil }

    /// Translates the lines around the one being spoken, a few at a time, on this Mac.
    private func translateNearby(_ session: TranslationSession) async {
        let cues = captions.cues
        guard !cues.isEmpty else { return }
        let from = max(0, captions.active - 2), to = min(cues.count, max(captions.active, 0) + 14)
        guard from < to else { return }
        let todo = Array(Set(cues[from..<to].map(\.text))).filter { captions.translations[$0] == nil }
        guard !todo.isEmpty else { return }
        if let replies = try? await session.translations(from: todo.map { TranslationSession.Request(sourceText: $0) }) {
            for r in replies { captions.translations[r.sourceText] = r.targetText }
        }
    }
}

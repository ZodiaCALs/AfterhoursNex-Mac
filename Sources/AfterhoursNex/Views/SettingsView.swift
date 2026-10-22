import Speech
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }
            PlaybackSettings().tabItem { Label(L("Playback"), systemImage: "play.circle") }
            CaptionSettings().tabItem { Label(L("Captions"), systemImage: "captions.bubble") }
            VideoSettings().tabItem { Label(L("Video"), systemImage: "play.rectangle") }
            PhoneSettings().tabItem { Label(L("Phone"), systemImage: "iphone") }
            StorageSettings().tabItem { Label(L("Storage"), systemImage: "internaldrive") }
        }
        .frame(width: 580, height: 440)
    }
}

struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("glass") private var glass = "regular"
    @AppStorage("checkUpdates") private var checkUpdates = true
    @AppStorage("updateRepo") private var updateRepo = ""
    @State private var note = ""

    var body: some View {
        Form {
            Picker(L("Appearance"), selection: $appearance) { Text(L("System")).tag("system"); Text(L("Light")).tag("light"); Text(L("Dark")).tag("dark") }
                .pickerStyle(.segmented)
            Picker(L("Glass"), selection: $glass) { Text(L("Regular")).tag("regular"); Text(L("Clear")).tag("clear") }.pickerStyle(.segmented)
            Text(L("Clear glass lets more of the page show through. With Reduce Transparency on in System Settings, controls are solid.")).font(.caption).foregroundStyle(.secondary)
            Section(L("Language")) {
                Text(L("AfterhoursNex follows your Mac’s language. To choose another, open System Settings › General › Language & Region › Applications.")).foregroundStyle(.secondary)
            }
            Section(L("Updates")) {
                Toggle(L("Check for updates"), isOn: $checkUpdates)
                if Updates.repo.isEmpty { TextField(L("GitHub repository"), text: $updateRepo, prompt: Text("owner/Afterhours-Nex")) }
                HStack {
                    Button(L("Check Now")) {
                        Task {
                            if let r = await Updates.latest() { store.newRelease = r; note = String(format: L("AfterhoursNex %@ is available."), r.version) }
                            else { note = L("AfterhoursNex is up to date.") }
                        }
                    }
                    Text(note).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PlaybackSettings: View {
    @Environment(Player.self) private var player
    @AppStorage("continuous") private var continuous = true

    var body: some View {
        Form {
            Picker(L("Speed"), selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) { ForEach(SPEEDS, id: \.self) { Text(speedLabel($0)).tag($0) } }
            Toggle(L("Play the next episode automatically"), isOn: $continuous)
            Text(L("Back skips 15 seconds and Forward skips 30: from the toolbar, the Controls menu, your keyboard’s media keys and Control Center.")).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct CaptionSettings: View {
    @AppStorage("autoCaptions") private var autoCaptions = false
    @AppStorage("speechLocale") private var speechLocale = ""
    @AppStorage("captionModel") private var model = "auto"
    @AppStorage("translateTo") private var target = "ja"

    var body: some View {
        Form {
            Section(L("Auto captions")) {
                Toggle(L("Make captions on this Mac when an episode has none"), isOn: $autoCaptions)
                Picker(L("Spoken language"), selection: $speechLocale) {
                    Text(L("Your Mac’s language")).tag("")
                    ForEach(locales, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
                }
            }
            Section(L("Speech model")) {
                Picker(L("Model"), selection: $model) {
                    Text(L("Automatic")).tag("auto")
                    Text("SpeechAnalyzer").tag("analyzer")
                    Text(L("Classic speech recognition")).tag("classic")
                }
                Text(model == "classic"
                     ? L("Apple’s classic speech recognition. It works for the most languages, and needs nothing to download.")
                     : model == "analyzer"
                        ? L("Apple’s newer speech model, made for long recordings like podcasts. Its language models download once and are kept by macOS.")
                        : L("SpeechAnalyzer when it knows the language, and classic speech recognition when it doesn’t."))
                    .foregroundStyle(.secondary)
                if model != "classic" { SpeechModelRow(localeID: speechLocale) }
            }
            Section(L("Translation")) {
                Picker(L("Translate into"), selection: $target) { ForEach(LANGUAGES.indices, id: \.self) { i in Text(LANGUAGES[i].1).tag(LANGUAGES[i].0) } }
                Text(L("Translation uses Apple’s translation on this Mac. Languages download the first time you need them, and you manage them in System Settings.")).foregroundStyle(.secondary)
                Button(L("Open Translation Languages…")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!) }
            }
        }
        .formStyle(.grouped)
    }

    private var locales: [String] { SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted() }
}

/// The SpeechAnalyzer model for the spoken language: whether it's on this Mac, and a download when it isn't.
struct SpeechModelRow: View {
    let localeID: String
    @State private var state = ""
    @State private var progress: Double = -1

    var body: some View {
        HStack {
            Label(state.isEmpty ? L("Checking…") : state, systemImage: state == L("Downloaded") ? "checkmark.circle.fill" : "cpu")
                .foregroundStyle(state == L("Downloaded") ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            Spacer()
            if progress >= 0 {
                ProgressView(value: progress).frame(width: 120)
            } else if state == L("Not downloaded yet") {
                Button(L("Download Model")) {
                    Task {
                        progress = 0
                        do {
                            if let locale = await SpeechModels.locale(for: localeID) {
                                try await SpeechModels.install(locale) { p in Task { @MainActor in progress = p } }
                            }
                        } catch { state = error.localizedDescription }
                        progress = -1
                        await check()
                    }
                }
            }
        }
        .task(id: localeID) { await check() }
    }

    private func check() async {
        guard let locale = await SpeechModels.locale(for: localeID) else { state = L("Not available for this language"); return }
        state = await SpeechModels.installed(locale) ? L("Downloaded") : L("Not downloaded yet")
    }
}

struct VideoSettings: View {
    @Environment(VideoTool.self) private var video

    var body: some View {
        Form {
            Section(L("Video podcasts")) {
                if let exe = video.executable {
                    Text(String(format: L("Ready. YouTube and Bilibili videos, channels and playlists play as audio, using yt-dlp at %@."), exe.path)).foregroundStyle(.secondary)
                    HStack {
                        Button(L("Update")) { Task { await video.update() } }.disabled(video.working)
                        if video.installedByApp { Button(L("Remove"), role: .destructive) { video.remove() } }
                    }
                } else {
                    Text(L("Play YouTube and Bilibili videos, channels and playlists as audio. AfterhoursNex downloads its video tool, yt-dlp (about 35 MB), only if you want it."))
                        .foregroundStyle(.secondary)
                    Button(L("Add Video Podcasts")) { Task { await video.install() } }.buttonStyle(.borderedProminent).disabled(video.working)
                }
                if video.working { ProgressView().controlSize(.small) }
                if !video.note.isEmpty { Text(video.note).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @State private var sizes: [String: Int64] = [:]

    var body: some View {
        Form {
            Section(L("Kept on this Mac")) {
                row(L("Captions"), "captions")
                row(L("Video audio"), "video")
                LabeledContent(L("Cover art")) {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(URLCache.shared.currentDiskUsage), countStyle: .file)).foregroundStyle(.secondary)
                        Button(L("Clear")) { URLCache.shared.removeAllCachedResponses(); measure() }
                    }
                }
            }
            Text(L("Each of these is made or downloaded again when it’s needed.")).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear(perform: measure)
    }

    private func row(_ label: String, _ folder: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: sizes[folder] ?? 0, countStyle: .file)).foregroundStyle(.secondary)
                Button(L("Clear")) { try? FileManager.default.removeItem(at: AppFolder.url(folder)); measure() }
            }
        }
    }

    private func measure() {
        for folder in ["captions", "video"] {
            var total: Int64 = 0
            if let e = FileManager.default.enumerator(at: AppFolder.url(folder), includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            sizes[folder] = total
        }
    }
}

struct PhoneSettings: View {
    @Environment(PhoneAccess.self) private var phone

    var body: some View {
        Form {
            Section(L("Use on your phone")) {
                Toggle(L("Phone access"), isOn: Binding(get: { phone.on }, set: { phone.setOn($0) }))
                Text(L("Phones on the same Wi-Fi can use AfterhoursNex in their browser, and the AfterhoursNex phone app can use this Mac’s auto captions and video podcasts. Only someone with the private link can get in."))
                    .foregroundStyle(.secondary)
                if !phone.problem.isEmpty { Text(phone.problem).foregroundStyle(.red) }
                if phone.on {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = PhoneAccess.qrCode(phone.link) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 128, height: 128).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Scan the code with your phone’s camera, or open this link on it:")).foregroundStyle(.secondary)
                            Text(phone.link).font(.callout.monospaced()).textSelection(.enabled)
                            HStack {
                                Button(L("Copy Link")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(phone.link, forType: .string) }
                                Button(L("New Link")) { phone.newLink() }.help(L("Makes a new private link; the old one stops working."))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}


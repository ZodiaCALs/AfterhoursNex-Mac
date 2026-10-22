import AppKit
import SwiftUI

/// AfterhoursNex for Mac: a podcast player for the late hours, in Liquid Glass, built with SwiftUI and the Mac's own frameworks.
@main
struct AfterhoursNexApp: App {
    @State private var store = Store()
    @State private var player = Player()
    @State private var captions = Captions()
    @State private var video = VideoTool()
    @State private var phone = PhoneAccess()
    @AppStorage("appearance") private var appearance = "system"

    init() {
        // covers come from the web once, then from disk; the memory cache keeps only what's on screen
        URLCache.shared = URLCache(memoryCapacity: 8 << 20, diskCapacity: 256 << 20)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store).environment(player).environment(captions).environment(video).environment(phone)
                .tint(Color.nex)
                .onAppear {
                    player.attach(store: store, captions: captions, video: video)
                    phone.video = video
                    phone.resume()
                    apply(appearance)
                }
                .onChange(of: appearance) { _, value in apply(value) }
                .task { await store.setUpStarterShelf(); await store.refreshAll(); await store.checkForUpdates() }
        }
        .defaultSize(width: 1220, height: 800)
        .commands {
            PlayerCommands(player: player)
            CommandGroup(after: .importExport) {
                Button(L("Import OPML…")) { OPML.importPanel(into: store) }
                Button(L("Export OPML…")) { OPML.exportPanel(store.shows) }
                Button(L("Import Audio Files…")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio]
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { store.importFiles(panel.urls) }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(store).environment(player).environment(captions).environment(video).environment(phone)
                .tint(Color.nex)
        }
    }

    private func apply(_ value: String) {
        NSApp.appearance = value == "light" ? NSAppearance(named: .aqua) : value == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

/// The Controls menu, with the shortcuts Mac media apps use.
struct PlayerCommands: Commands {
    let player: Player
    var body: some Commands {
        CommandMenu(L("Controls")) {
            Button(player.isPlaying ? L("Pause") : L("Play")) { player.toggle() }.keyboardShortcut(.space, modifiers: [])
            Divider()
            Button(L("Back 15 Seconds")) { player.skip(by: -15) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button(L("Forward 30 Seconds")) { player.skip(by: 30) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button(L("Next Episode")) { player.next() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Button(L("Faster")) { player.faster() }.keyboardShortcut("=", modifiers: [.command, .option])
            Button(L("Slower")) { player.slower() }.keyboardShortcut("-", modifiers: [.command, .option])
        }
    }
}

/// A localised string from the app's Localizable.strings (English is the key itself).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

extension Color {
    /// The AfterhoursNex pink: deeper in light mode, softer in dark mode, readable on glass in both.
    static let nex = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.51, blue: 0.68, alpha: 1)
            : NSColor(srgbRed: 0.76, green: 0.18, blue: 0.40, alpha: 1)
    })
}

/// Liquid Glass, as macOS 27 refines it: glass only for controls and floating surfaces, never under body text, clear or
/// regular as the listener prefers, and a solid surface when Reduce Transparency is on.
struct NexGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = true
    @AppStorage("glass") private var variant = "regular"
    @Environment(\.accessibilityReduceTransparency) private var reduce

    @ViewBuilder func body(content: Content) -> some View {
        if reduce {
            content.background(.background.secondary, in: shape)
        } else {
            let glass: Glass = variant == "clear" ? .clear : .regular
            content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        }
    }
}

extension View {
    func glass<S: Shape>(in shape: S, interactive: Bool = true) -> some View { modifier(NexGlass(shape: shape, interactive: interactive)) }

    /// The glass button style, or a plain bordered one when Reduce Transparency is on.
    func glassButton(prominent: Bool = false) -> some View { modifier(GlassButton(prominent: prominent)) }
}

struct GlassButton: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @ViewBuilder func body(content: Content) -> some View {
        if reduce { if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) } }
        else if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
    }
}

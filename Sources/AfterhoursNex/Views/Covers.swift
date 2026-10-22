import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The gradients a designed cover can use, from the AfterhoursNex palette.
let DESIGNS: [[Color]] = [
    [Color(red: 1.00, green: 0.51, blue: 0.68), Color(red: 0.71, green: 0.27, blue: 0.55)], [Color(red: 1.00, green: 0.73, blue: 0.37), Color(red: 0.95, green: 0.45, blue: 0.47)],
    [Color(red: 0.56, green: 0.49, blue: 1.00), Color(red: 0.29, green: 0.25, blue: 0.82)], [Color(red: 0.31, green: 0.82, blue: 0.77), Color(red: 0.17, green: 0.48, blue: 0.61)],
    [Color(red: 0.97, green: 0.57, blue: 0.43), Color(red: 0.42, green: 0.25, blue: 0.82)], [Color(red: 0.60, green: 0.90, blue: 0.71), Color(red: 0.18, green: 0.52, blue: 0.35)],
    [Color(red: 0.89, green: 0.91, blue: 0.94), Color(red: 0.44, green: 0.50, blue: 0.59)], [Color(red: 0.23, green: 0.21, blue: 0.31), Color(red: 0.05, green: 0.05, blue: 0.07)],
]

/// A designed cover: a gradient, a typeface and the words on it ("g=<gradient>;f=<serif|sans>;t=<words>").
struct Design {
    var gradient: Int
    var serif: Bool
    var words: String
    init(gradient: Int, serif: Bool, words: String) { self.gradient = gradient; self.serif = serif; self.words = words }
    init?(_ s: String) {
        guard s.hasPrefix("g=") else { return nil }
        let parts = s.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        gradient = Int(parts[0].dropFirst(2)) ?? 0
        serif = parts.count < 2 || parts[1] != "f=sans"
        words = parts.count > 2 ? String(parts[2].dropFirst(2)) : ""
    }
    var string: String { "g=\(gradient);f=\(serif ? "serif" : "sans");t=\(words)" }
}

/// A cover: the listener's own image or design, the show's art, or a monogram of the show's name.
struct CoverView: View {
    var show: Show?
    var url = ""
    var title = ""
    var size: CGFloat

    var body: some View {
        let name = show?.name ?? title
        let shape = RoundedRectangle(cornerRadius: max(3, size * 0.11), style: .continuous)
        ZStack {
            if let show, let design = Design(show.coverDesign) {
                DesignedCover(design: design, size: size)
            } else if let show, !show.coverFile.isEmpty {
                Monogram(name: name, size: size)
                CachedImage(address: AppFolder.dir("covers").appendingPathComponent(show.coverFile).absoluteString, points: size)
            } else {
                Monogram(name: name, size: size)
                let address = url.isEmpty ? (show?.image ?? "") : url
                if !address.isEmpty { CachedImage(address: address, points: size) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
    }
}

struct Monogram: View {
    let name: String
    let size: CGFloat
    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.85), Color(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }
    }
}

struct DesignedCover: View {
    let design: Design
    let size: CGFloat
    var body: some View {
        let short = design.words.count <= 3
        ZStack {
            LinearGradient(colors: DESIGNS[design.gradient % DESIGNS.count], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(design.words)
                .font(.system(size: size * (short ? 0.4 : 0.17), weight: .semibold, design: design.serif ? .serif : .default))
                .foregroundStyle(.white).multilineTextAlignment(.center).minimumScaleFactor(0.4).lineLimit(4).padding(size * 0.09)
        }
        .frame(width: size, height: size)
    }
}

/// Change a show's cover: choose an image, or design one with its own words, a gradient and a typeface.
struct CoverEditor: View {
    let show: Show
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var words = ""
    @State private var gradient = 0
    @State private var serif = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Cover")).font(.title2.bold())
            HStack(alignment: .top, spacing: 22) {
                DesignedCover(design: Design(gradient: gradient, serif: serif, words: words), size: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).shadow(radius: 6, y: 3)
                Form {
                    TextField(L("Words on the cover"), text: $words)
                    Picker(L("Type"), selection: $serif) { Text(L("Serif")).tag(true); Text(L("Sans")).tag(false) }.pickerStyle(.segmented)
                    HStack(spacing: 8) {
                        ForEach(DESIGNS.indices, id: \.self) { i in
                            Button { gradient = i } label: {
                                Circle().fill(LinearGradient(colors: DESIGNS[i], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 24, height: 24)
                                    .overlay { if i == gradient { Circle().strokeBorder(.primary, lineWidth: 2) } }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .formStyle(.columns)
            }
            HStack {
                Button(L("Choose Image…"), action: choose)
                if !show.coverFile.isEmpty || !show.coverDesign.isEmpty {
                    Button(L("Use the Show’s Own Cover")) { store.update(show.id) { $0.coverFile = ""; $0.coverDesign = "" }; dismiss() }
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Use This Design")) {
                    let d = Design(gradient: gradient, serif: serif, words: words).string
                    store.update(show.id) { $0.coverDesign = d; $0.coverFile = "" }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            let d = Design(show.coverDesign)
            words = d?.words ?? show.name; gradient = d?.gradient ?? 0; serif = d?.serif ?? true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { store.setCover(show.id, image: url); dismiss() }
    }
}

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 1.2.0's press: shrinks a little and dims while held, springing back.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A section heading, as Apple Music sets them: large and bold, with an optional line under it.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 22, weight: .bold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Artwork that lifts a little under the pointer and shows a play button, as in Apple Music.
struct ArtworkCard<Label: View>: View {
    var show: Show? = nil
    var url = ""
    var title: String
    var size: CGFloat = 170
    var onPlay: (() -> Void)? = nil
    var onOpen: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                CoverView(show: show, url: url, title: title, size: size)
                    .shadow(color: .black.opacity(hovering ? 0.28 : 0.16), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
                    .overlay(alignment: .bottomTrailing) {
                        if let onPlay, hovering {
                            Button(action: onPlay) {
                                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38)
                            }
                            .buttonStyle(.plain)
                            .glass(in: Circle())
                            .padding(10)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                label.frame(width: size, alignment: .leading)
            }
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(Pressable())
        .onHover { over in withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { hovering = over } }
    }
}

/// The colour of a cover, for tinting its show's page: the cover's average colour, measured once and remembered.
@MainActor
final class ArtColors {
    static let shared = ArtColors()
    private var known: [String: Color] = [:]
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func color(for address: String) async -> Color? {
        if let c = known[address] { return c }
        guard !address.isEmpty, let image = await CoverCache.shared.load(address, pixels: 64),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let c = Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
        known[address] = c
        return c
    }
}

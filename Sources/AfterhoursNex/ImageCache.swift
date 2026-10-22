import AppKit
import ImageIO
import SwiftUI

/// Covers decoded at the size they're shown (not their full size), kept in a memory cache with a firm limit. The
/// downloads themselves come from the URL cache on disk after the first time.
final class CoverCache: @unchecked Sendable {
    static let shared = CoverCache()
    private let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 48 << 20; return c }()

    /// Sizes are rounded up to a few steps, so a cover shown at similar sizes is decoded once.
    static func bucket(_ points: CGFloat) -> Int { let px = Int(points * 2); return [64, 128, 256, 512, 1024].first { $0 >= px } ?? 1024 }

    func cached(_ address: String, pixels: Int) -> NSImage? { cache.object(forKey: "\(pixels)|\(address)" as NSString) }

    func load(_ address: String, pixels: Int) async -> NSImage? {
        let key = "\(pixels)|\(address)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = URL(string: address) else { return nil }
        let data: Data?
        if url.isFileURL { data = try? Data(contentsOf: url) } else { data = try? await Net.data(url) }
        guard let data, let image = await Task.detached(priority: .utility, operation: { Self.downsample(data, pixels: pixels) }).value else { return nil }
        cache.setObject(image, forKey: key, cost: pixels * pixels * 4)
        return image
    }

    static func downsample(_ data: Data, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// An image from the cover cache, faded in when it arrives.
struct CachedImage: View {
    let address: String
    let points: CGFloat
    @State private var image: NSImage?

    var body: some View {
        // Color.clear takes exactly the space offered, so a filled image can't make the layout around it bigger
        Color.clear
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill().transition(.opacity) } }
            .clipped()
            .task(id: address) {
            let pixels = CoverCache.bucket(points)
            if let hit = CoverCache.shared.cached(address, pixels: pixels) { image = hit; return }
            image = nil
            let loaded = await CoverCache.shared.load(address, pixels: pixels)
            withAnimation(.easeOut(duration: 0.22)) { image = loaded }
        }
    }
}

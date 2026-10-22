import Foundation

/// A quiet look for a newer AfterhoursNex for Mac on GitHub.
enum Updates {
    /// The repository releases come from ("owner/name"); the release workflow fills it in.
    static let repo = ""

    static func latest() async -> (version: String, url: URL)? {
        let custom = UserDefaults.standard.string(forKey: "updateRepo") ?? ""
        let r = custom.isEmpty ? repo : custom
        guard !r.isEmpty, let api = URL(string: "https://api.github.com/repos/\(r)/releases/latest"),
              let o = (try? await Net.json(api)) as? [String: Any], let tag = o["tag_name"] as? String,
              let match = tag.firstMatch(of: #/\d+(\.\d+)+/#) else { return nil }
        let version = String(match.0)
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"   // "1.2" for 1.2.S
        guard newer(version, than: current) else { return nil }
        let assets = o["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        guard let link = URL(string: dmg ?? (o["html_url"] as? String ?? "")) else { return nil }
        return (version, link)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

import Foundation
import Observation

/// Video podcasts from YouTube, Bilibili and similar sites, heard as audio, through yt-dlp. AfterhoursNex downloads
/// yt-dlp's standalone Mac program into its own folder when the listener asks, and keeps it up to date.
@Observable @MainActor
final class VideoTool {
    var working = false
    var note = ""
    @ObservationIgnored private let own = AppFolder.url("tools/yt-dlp")

    var executable: URL? {
        if FileManager.default.isExecutableFile(atPath: own.path) { return own }
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }
    var installedByApp: Bool { FileManager.default.isExecutableFile(atPath: own.path) }

    nonisolated static func handles(_ address: String) -> Bool {
        address.range(of: #"(?i)^https?://([\w-]+\.)*(youtube\.com|youtu\.be|bilibili\.com|b23\.tv|vimeo\.com|nicovideo\.jp)/"#, options: .regularExpression) != nil
    }

    func install() async {
        working = true; defer { working = false }
        do {
            let (temp, _) = try await URLSession.shared.download(from: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!)
            _ = AppFolder.dir("tools")
            try? FileManager.default.removeItem(at: own)
            try FileManager.default.moveItem(at: temp, to: own)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.path)
            note = L("Video podcasts are ready.")
        } catch {
            note = L("Couldn’t download the video tool. Check your connection and try again.")
        }
    }

    func remove() { try? FileManager.default.removeItem(at: own); note = "" }

    func update() async {
        guard let exe = executable else { return }
        working = true; defer { working = false }
        note = (try? await Self.run(exe, ["-U"]))?.split(separator: "\n").last.map(String.init) ?? ""
    }

    nonisolated static func run(_ exe: URL, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NexError.tool }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// The audio of a video, fetched once (as AAC, which plays directly) and kept in Application Support.
    func audio(for page: String) async throws -> URL {
        guard let exe = executable else { throw NexError.noVideoTool }
        let dir = AppFolder.dir("video")
        let id = stableID("v", page)
        func existing() -> URL? {
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .first { $0.lastPathComponent.hasPrefix(id + ".") && !$0.pathExtension.hasSuffix("part") }
        }
        if let f = existing() { return f }
        _ = try await Self.run(exe, ["-f", "bestaudio[ext=m4a]/bestaudio", "--no-playlist", "--no-warnings", "-o", dir.appendingPathComponent("\(id).%(ext)s").path, page])
        guard let f = existing() else { throw NexError.notAudio }
        return f
    }

    /// A channel or playlist, as a show of its videos.
    func show(for page: String) async throws -> Show {
        guard let exe = executable else { throw NexError.noVideoTool }
        let out = try await Self.run(exe, ["-J", "--flat-playlist", "--playlist-end", "60", "--no-warnings", page])
        guard let o = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { throw NexError.noFeed }
        let entries = (o["entries"] as? [[String: Any]]) ?? [o]
        let sid = stableID("v", page)
        func thumb(_ e: [String: Any]) -> String { (e["thumbnail"] as? String) ?? ((e["thumbnails"] as? [[String: Any]])?.last?["url"] as? String) ?? "" }
        let episodes: [Episode] = entries.compactMap { e in
            guard let u = (e["url"] as? String) ?? (e["webpage_url"] as? String) else { return nil }
            return Episode(id: stableID("v", u), showID: sid, title: e["title"] as? String ?? "", audioURL: u,
                           date: (e["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }, duration: e["duration"] as? Double ?? 0,
                           image: thumb(e), summary: String(plainText(e["description"] as? String ?? "").prefix(800)))
        }
        guard !episodes.isEmpty else { throw NexError.noFeed }
        return Show(id: sid, title: o["title"] as? String ?? page, author: (o["channel"] as? String) ?? (o["uploader"] as? String) ?? "", image: thumb(o),
                    feedURL: page, summary: String(plainText(o["description"] as? String ?? "").prefix(1200)), link: page, source: .video,
                    episodes: episodes, refreshed: Date())
    }

    /// Videos about a topic, from YouTube and Bilibili.
    func search(_ query: String) async -> [EpisodeHit] {
        guard let exe = executable else { return [] }
        var hits: [EpisodeHit] = []
        for prefix in ["ytsearch6", "bilisearch6"] {
            guard let out = try? await Self.run(exe, ["-J", "--flat-playlist", "--no-warnings", "\(prefix):\(query)"]),
                  let o = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], let entries = o["entries"] as? [[String: Any]] else { continue }
            for e in entries {
                guard let u = (e["url"] as? String) ?? (e["webpage_url"] as? String) else { continue }
                hits.append(EpisodeHit(title: e["title"] as? String ?? "", show: (e["channel"] as? String) ?? (e["uploader"] as? String) ?? "",
                                       artwork: (e["thumbnails"] as? [[String: Any]])?.last?["url"] as? String ?? "", audioURL: u, feedURL: "",
                                       summary: "", date: nil, duration: e["duration"] as? Double ?? 0))
            }
        }
        return hits
    }
}

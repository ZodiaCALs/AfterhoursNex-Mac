import Foundation

struct Show: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case rss, local, video }
    var id: String
    var title: String
    var author = ""
    var image = ""
    var feedURL: String
    var summary = ""
    var link = ""
    var source: Source = .rss
    // the listener's own arrangement
    var alias = ""
    var pinned = false
    var group = ""
    var coverFile = ""          // an image the listener chose, in Application Support/covers
    var coverDesign = ""        // or a design: "g=<gradient>;f=<serif|sans>;t=<words>"
    var episodes: [Episode] = []
    var refreshed: Date?

    var name: String { alias.isEmpty ? title : alias }
}

struct Episode: Codable, Identifiable, Hashable {
    var id: String
    var showID: String
    var title: String
    var audioURL: String
    var date: Date?
    var duration: Double = 0
    var image = ""
    var summary = ""
    var transcriptURL = ""
    var transcriptType = ""
}

struct Listening: Codable { var position: Double; var duration: Double; var done: Bool }

struct Cue: Codable, Hashable { var start: Double; var end: Double; var text: String; var speaker = "" }

/// The pages: those in the sidebar, and those opened from them (a show, a preview, an episode).
enum Page: Hashable {
    case listenNow, discover, library, radio, search, show(String), preview(Preview), episode(EpisodeHit)
    /// Pages opened from a list, which zoom in (1.2.0's drillIn); the others rise into place (its pageIn).
    var drills: Bool { switch self { case .show, .preview, .episode: return true; default: return false } }
}

/// A show to look at before adding it.
struct Preview: Identifiable, Hashable { var id = UUID(); var title: String; var feedURL = ""; var term = ""; var image = "" }

enum NexError: LocalizedError {
    case http(Int), noFeed, notAudio, noVideoTool, tool
    var errorDescription: String? {
        switch self {
        case .http(let code): return String(format: L("The server answered with an error (%d)."), code)
        case .noFeed: return L("Couldn’t find a podcast feed at that address.")
        case .notAudio: return L("Couldn’t get this episode’s audio.")
        case .noVideoTool: return L("Add video podcasts in Settings › Video first.")
        case .tool: return L("The video tool stopped with an error.")
        }
    }
}

/// A short, stable id for a text (the same on every launch).
func stableID(_ prefix: String, _ text: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in text.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return prefix + String(h, radix: 36)
}

/// The app's folder in Application Support.
enum AppFolder {
    static let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AfterhoursNex", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    static func dir(_ path: String) -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Fmt {
    static func length(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let m = Int(seconds / 60)
        return m >= 60 ? String(format: L("%d hr %d min"), m / 60, m % 60) : String(format: L("%d min"), max(1, m))
    }
    static func clock(_ seconds: Double) -> String {
        let t = Int(max(0, seconds.isFinite ? seconds : 0))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    static func day(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("Today") }
        if cal.isDateInYesterday(date) { return L("Yesterday") }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

let SPEEDS: [Float] = [0.5, 0.75, 0.9, 1, 1.1, 1.2, 1.25, 1.3, 1.5, 1.75, 2, 2.5, 3]
func speedLabel(_ s: Float) -> String { (s.rounded() == s ? String(Int(s)) : String(format: "%g", s)) + "×" }

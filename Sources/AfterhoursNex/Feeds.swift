import Foundation

enum Net {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "AfterhoursNex/1.0 (Mac podcast player)"]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
    static func data(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw NexError.http(http.statusCode) }
        return data
    }
    static func json(_ url: URL) async throws -> Any { try JSONSerialization.jsonObject(with: try await data(url)) }
}

/// Reads RSS and Atom podcast feeds, with the iTunes and Podcasting 2.0 tags.
final class FeedParser: NSObject, XMLParserDelegate {
    struct Item { var title = "", guid = "", audio = "", date = "", duration = "", image = "", summary = "", transcript = "", transcriptType = "" }
    struct Result { var title = "", author = "", image = "", summary = "", link = ""; var items: [Item] = [] }
    private var result = Result()
    private var item: Item?
    private var text = ""
    private var stack: [String] = []

    static func parse(_ data: Data) -> Result? {
        let p = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        let ok = xml.parse()
        return ok || !p.result.items.isEmpty ? p.result : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        stack.append(name); text = ""
        switch name {
        case "item", "entry": item = Item()
        case "enclosure":
            if item != nil, let url = a["url"], (a["type"] ?? "audio").hasPrefix("audio") || item!.audio.isEmpty { item!.audio = url }
        case "itunes:image":
            if let href = a["href"] { if item != nil { item!.image = href } else if result.image.isEmpty { result.image = href } }
        case "podcast:transcript":
            if item != nil, let url = a["url"] {
                let type = a["type"] ?? ""
                if item!.transcript.isEmpty || type.contains("vtt") || type.contains("json") { item!.transcript = url; item!.transcriptType = type }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if !stack.isEmpty { stack.removeLast() }; text = "" }
        if var i = item {
            switch name {
            case "title": if i.title.isEmpty { i.title = t }
            case "guid", "id": i.guid = t
            case "pubDate", "published", "updated": if i.date.isEmpty { i.date = t }
            case "itunes:duration": i.duration = t
            case "description", "content:encoded", "itunes:summary", "summary": if t.count > i.summary.count { i.summary = t }
            case "item", "entry":
                if !i.audio.isEmpty { result.items.append(i) }
                item = nil
                return
            default: break
            }
            item = i
        } else {
            let parent = stack.dropLast().last ?? ""
            switch name {
            case "title": if result.title.isEmpty, parent == "channel" || parent == "feed" { result.title = t }
            case "itunes:author": if result.author.isEmpty { result.author = t }
            case "description", "itunes:summary", "subtitle": if result.summary.isEmpty, parent == "channel" || parent == "feed" { result.summary = t }
            case "url": if parent == "image", result.image.isEmpty { result.image = t }
            case "link": if result.link.isEmpty, parent == "channel", !t.isEmpty { result.link = t }
            default: break
            }
        }
    }
}

enum Dates {
    private static let formatters: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                                                      "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z"].map { format in
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format; return f
    }
    static func parse(_ s: String) -> Date? {
        for f in formatters { if let d = f.date(from: s) { return d } }
        return ISO8601DateFormatter().date(from: s)
    }
}

func parseDuration(_ s: String) -> Double { s.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 } }

/// Show notes as plain text.
func plainText(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#8217;": "’", "&#8220;": "“", "&#8221;": "”"] {
        s = s.replacingOccurrences(of: entity, with: char)
    }
    return s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}

enum Feeds {
    /// A show from its feed, or from a website that links to one.
    static func show(from address: String) async throws -> Show {
        guard var url = URL(string: address.trimmingCharacters(in: .whitespaces)) else { throw NexError.noFeed }
        var data = try await Net.data(url)
        if FeedParser.parse(data)?.items.isEmpty ?? true, let html = String(data: data, encoding: .utf8), let alt = feedLink(in: html, base: url) {
            url = alt; data = try await Net.data(alt)
        }
        guard let feed = FeedParser.parse(data), !feed.items.isEmpty else { throw NexError.noFeed }
        let sid = stableID("s", url.absoluteString)
        let episodes = feed.items.map { i in
            Episode(id: stableID("e", i.guid.isEmpty ? i.audio : i.guid), showID: sid, title: i.title, audioURL: i.audio, date: Dates.parse(i.date),
                    duration: parseDuration(i.duration), image: i.image, summary: String(plainText(i.summary).prefix(1200)),
                    transcriptURL: i.transcript, transcriptType: i.transcriptType)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return Show(id: sid, title: feed.title, author: feed.author, image: feed.image, feedURL: url.absoluteString,
                    summary: String(plainText(feed.summary).prefix(1500)), link: feed.link, episodes: episodes, refreshed: Date())
    }

    static func feedLink(in html: String, base: URL) -> URL? {
        guard let re = try? NSRegularExpression(pattern: #"<link[^>]+type=["']application/(?:rss|atom)\+xml["'][^>]*>"#, options: .caseInsensitive),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(m.range, in: html),
              let href = String(html[r]).firstMatch(of: #/href=["']([^"']+)["']/#)?.1 else { return nil }
        return URL(string: String(href), relativeTo: base)?.absoluteURL
    }
}

struct ShowHit: Identifiable, Hashable { var id: String { feedURL }; var title: String; var author: String; var artwork: String; var feedURL: String; var genre: String }
struct EpisodeHit: Identifiable, Hashable {
    var id: String { audioURL }
    var title: String; var show: String; var artwork: String; var audioURL: String; var feedURL: String; var summary: String; var date: Date?; var duration: Double
    var episode: Episode { Episode(id: stableID("t", audioURL), showID: "search", title: title, audioURL: audioURL, date: date, duration: duration, image: artwork, summary: summary) }
}

/// Apple's podcast directory.
enum Directory {
    private static func query(_ term: String, entity: String, limit: Int, country: String? = nil) -> URL {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "media", value: "podcast"), .init(name: "entity", value: entity), .init(name: "limit", value: String(limit)),
                        .init(name: "term", value: term), .init(name: "country", value: country ?? Locale.current.region?.identifier ?? "US")]
        return c.url!
    }
    private static func results(_ url: URL) async throws -> [[String: Any]] { ((try await Net.json(url)) as? [String: Any])?["results"] as? [[String: Any]] ?? [] }

    static func shows(_ term: String, country: String? = nil, limit: Int = 25) async throws -> [ShowHit] {
        try await results(query(term, entity: "podcast", limit: limit, country: country)).compactMap { r in
            guard let feed = r["feedUrl"] as? String else { return nil }
            return ShowHit(title: r["collectionName"] as? String ?? "", author: r["artistName"] as? String ?? "", artwork: r["artworkUrl600"] as? String ?? "",
                           feedURL: feed, genre: r["primaryGenreName"] as? String ?? "")
        }
    }

    static func episodes(_ term: String, limit: Int = 30) async throws -> [EpisodeHit] {
        try await results(query(term, entity: "podcastEpisode", limit: limit)).compactMap { r in
            guard let audio = r["episodeUrl"] as? String else { return nil }
            return EpisodeHit(title: r["trackName"] as? String ?? "", show: r["collectionName"] as? String ?? "", artwork: r["artworkUrl600"] as? String ?? "",
                              audioURL: audio, feedURL: r["feedUrl"] as? String ?? "", summary: plainText(r["description"] as? String ?? ""),
                              date: (r["releaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                              duration: (r["trackTimeMillis"] as? Double ?? 0) / 1000)
        }
    }
}

struct Station: Identifiable, Hashable, Decodable {
    var stationuuid: String; var name: String
    var url_resolved: String?; var url: String?; var favicon: String?; var tags: String?; var country: String?; var state: String?
    var codec: String?; var bitrate: Int?; var hls: Int?
    var id: String { stationuuid }
    var stream: String { (url_resolved?.isEmpty == false ? url_resolved : url) ?? "" }
    var episode: Episode { Episode(id: "radio:" + stationuuid, showID: "radio", title: name.trimmingCharacters(in: .whitespaces), audioURL: stream, image: favicon ?? "",
                                   summary: [state ?? country ?? "", tags?.split(separator: ",").prefix(2).joined(separator: ", ") ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) }
}

/// Public FM and AM stations, from the Radio Browser directory.
enum Radio {
    static func stations(country: String, name: String = "") async throws -> [Station] {
        var c = URLComponents(string: "https://de1.api.radio-browser.info/json/stations/search")!
        c.queryItems = [.init(name: "hidebroken", value: "true"), .init(name: "order", value: "clickcount"), .init(name: "reverse", value: "true"),
                        .init(name: "limit", value: "60"), .init(name: "countrycode", value: country)]
        if !name.isEmpty { c.queryItems?.append(.init(name: "name", value: name)) }
        let list = try JSONDecoder().decode([Station].self, from: try await Net.data(c.url!))
        // AVFoundation plays MP3, AAC and HLS streams
        return list.filter { s in s.hls == 1 || ["MP3", "AAC", "AAC+", ""].contains((s.codec ?? "").uppercased()) }.filter { !$0.stream.isEmpty }
    }
}

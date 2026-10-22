import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import Observation

/// Phone access: AfterhoursNex in a phone's browser, served by this Mac on the same Wi-Fi behind a private link, and
/// the AfterhoursNex phone app, borrowing this Mac's captions and video podcasts.
@Observable @MainActor
final class PhoneAccess {
    private(set) var on = false
    private(set) var link = ""
    private(set) var problem = ""
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var key = UserDefaults.standard.string(forKey: "phoneKey") ?? ""
    @ObservationIgnored weak var video: VideoTool?

    init() { if key.isEmpty { newKey() } }

    func resume() { if UserDefaults.standard.bool(forKey: "phoneOn") { start() } }
    func setOn(_ value: Bool) { UserDefaults.standard.set(value, forKey: "phoneOn"); if value { start() } else { stop() } }
    func newLink() { newKey(); if on { start() } }

    private func newKey() {
        key = String((0..<24).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
        UserDefaults.standard.set(key, forKey: "phoneKey")
    }

    func start() {
        stop()
        guard let ip = Self.lanAddress() else { problem = L("Connect this Mac to Wi-Fi to use it from your phone."); return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: 8765)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { problem = L("Couldn’t start phone access."); return }
        let server = PhoneServer(key: key, host: "\(ip):8765", video: video)
        l.newConnectionHandler = { server.accept($0) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.problem = L("Couldn’t start phone access. Another app may be using its port."); self?.stop() } }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l; on = true; problem = ""
        link = "http://\(ip):8765/?key=\(key)"
    }

    func stop() { listener?.cancel(); listener = nil; on = false; link = "" }

    /// This Mac's address on the local network (Wi-Fi or Ethernet).
    nonisolated static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let lan = ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
            guard lan else { continue }
            if String(cString: p.pointee.ifa_name).hasPrefix("en") { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }

    /// The link as a QR code, for a phone's camera.
    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private struct PhoneError: Error { let status: Int; let message: String }

/// The HTTP side: the page for phone browsers and the API it uses, and the phone app's requests.
final class PhoneServer: @unchecked Sendable {
    let key: String
    let host: String
    weak var video: VideoTool?
    init(key: String, host: String, video: VideoTool?) { self.key = key; self.host = host; self.video = video }

    func accept(_ c: NWConnection) {
        c.start(queue: .global(qos: .userInitiated))
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                Task { await self.handle(c, head) }
            } else if done || error != nil || buf.count > 64 * 1024 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func handle(_ c: NWConnection, _ head: String) async {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        guard headers["host"] == host else { return send(c, 403, "text/plain; charset=utf-8", Data("Open the link from AfterhoursNex.".utf8)) }
        let comps = URLComponents(string: "http://x" + String(parts[1]))
        let path = comps?.path ?? "/"
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        if path.hasPrefix("/api/nex/") {
            guard q["key"] == key else { return send(c, 401, "text/plain; charset=utf-8", Data("Open the current phone link.".utf8)) }
            return await nex(c, path, q, headers)
        }
        if let k = q["key"] {
            guard k == key else { return send(c, 401, "text/plain; charset=utf-8", Data("This link has been replaced. Ask for the new one.".utf8)) }
            return send(c, 303, "text/plain", Data(), extra: ["Location": "/", "Set-Cookie": "ahk=\(key); Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000"])
        }
        let cookie = headers["cookie"]?.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("ahk=") }.map { String($0.dropFirst(4)) }
        guard cookie == key else { return send(c, 401, "text/plain; charset=utf-8", Data("Open the private link from AfterhoursNex › Settings › Phone.".utf8)) }
        do { try await api(c, path, q) } catch let e as PhoneError { error(c, e.status, e.message) } catch { self.error(c, 502, error.localizedDescription) }
    }

    // ---- the page and the API it uses ----

    private func api(_ c: NWConnection, _ path: String, _ q: [String: String]) async throws {
        switch path {
        case "/", "/index.html": send(c, 200, "text/html; charset=utf-8", asset("index", "html"))
        case "/icon.png": send(c, 200, "image/png", asset("icon", "png"))
        case "/manifest.webmanifest": send(c, 200, "application/manifest+json", Data(#"{"name":"AfterhoursNex","display":"standalone","start_url":"/"}"#.utf8))
        case "/api/ping": json(c, ["app": "afterhours", "name": "AfterhoursNex", "version": appVersion, "platform": "mac", "client": "phone"])
        case "/api/fetch":
            let (d, type, final) = try await fetch(q["url"], limit: 25 << 20)
            send(c, 200, type.isEmpty ? "application/octet-stream" : type, d, extra: ["X-Final-URL": final])
        case "/api/feedinfo": json(c, try await feedInfo(q["url"]))
        case "/api/image":
            let (d, type, _) = try await fetch(q["url"], limit: 8 << 20)
            guard let t = imageType(type, d) else { throw PhoneError(status: 415, message: "That address isn’t an image.") }
            send(c, 200, t, d, extra: ["Cache-Control": "private, max-age=604800"])
        case "/api/search":
            let term = (q["term"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { throw PhoneError(status: 400, message: "Type something to search for.") }
            let limit = String(min(50, max(1, Int(q["limit"] ?? "") ?? 20)))
            send(c, 200, "application/json", try await apple("/search", ["media": "podcast", "entity": "podcast", "term": String(term.prefix(120)), "country": country(q), "limit": limit]))
        case "/api/lookup":
            let ids = (q["id"] ?? "").filter { $0.isNumber || $0 == "," }
            guard !ids.isEmpty else { throw PhoneError(status: 400, message: "No podcast IDs given.") }
            send(c, 200, "application/json", try await apple("/lookup", ["id": ids, "country": country(q)]))
        case "/api/crawl": json(c, try await crawl(q["url"]))
        case "/api/captions":
            json(c, ["available": false, "engine": "", "models": [Any](), "sizes": [String: Any](), "versions": [String: Any](), "install": "Auto captions on phones aren’t available yet."])
        case "/api/prefs": json(c, ["window": false, "browser": "", "native": false])
        case "/api/phone": json(c, ["on": false, "url": "", "address": ""])
        default:
            if path.hasPrefix("/api/captions/") { throw PhoneError(status: 501, message: "Auto captions on phones aren’t available yet.") }
            throw PhoneError(status: 404, message: "Not found.")
        }
    }

    private func asset(_ name: String, _ ext: String) -> Data {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "phone").flatMap { try? Data(contentsOf: $0) } ?? Data()
    }

    private func fetch(_ address: String?, limit: Int) async throws -> (Data, String, String) {
        guard let address, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { throw PhoneError(status: 400, message: "That isn’t a web address.") }
        let (data, response) = try await Net.session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) { throw PhoneError(status: 502, message: "The site answered with an error (\(http.statusCode)).") }
        guard data.count <= limit else { throw PhoneError(status: 413, message: "That file is too big.") }
        return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "", response.url?.absoluteString ?? address)
    }

    private func apple(_ path: String, _ params: [String: String]) async throws -> Data {
        var comps = URLComponents(string: "https://itunes.apple.com" + path)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await fetch(comps.url!.absoluteString, limit: 4 << 20).0
    }

    private func country(_ q: [String: String]) -> String {
        let c = (q["country"] ?? "gb").lowercased()
        return c.range(of: "^[a-z]{2}$", options: .regularExpression) != nil ? c : "gb"
    }

    private func first(_ pattern: String, _ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return "" }
        return plainText(String(text[r]))
    }

    private func feedInfo(_ address: String?) async throws -> [String: Any] {
        let (d, _, final) = try await fetch(address, limit: 768 << 10)
        let text = String(decoding: d, as: UTF8.self)
        let head = text.range(of: "<item[\\s>]", options: .regularExpression).map { String(text[..<$0.lowerBound]) } ?? text
        let noImage = head.replacingOccurrences(of: "(?is)<image\\b.*?</image>", with: "", options: .regularExpression)
        var image = first("<itunes:image\\b[^>]*\\bhref\\s*=\\s*[\"']([^\"']+)[\"']", head)
        if image.isEmpty { image = first("<image\\b[^>]*>.*?<url[^>]*>(.*?)</url>", head) }
        return ["title": first("<title[^>]*>(.*?)</title>", noImage), "author": first("<itunes:author[^>]*>(.*?)</itunes:author>", head),
                "image": image, "link": first("<link[^>]*>(.*?)</link>", noImage), "finalUrl": final]
    }

    /// A show's feed, from a feed address or from its website.
    private func crawl(_ address: String?) async throws -> [String: Any] {
        let (d, _, base) = try await fetch(address, limit: 4 << 20)
        let text = String(decoding: d, as: UTF8.self)
        func result(_ feed: String, _ show: [String: Any]) -> [String: Any] { ["source": "rss", "feedUrl": feed, "pageUrl": base, "show": show, "episodes": []] }
        if text.range(of: "<rss|<feed[\\s>]", options: .regularExpression) != nil {
            guard text.contains("<enclosure") else { throw PhoneError(status: 422, message: "That feed has no audio episodes.") }
            return result(base, [:])
        }
        guard let baseURL = URL(string: base) else { throw PhoneError(status: 400, message: "That isn’t a web address.") }
        var candidates: [String] = []
        if let link = Feeds.feedLink(in: text, base: baseURL) { candidates.append(link.absoluteString) }
        if let re = try? NSRegularExpression(pattern: "href=[\"']([^\"']+)[\"']", options: .caseInsensitive) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let href = String(text[r])
                if href.range(of: "(/feed\\b|/rss\\b|rss\\.xml|feed\\.xml|podcast\\.xml|format=rss)", options: [.regularExpression, .caseInsensitive]) != nil,
                   let u = URL(string: href, relativeTo: baseURL) { candidates.append(u.absoluteString) }
            }
        }
        let appleID = first("podcasts\\.apple\\.com/[^\"'\\s<>]*?/id(\\d{5,12})", text)
        if !appleID.isEmpty, let data = try? await apple("/lookup", ["id": appleID, "country": "gb"]),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let feed = (o["results"] as? [[String: Any]])?.first?["feedUrl"] as? String { candidates.append(feed) }
        for guess in ["feed", "feed/podcast", "podcast/feed", "rss", "rss.xml", "feed.xml", "podcast.xml", "index.xml", "?format=rss"] {
            if let u = URL(string: guess, relativeTo: baseURL) { candidates.append(u.absoluteString) }
        }
        let show: [String: Any] = ["title": first("<meta[^>]+property=[\"']og:site_name[\"'][^>]+content=[\"']([^\"']+)", text).isEmpty ? first("<title[^>]*>(.*?)</title>", text) : first("<meta[^>]+property=[\"']og:site_name[\"'][^>]+content=[\"']([^\"']+)", text),
                                   "image": first("<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)", text),
                                   "description": first("<meta[^>]+name=[\"']description[\"'][^>]+content=[\"']([^\"']+)", text)]
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if let (cd, _, final) = try? await fetch(candidate, limit: 4 << 20), String(decoding: cd, as: UTF8.self).contains("<enclosure") { return result(final, show) }
        }
        throw PhoneError(status: 422, message: "Couldn’t find a podcast feed on that page.")
    }

    private func imageType(_ type: String, _ d: Data) -> String? {
        if type.lowercased().hasPrefix("image/") { return type }
        let b = [UInt8](d.prefix(12))
        if b.count > 3, b[0] == 0x89, b[1] == 0x50 { return "image/png" }
        if b.count > 3, b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b.count > 11, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }

    // ---- the phone app: this Mac's captions and video podcasts ----

    private func nex(_ c: NWConnection, _ path: String, _ q: [String: String], _ headers: [String: String]) async {
        let video = await MainActor.run { self.video }
        do {
            switch path {
            case "/api/nex/ping":
                let ready = await MainActor.run { video?.executable != nil }
                json(c, ["name": "AfterhoursNex", "version": appVersion, "captions": true, "video": ready])
            case "/api/nex/captions":
                let lines = stream(c)
                do {
                    _ = try await Transcriber.transcribe(q["url"] ?? "", localeID: UserDefaults.standard.string(forKey: "speechLocale") ?? "",
                                                         status: { message, progress in lines(["status": message, "progress": progress]) },
                                                         cues: { cues in lines(["cues": cues.map { c -> [String: Any] in ["start": Int(c.start * 1000), "end": Int(c.end * 1000), "text": c.text, "speaker": c.speaker] }]) })
                } catch { lines(["error": error.localizedDescription]) }
                finish(c)
            case "/api/nex/video/feed":
                guard let video else { throw PhoneError(status: 503, message: "Add video podcasts on this Mac first.") }
                let show = try await video.show(for: q["url"] ?? "")
                json(c, ["title": show.title, "author": show.author, "image": show.image, "description": show.summary, "link": show.link,
                         "episodes": show.episodes.map { e -> [String: Any] in
                             ["id": e.id, "sid": q["sid"] ?? show.id, "title": e.title, "url": e.audioURL,
                              "date": Int((e.date?.timeIntervalSince1970 ?? 0) * 1000), "duration": Int(e.duration), "image": e.image, "desc": e.summary] }])
            case "/api/nex/video/search":
                let hits = await video?.search(q["q"] ?? "") ?? []
                json(c, list: hits.map { h -> [String: Any] in ["url": h.audioURL, "title": h.title, "channel": h.show, "durationSec": Int(h.duration), "thumb": h.artwork, "site": ""] })
            case "/api/nex/video/prepare":
                let lines = stream(c)
                do {
                    guard let video else { throw PhoneError(status: 503, message: "Add video podcasts on this Mac first.") }
                    lines(["status": "Getting the audio…", "progress": -1.0])
                    let file = try await video.audio(for: q["url"] ?? "")
                    lines(["file": file.lastPathComponent])
                } catch { lines(["error": (error as? PhoneError)?.message ?? error.localizedDescription]) }
                finish(c)
            default:
                guard path.hasPrefix("/api/nex/file/") else { throw PhoneError(status: 404, message: "Not found.") }
                serveFile(c, String(path.dropFirst("/api/nex/file/".count)), range: headers["range"])
            }
        } catch let e as PhoneError { error(c, e.status, e.message) } catch { self.error(c, 502, error.localizedDescription) }
    }

    /// A video's audio, a few megabytes at a time, so the phone can start playing and seek.
    private func serveFile(_ c: NWConnection, _ name: String, range: String?) {
        let file = AppFolder.dir("video").appendingPathComponent(name)
        guard name.range(of: "^[\\w.-]+$", options: .regularExpression) != nil, let handle = try? FileHandle(forReadingFrom: file),
              let total = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else {
            return error(c, 404, "Not found.")
        }
        defer { try? handle.close() }
        var start: Int64 = 0, end = total - 1
        if let range, let m = range.firstMatch(of: #/bytes=(\d*)-(\d*)/#) {
            if let s = Int64(m.1) { start = s }
            if let e = Int64(m.2) { end = min(e, total - 1) }
        }
        end = min(end, start + (4 << 20) - 1)
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.read(upToCount: Int(end - start + 1))) ?? Data()
        send(c, 206, name.hasSuffix(".m4a") ? "audio/mp4" : "application/octet-stream", data,
             extra: ["Accept-Ranges": "bytes", "Content-Range": "bytes \(start)-\(start + Int64(data.count) - 1)/\(total)"])
    }

    // ---- replies ----

    private func send(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        var data = Data((head + "\r\n").utf8)
        data.append(body)
        c.send(content: data, completion: .contentProcessed { _ in c.cancel() })
    }

    private func json(_ c: NWConnection, _ value: [String: Any]) { send(c, 200, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)) }
    private func json(_ c: NWConnection, list value: [[String: Any]]) { send(c, 200, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: value)) ?? Data("[]".utf8)) }
    private func error(_ c: NWConnection, _ status: Int, _ message: String) { send(c, status, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()) }

    /// A reply sent a line of JSON at a time, as the work goes on.
    private func stream(_ c: NWConnection) -> @Sendable ([String: Any]) -> Void {
        c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson; charset=utf-8\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        return { value in
            var line = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
            line.append(0x0A)
            c.send(content: line, completion: .contentProcessed { _ in })
        }
    }
    private func finish(_ c: NWConnection) { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }
}

/// The app's version as people see it ("1.2.S").
let appVersion: String = Bundle.main.object(forInfoDictionaryKey: "AHNDisplayVersion") as? String
    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.S"

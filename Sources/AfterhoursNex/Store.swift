import Foundation
import SwiftUI
import Observation

struct ShelfSection: Identifiable { var id: String { title }; var title: String; var shows: [Show] }

/// The library: the listener's shows, their episodes and where they are in each, kept in Application Support.
@Observable @MainActor
final class Store {
    var shows: [Show] = []
    var listening: [String: Listening] = [:]
    var refreshing: Set<String> = []
    var newRelease: (version: String, url: URL)?
    /// While the starter shelf is being set up: how many of how many.
    var setup: (done: Int, total: Int)?
    /// Kept up to date when the library changes, so pages don't sort thousands of episodes on every redraw.
    private(set) var latest: [Episode] = []
    @ObservationIgnored private var lastSaved = Date.distantPast

    init() {
        shows = Self.read("library.json") ?? []
        listening = Self.read("listening.json") ?? [:]
        reindex()
    }

    func save() { reindex(); Self.write(shows, "library.json") }

    private func reindex() {
        latest = Array(shows.flatMap { $0.episodes.prefix(8) }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(40))
    }

    /// The catalogue's shows not on the shelf yet, from the categories the listener already likes first.
    var pickedForYou: [CatalogPick] {
        let have = Set(shows.map { $0.title.lowercased() })
        return Catalog.all.filter { !have.contains($0.title.lowercased()) }.prefix(12).map { $0 }
    }

    /// The first time AfterhoursNex opens: the thirty shows from the catalogue, found in Apple's directory at a gentle pace.
    func setUpStarterShelf() async {
        guard !UserDefaults.standard.bool(forKey: "setUp"), shows.isEmpty, !Catalog.data.presets.isEmpty else { return }
        let presets = Catalog.data.presets
        setup = (0, presets.count)
        for (i, p) in presets.enumerated() {
            if let hit = (try? await Directory.shows(p.searchTerm, country: p.country, limit: 5))?.first(where: { related($0.title, p.title) }) {
                _ = try? await add(hit.feedURL)
            } else if let site = p.site, !site.isEmpty {
                _ = try? await add(site)
            }
            setup = (i + 1, presets.count)
            try? await Task.sleep(for: .seconds(2.5))
        }
        setup = nil
        UserDefaults.standard.set(true, forKey: "setUp")
    }

    /// Points a show at a different feed, keeping the listener's name, cover, pin and group.
    func changeFeed(_ id: String, to address: String) async throws {
        let fresh = try await Feeds.show(from: address)
        update(id) { s in s.feedURL = fresh.feedURL; s.episodes = fresh.episodes.map { var e = $0; e.showID = id; return e }; s.image = fresh.image; s.summary = fresh.summary; s.refreshed = Date() }
    }
    func saveListening(now: Bool = false) {
        guard now || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date(); Self.write(listening, "listening.json")
    }
    private static func read<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: AppFolder.url(name)) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(T.self, from: data)
    }
    private static func write<T: Encodable>(_ value: T, _ name: String) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        if let data = try? e.encode(value) { try? data.write(to: AppFolder.url(name), options: .atomic) }
    }

    func show(_ id: String) -> Show? { shows.first { $0.id == id } }

    /// The sidebar: pinned shows, then the listener's groups, then the rest, each in their own order.
    var sections: [ShelfSection] {
        let pinned = shows.filter(\.pinned)
        let rest = shows.filter { !$0.pinned }
        var groups: [String] = []
        for s in rest where !s.group.isEmpty && !groups.contains(s.group) { groups.append(s.group) }
        var out: [ShelfSection] = []
        if !pinned.isEmpty { out.append(.init(title: L("Pinned"), shows: pinned)) }
        for g in groups { out.append(.init(title: g, shows: rest.filter { $0.group == g })) }
        let loose = rest.filter { $0.group.isEmpty }
        if !loose.isEmpty { out.append(.init(title: L("Shows"), shows: loose)) }
        return out
    }

    // ---- adding, refreshing, arranging ----

    @discardableResult
    func add(_ address: String) async throws -> Show {
        if let s = shows.first(where: { $0.feedURL == address }) { return s }
        let s = try await Feeds.show(from: address)
        if let existing = show(s.id) { return existing }
        shows.append(s); save()
        return s
    }

    func add(_ show: Show) { if self.show(show.id) == nil { shows.append(show); save() } }

    func refresh(_ id: String) async {
        guard let s = show(id), s.source == .rss, !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        guard let fresh = try? await Feeds.show(from: s.feedURL) else { return }
        update(id) { s in
            s.episodes = fresh.episodes
            if !fresh.title.isEmpty { s.title = fresh.title }
            if s.image.isEmpty { s.image = fresh.image }
            s.summary = fresh.summary; s.refreshed = Date()
        }
    }

    func refreshAll() async {
        let ids = shows.filter { $0.source == .rss }.map(\.id)
        await withTaskGroup(of: Void.self) { group in for id in ids { group.addTask { await self.refresh(id) } } }
    }

    func update(_ id: String, _ change: (inout Show) -> Void) {
        guard let i = shows.firstIndex(where: { $0.id == id }) else { return }
        change(&shows[i]); save()
    }

    /// Removes a show, and returns it with its place so Undo can put it back.
    func remove(_ id: String) -> (Show, Int)? {
        guard let i = shows.firstIndex(where: { $0.id == id }) else { return nil }
        let s = shows.remove(at: i); save()
        return (s, i)
    }

    func restore(_ show: Show, at index: Int) {
        guard self.show(show.id) == nil else { return }
        shows.insert(show, at: min(index, shows.count)); save()
    }

    /// Reorders one sidebar section, keeping the other shows where they are.
    func move(_ ids: [String], from: IndexSet, to: Int) {
        var section = ids
        section.move(fromOffsets: from, toOffset: to)
        let slots = shows.indices.filter { ids.contains(shows[$0].id) }
        var reordered = shows
        for (slot, id) in zip(slots, section) { if let s = show(id) { reordered[slot] = s } }
        shows = reordered; save()
    }

    func setCover(_ id: String, image: URL) {
        let name = "\(id)-\(Int(Date().timeIntervalSince1970)).\(image.pathExtension.isEmpty ? "png" : image.pathExtension)"
        let dest = AppFolder.dir("covers").appendingPathComponent(name)
        guard (try? FileManager.default.copyItem(at: image, to: dest)) != nil else { return }
        update(id) { $0.coverFile = name; $0.coverDesign = "" }
    }

    // ---- listening ----

    var upNext: [Episode] {
        shows.flatMap(\.episodes).filter { e in listening[e.id].map { !$0.done && $0.position > 30 } ?? false }.prefix(12).map { $0 }
    }

    func markPlayed(_ e: Episode, _ done: Bool) {
        listening[e.id] = Listening(position: done ? max(e.duration, 1) : 0, duration: e.duration, done: done)
        saveListening(now: true)
    }

    // ---- audio files from this Mac ----

    @discardableResult
    func importFiles(_ urls: [URL]) -> Show {
        let id = "local"
        if show(id) == nil { shows.append(Show(id: id, title: L("On This Mac"), feedURL: "", summary: L("Audio files you’ve imported."), source: .local)) }
        update(id) { s in
            let fresh = urls.filter { u in !s.episodes.contains { $0.audioURL == u.absoluteString } }.enumerated().map { i, u in
                Episode(id: stableID("l", u.path), showID: id, title: u.deletingPathExtension().lastPathComponent, audioURL: u.absoluteString,
                        date: Date().addingTimeInterval(Double(-i)))
            }
            s.episodes = fresh + s.episodes
        }
        return show(id)!
    }

    func checkForUpdates() async {
        guard UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true else { return }
        if let r = await Updates.latest() { newRelease = r }
    }
}

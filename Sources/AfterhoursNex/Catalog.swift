import Foundation

/// The AfterhoursNex catalogue: thirty shows for a new shelf, and many more to discover, by category.
struct CatalogData: Decodable {
    var categories: [CatalogCategory]
    var presets: [CatalogPick]
    var extras: [CatalogPick]?
}
struct CatalogCategory: Decodable, Identifiable, Hashable { var id: String; var label: String; var short: String? }
struct CatalogPick: Decodable, Identifiable, Hashable {
    var key: String; var cat: String; var title: String
    var author: String?; var artist: String?; var term: String?; var countries: [String]?; var why: String?; var site: String?
    var id: String { key }
    var searchTerm: String { term?.isEmpty == false ? term! : title }
    var country: String { countries?.first ?? "us" }
}

enum Catalog {
    static let data: CatalogData = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"), let d = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(CatalogData.self, from: d) else { return CatalogData(categories: [], presets: [], extras: []) }
        return c
    }()
    static var all: [CatalogPick] { data.presets + (data.extras ?? []) }
}

/// Whether two show titles name the same show (ignoring case, punctuation and small differences).
func related(_ a: String, _ b: String) -> Bool {
    func squash(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
    let x = squash(a), y = squash(b)
    guard !x.isEmpty, !y.isEmpty else { return false }
    return x.contains(y) || y.contains(x)
}

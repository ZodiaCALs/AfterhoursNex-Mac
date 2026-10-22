import AppKit
import Foundation
import UniformTypeIdentifiers

/// OPML, the format podcast apps use to move a list of shows between them.
enum OPML {
    static func export(_ shows: [Show]) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
        let outlines = shows.filter { $0.source == .rss && !$0.feedURL.isEmpty }
            .map { "    <outline type=\"rss\" text=\"\(esc($0.name))\" title=\"\(esc($0.name))\" xmlUrl=\"\(esc($0.feedURL))\"/>" }.joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>AfterhoursNex</title></head>\n  <body>\n\(outlines)\n  </body>\n</opml>\n"
    }

    static func feeds(in data: Data) -> [String] {
        final class Reader: NSObject, XMLParserDelegate {
            var feeds: [String] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                if name.lowercased() == "outline", let url = a["xmlUrl"] ?? a["xmlurl"], !url.isEmpty { feeds.append(url) }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.feeds
    }

    @MainActor static func exportPanel(_ shows: [Show]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AfterhoursNex.opml"
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        if panel.runModal() == .OK, let url = panel.url { try? export(shows).write(to: url, atomically: true, encoding: .utf8) }
    }

    @MainActor static func importPanel(into store: Store) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let list = feeds(in: data)
        Task { for feed in list { _ = try? await store.add(feed) } }
    }
}

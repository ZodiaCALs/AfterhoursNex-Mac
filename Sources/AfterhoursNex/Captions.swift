import AVFoundation
import Foundation
import Observation
import Speech

/// Captions for the playing episode: the show's transcript, a caption file, or captions made on this Mac with Apple's
/// speech recognition. Kept in Application Support once made, so they load instantly next time.
@Observable @MainActor
final class Captions {
    private(set) var cues: [Cue] = []
    private(set) var source = ""
    private(set) var status = ""
    private(set) var progress: Double = -1
    private(set) var active = -1
    var translations: [String: String] = [:]
    @ObservationIgnored private var episodeID = ""
    @ObservationIgnored private var job: Task<Void, Never>?

    var working: Bool { job != nil && !status.isEmpty }

    func load(_ e: Episode) {
        job?.cancel(); job = nil
        episodeID = e.id; cues = []; source = ""; status = ""; progress = -1; active = -1
        if let saved = read(e.id) { cues = saved; source = "saved"; return }
        if !e.transcriptURL.isEmpty, let url = URL(string: e.transcriptURL) {
            job = Task {
                if let data = try? await Net.data(url), let parsed = Self.parse(data, type: e.transcriptType), !parsed.isEmpty, episodeID == e.id {
                    cues = parsed; source = "transcript"; write(parsed, e.id)
                }
                job = nil
            }
        } else if UserDefaults.standard.bool(forKey: "autoCaptions"), !e.id.hasPrefix("radio:") {
            make(e)
        }
    }

    func tick(_ position: Double) {
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi { let mid = (lo + hi) / 2; if cues[mid].start <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 } }
        if found != active { active = found }
    }

    @discardableResult
    func importFile(_ url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let parsed = Self.parse(data, type: url.pathExtension), !parsed.isEmpty else { return false }
        cues = parsed; source = "file"; write(parsed, episodeID)
        return true
    }

    func make(_ e: Episode) {
        job?.cancel()
        job = Task { await transcribe(e); job = nil }
    }

    func stop() { job?.cancel(); job = nil; status = ""; progress = -1 }

    func forget(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }

    // ---- reading caption formats ----

    nonisolated static func parse(_ data: Data, type: String = "") -> [Cue]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if type.contains("json") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return parseJSON(data) }
        return parseTimed(text)
    }

    /// WebVTT and SubRip.
    nonisolated static func parseTimed(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(String(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")) else { continue }
            var body = lines[(timing + 1)...].joined(separator: " ")
            var speaker = ""
            if let m = body.firstMatch(of: #/<v\s+([^>]+)>/#) { speaker = String(m.1) }
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            // a speaker label in capitals, as caption files write them ("HOST: Good evening.")
            if speaker.isEmpty, let m = body.firstMatch(of: #/^([A-Z][A-Z0-9 .'-]{1,30}):\s+/#) { speaker = String(m.1); body = String(body[m.range.upperBound...]) }
            body = plainText(body)
            if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body, speaker: speaker)) }
        }
        return cues
    }

    nonisolated static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        return parts.isEmpty ? nil : parts.reduce(0) { $0 * 60 + $1 }
    }

    /// The Podcasting 2.0 JSON transcript.
    nonisolated static func parseJSON(_ data: Data) -> [Cue]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let segments = o["segments"] as? [[String: Any]] else { return nil }
        return segments.compactMap { s in
            guard let start = s["startTime"] as? Double, let body = s["body"] as? String else { return nil }
            return Cue(start: start, end: s["endTime"] as? Double ?? start + 3, text: body.trimmingCharacters(in: .whitespacesAndNewlines), speaker: s["speaker"] as? String ?? "")
        }
    }

    // ---- captions made on this Mac ----

    private func transcribe(_ e: Episode) async {
        do {
            let made = try await Transcriber.transcribe(e.audioURL, localeID: UserDefaults.standard.string(forKey: "speechLocale") ?? "",
                status: { message, progress in Task { @MainActor in if self.episodeID == e.id { self.status = message; self.progress = progress } } },
                cues: { cues in Task { @MainActor in if self.episodeID == e.id { self.cues = cues; self.source = "auto" } } })
            if episodeID == e.id, !Task.isCancelled { status = ""; progress = -1; cues = made; write(made, e.id) }
        } catch {
            if episodeID == e.id { status = error.localizedDescription; progress = -1 }
        }
    }

    // ---- kept captions ----

    private func file(_ id: String) -> URL { AppFolder.dir("captions").appendingPathComponent(id + ".json") }
    private func read(_ id: String) -> [Cue]? { (try? Data(contentsOf: file(id))).flatMap { try? JSONDecoder().decode([Cue].self, from: $0) } }
    private func write(_ cues: [Cue], _ id: String) { if !id.isEmpty, let data = try? JSONEncoder().encode(cues) { try? data.write(to: file(id), options: .atomic) } }
}

/// Captions made with Apple's speech recognition (on this Mac when it can), in ninety-second pieces gathered into readable lines.
enum Transcriber {
    static func transcribe(_ address: String, localeID: String, status: @escaping @Sendable (String, Double) -> Void,
                           cues report: @escaping @Sendable ([Cue]) -> Void) async throws -> [Cue] {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else { throw TranscribeError(L("Allow speech recognition for AfterhoursNex in System Settings › Privacy & Security.")) }
        let spoken = localeID.isEmpty ? Locale.current : Locale(identifier: localeID)
        let code = spoken.language.languageCode?.identifier ?? ""
        let joiner = ["zh", "ja", "yue"].contains(code) ? "" : " "
        status(L("Getting the audio…"), -1)
        let file = try await localFile(address)
        // the model chosen in Settings › Captions: SpeechAnalyzer when it knows the language (or when asked for), else classic
        let choice = UserDefaults.standard.string(forKey: "captionModel") ?? "auto"
        if choice != "classic", let locale = await SpeechModels.locale(for: localeID) {
            return try await SpeechModels.transcribe(file, locale: locale, joiner: joiner, status: status, cues: report)
        }
        if choice == "analyzer" { throw TranscribeError(L("SpeechAnalyzer doesn’t know this language yet. Choose Classic speech recognition in Settings › Captions.")) }
        guard let recognizer = localeID.isEmpty ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: spoken), recognizer.isAvailable else {
            throw TranscribeError(L("Speech recognition isn’t available for this language."))
        }
        let asset = AVURLAsset(url: file)
        let total = try await asset.load(.duration).seconds
        var made: [Cue] = []
        var t = 0.0
        let chunk = 90.0
        while t < total, !Task.isCancelled {
            status(L("Making captions on this Mac…"), t / max(total, 1))
            let piece = try await export(asset, from: t, length: min(chunk, total - t))
            let segments = (try? await recognize(recognizer, piece)) ?? []
            made += lines(segments, offset: t, joiner: joiner)
            try? FileManager.default.removeItem(at: piece)
            report(made)
            t += chunk
        }
        return made
    }

    struct TranscribeError: LocalizedError { let text: String; init(_ text: String) { self.text = text }; var errorDescription: String? { text } }

    private static func localFile(_ address: String) async throws -> URL {
        guard let url = URL(string: address) else { throw NexError.notAudio }
        if url.isFileURL { return url }
        let (temp, _) = try await Net.session.download(from: url)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(stableID("a", address) + "." + (url.pathExtension.isEmpty ? "mp3" : url.pathExtension))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private static func export(_ asset: AVURLAsset, from start: Double, length: Double) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw NexError.notAudio }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        try await session.export(to: out, as: .m4a)
        return out
    }

    private static func recognize(_ recognizer: SFSpeechRecognizer, _ url: URL) async throws -> [SFTranscriptionSegment] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { c in
            recognizer.recognitionTask(with: request) { result, error in
                if once.done { return }
                if let result, result.isFinal { once.done = true; c.resume(returning: result.bestTranscription.segments) }
                else if let error { once.done = true; c.resume(throwing: error) }
            }
        }
    }

    /// Recognised words, gathered into lines: at a sentence's end, a pause, or about fourteen words.
    private static func lines(_ segments: [SFTranscriptionSegment], offset: Double, joiner: String) -> [Cue] {
        var out: [Cue] = []
        var words: [String] = []
        var start = 0.0, end = 0.0
        func flush() { if !words.isEmpty { out.append(Cue(start: offset + start, end: offset + end, text: words.joined(separator: joiner))); words = [] } }
        for s in segments {
            if !words.isEmpty && (s.timestamp - end > 0.9 || words.count >= 14) { flush() }
            if words.isEmpty { start = s.timestamp }
            words.append(s.substring); end = s.timestamp + s.duration
            if let last = s.substring.last, ".?!。？！".contains(last) { flush() }
        }
        flush()
        return out
    }
}

/// SpeechAnalyzer: Apple's newer speech-to-text (macOS 26), made for long recordings, with language models macOS
/// downloads once and keeps.
enum SpeechModels {
    /// The model's version of a language, if it has one.
    static func locale(for id: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: id.isEmpty ? Locale.current : Locale(identifier: id))
    }

    static func installed(_ locale: Locale) async -> Bool {
        let tag = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == tag }
    }

    static func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let watch = Task {
            while !Task.isCancelled { progress(request.progress.fractionCompleted); try? await Task.sleep(for: .milliseconds(250)) }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
    }

    static func transcribe(_ file: URL, locale: Locale, joiner: String, status: @escaping @Sendable (String, Double) -> Void,
                           cues report: @escaping @Sendable ([Cue]) -> Void) async throws -> [Cue] {
        if !(await installed(locale)) {
            status(L("Downloading the speech model…"), 0)
            try await install(locale) { status(L("Downloading the speech model…"), $0) }
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audio = try AVAudioFile(forReading: file)
        let total = Double(audio.length) / max(audio.processingFormat.sampleRate, 1)
        status(L("Making captions on this Mac…"), 0)
        let collect = Task { () throws -> [Cue] in
            var made: [Cue] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds, end = CMTimeRangeGetEnd(result.range).seconds
                made += lines(text, from: start, to: end, joiner: joiner)
                status(L("Making captions on this Mac…"), min(1, end / max(total, 1)))
                report(made)
            }
            return made
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: audio) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
        } catch {
            collect.cancel()
            throw error
        }
        return try await collect.value
    }

    /// A recognised passage, cut into lines at the ends of sentences (and long sentences into shorter lines), each line
    /// given its share of the passage's time.
    static func lines(_ text: String, from start: Double, to end: Double, joiner: String) -> [Cue] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!。？！".contains(ch) { sentences.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
        var parts: [String] = []
        for sentence in sentences where !sentence.isEmpty {
            if joiner.isEmpty {
                var rest = Substring(sentence)
                while rest.count > 30 { parts.append(String(rest.prefix(30))); rest = rest.dropFirst(30) }
                if !rest.isEmpty { parts.append(String(rest)) }
            } else {
                let words = sentence.split(separator: " ")
                for i in stride(from: 0, to: words.count, by: 14) { parts.append(words[i..<min(i + 14, words.count)].joined(separator: " ")) }
            }
        }
        let length = Double(max(1, parts.reduce(0) { $0 + $1.count }))
        var t = start
        return parts.map { p in
            let d = max(0, end - start) * Double(p.count) / length
            defer { t += d }
            return Cue(start: t, end: t + d, text: p)
        }
    }
}

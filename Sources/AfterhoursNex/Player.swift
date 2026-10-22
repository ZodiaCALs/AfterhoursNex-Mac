import AVFoundation
import AppKit
import MediaPlayer
import Observation

/// Playback with AVFoundation: speeds that keep the voice natural, the place in every episode remembered, the next one
/// played after, a sleep timer, and the Mac's own Now Playing, media keys and Control Center.
@Observable @MainActor
final class Player {
    private(set) var episode: Episode?
    private(set) var showName = ""
    private(set) var artwork = ""
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var status = ""
    private(set) var speed: Float = UserDefaults.standard.object(forKey: "speed") as? Float ?? 1
    var sleepEnd: Date?
    var sleepAtEnd = false
    @ObservationIgnored private var queue: [Episode] = []
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private weak var store: Store?
    @ObservationIgnored private weak var captions: Captions?
    @ObservationIgnored private weak var video: VideoTool?
    @ObservationIgnored private var art: MPMediaItemArtwork?
    @ObservationIgnored private var lastNoted = Date.distantPast

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let self, (note.object as? AVPlayerItem) === self.player.currentItem { self.ended() } }
        }
        remoteCommands()
    }

    func attach(store: Store, captions: Captions, video: VideoTool) { self.store = store; self.captions = captions; self.video = video }

    var isLive: Bool { episode?.id.hasPrefix("radio:") ?? false }

    func play(_ e: Episode, in list: [Episode] = [], show: Show? = nil) {
        let s = show ?? store?.show(e.showID)
        episode = e
        showName = s?.name ?? e.summary
        artwork = e.image.isEmpty ? (s?.image ?? "") : e.image
        queue = list.isEmpty ? (s?.episodes ?? []) : list
        position = 0; duration = e.duration; status = ""
        let saved = store?.listening[e.id]
        let start = saved.map { !$0.done && $0.position > 5 ? $0.position - 2 : 0 } ?? 0
        captions?.load(e)
        Task {
            var address = e.audioURL
            if VideoTool.handles(address), let video {
                status = L("Getting the audio…")
                do { address = try await video.audio(for: address).absoluteString; status = "" } catch { status = error.localizedDescription; return }
                guard episode?.id == e.id else { return }
            }
            guard let url = URL(string: address) else { status = NexError.notAudio.localizedDescription; return }
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain
            player.replaceCurrentItem(with: item)
            if start > 0 && !isLive { _ = await player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            player.defaultRate = speed
            player.play()
            isPlaying = true
            loadArtwork()
            nowPlaying()
        }
    }

    func toggle() {
        guard episode != nil else { return }
        if isPlaying {
            player.pause(); isPlaying = false
            if let e = episode, !isLive { store?.listening[e.id] = Listening(position: position, duration: duration, done: false) }
            store?.saveListening(now: true)
        } else { player.play(); isPlaying = true }
        nowPlaying()
    }

    func seek(to seconds: Double) {
        position = max(0, seconds)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        captions?.tick(position)
        nowPlaying()
    }

    func skip(by seconds: Double) { seek(to: duration > 0 ? min(duration, position + seconds) : position + seconds) }

    func setSpeed(_ s: Float) {
        speed = s
        UserDefaults.standard.set(s, forKey: "speed")
        player.defaultRate = s
        if isPlaying { player.rate = s }
        nowPlaying()
    }
    func faster() { if let s = SPEEDS.first(where: { $0 > speed }) { setSpeed(s) } }
    func slower() { if let s = SPEEDS.last(where: { $0 < speed }) { setSpeed(s) } }

    func next() {
        guard let e = episode, let i = queue.firstIndex(where: { $0.id == e.id }), i + 1 < queue.count else { return }
        play(queue[i + 1], in: queue)
    }

    func sleep(minutes: Int?) { sleepAtEnd = false; sleepEnd = minutes.map { Date().addingTimeInterval(Double($0) * 60) } }
    func sleepAtEndOfEpisode() { sleepEnd = nil; sleepAtEnd = true }

    private func tick(_ t: Double) {
        guard let e = episode else { return }
        if t.isFinite { position = t }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        isPlaying = player.timeControlStatus != .paused
        // the place is noted every few seconds, so lists showing progress don't redraw twice a second
        if isPlaying, !isLive, let store, Date().timeIntervalSince(lastNoted) > 5 {
            lastNoted = Date()
            store.listening[e.id] = Listening(position: position, duration: duration, done: duration > 0 && position > duration - 30)
            store.saveListening()
        }
        if let end = sleepEnd, Date() >= end { sleepEnd = nil; if isPlaying { toggle() } }
        captions?.tick(position)
    }

    private func ended() {
        guard let e = episode else { return }
        store?.markPlayed(e, true)
        if sleepAtEnd { sleepAtEnd = false; isPlaying = false; nowPlaying(); return }
        if UserDefaults.standard.object(forKey: "continuous") as? Bool ?? true { next() } else { isPlaying = false; nowPlaying() }
    }

    // ---- the Mac's Now Playing, media keys and Control Center ----

    private func remoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == true { self?.toggle() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: -15) }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: 30) }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func nowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let e = episode else { center.nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: e.title, MPMediaItemPropertyArtist: showName,
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0,
                                   MPNowPlayingInfoPropertyIsLiveStream: isLive, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art { info[MPMediaItemPropertyArtwork] = art }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork() {
        art = nil
        guard !artwork.isEmpty, let url = URL(string: artwork) else { return }
        Task {
            guard let data = try? await Net.data(url), let image = NSImage(data: data) else { return }
            art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlaying()
        }
    }
}

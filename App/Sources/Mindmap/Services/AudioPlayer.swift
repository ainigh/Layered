import AVFoundation
import Observation

/// Plays a dropped recording, whole or from one sentence's start to its end, so proof and
/// transcript items can be heard. One clip plays at a time.
@MainActor
@Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    /// The recording playing, and where in it the clip started.
    private(set) var playing: URL?
    private(set) var from: Double?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopper: Task<Void, Never>?

    /// Plays `url` from `t0`, to `t1` when given (at least a second and a half) or to its end.
    func play(_ url: URL, from t0: Double = 0, to t1: Double? = nil) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.currentTime = t0
        p.play()
        player = p
        playing = url
        from = t0
        let length = t1.map { max($0 - t0, 1.5) } ?? max(p.duration - t0, 0)
        stopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopper?.cancel()
        stopper = nil
        player?.stop()
        player = nil
        playing = nil
        from = nil
    }

    func isPlaying(_ url: URL?, from t0: Double? = nil) -> Bool {
        url != nil && playing == url && (t0 == nil || from == t0)
    }
}

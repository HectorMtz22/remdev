import AVFoundation

protocol VideoEngineDelegate: AnyObject {
    func videoEngineDidFailPermanently(_ engine: VideoEngine, error: Error?)
}

class VideoEngine {
    private(set) var player: AVQueuePlayer
    weak var delegate: VideoEngineDelegate?

    /// Called on the main queue when the player instance is replaced during recreation.
    var onPlayerRecreated: ((AVQueuePlayer) -> Void)?

    private var looper: AVPlayerLooper?
    private var errorObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    private let url: URL
    private var retryCount = 0
    private let maxRetries = 3
    private let retryDelays: [TimeInterval] = [2, 4, 6]
    private var hasRecreatedPlayer = false

    init(url: URL, maxResolution: CGSize? = nil) {
        self.url = url
        self.maxResolution = maxResolution
        self.player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        startPlayback()
    }

    private let maxResolution: CGSize?

    private func startPlayback() {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["playable", "duration", "tracks"]
        )
        item.preferredForwardBufferDuration = 5

        // Decode at display resolution, not the video's native resolution
        if let res = maxResolution {
            item.preferredMaximumResolution = res
        }

        // Clean up previous looper/observers before creating new ones
        cleanupObservers()

        looper = AVPlayerLooper(player: player, templateItem: item)

        // Monitor looper status for failures
        statusObservation = looper?.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard let self else { return }
            if looper.status == .failed {
                self.handlePlaybackError(looper.error)
            }
        }

        // Observe item failures
        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.handlePlaybackError(error)
        }

        // Observe stalls
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackError(nil)
        }

        player.play()
    }

    private func handlePlaybackError(_ error: Error?) {
        guard retryCount < maxRetries else {
            // Exhausted retries — try manual seek-based loop as last resort
            fallbackToManualLoop()
            return
        }

        let delay = retryDelays[retryCount]
        retryCount += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.url.path) else {
                self.delegate?.videoEngineDidFailPermanently(self, error: error)
                return
            }
            self.player.removeAllItems()
            self.startPlayback()
        }
    }

    private func fallbackToManualLoop() {
        cleanupObservers()
        looper?.disableLooping()
        looper = nil

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        if let res = maxResolution {
            item.preferredMaximumResolution = res
        }
        player.removeAllItems()
        player.insert(item, after: nil)

        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero)
            self.player.play()
        }

        // Watch for the manual loop itself failing — trigger full recreation
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.recreatePlayer(error)
        }

        // Watchdog: if player stays paused unexpectedly for 5s, recreate
        startTimeControlWatchdog()

        player.play()
    }

    // MARK: - Experimental: Full Player Recreation

    /// Nuclear option — tears down the current AVQueuePlayer entirely and builds
    /// a fresh one. This handles cases where the player's internal decode pipeline
    /// is wedged and no amount of item-level retry will fix it.
    private func recreatePlayer(_ error: Error?) {
        guard !hasRecreatedPlayer else {
            // Already tried once — give up permanently
            delegate?.videoEngineDidFailPermanently(self, error: error)
            return
        }
        hasRecreatedPlayer = true

        // Tear down old player completely
        cleanupObservers()
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()

        // Build a brand new player
        let newPlayer = AVQueuePlayer()
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.isMuted = player.isMuted
        player = newPlayer

        // Reset retry state so the new player gets fresh attempts
        retryCount = 0

        // Notify the view layer so AVPlayerLayer can rebind
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPlayerRecreated?(self.player)
        }

        startPlayback()
    }

    /// Monitors `timeControlStatus` — if the player is supposed to be playing
    /// but stalls for too long, triggers recreation.
    private func startTimeControlWatchdog() {
        timeControlObservation?.invalidate()
        var stallStart: Date?

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .paused, .waitingToPlayAtSpecifiedRate:
                if stallStart == nil { stallStart = Date() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self else { return }
                    guard let start = stallStart,
                          Date().timeIntervalSince(start) >= 8,
                          self.player.timeControlStatus != .playing else { return }
                    stallStart = nil
                    self.recreatePlayer(nil)
                }
            case .playing:
                stallStart = nil
            @unknown default:
                break
            }
        }
    }

    private func cleanupObservers() {
        if let obs = errorObserver {
            NotificationCenter.default.removeObserver(obs)
            errorObserver = nil
        }
        if let obs = stallObserver {
            NotificationCenter.default.removeObserver(obs)
            stallObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
    }

    func tearDown() {
        cleanupObservers()
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }
}

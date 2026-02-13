import AVFoundation

protocol VideoEngineDelegate: AnyObject {
    func videoEngineDidFailPermanently(_ engine: VideoEngine, error: Error?)
}

class VideoEngine {
    let player: AVQueuePlayer
    weak var delegate: VideoEngineDelegate?

    private var looper: AVPlayerLooper?
    private var errorObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    private let url: URL
    private var retryCount = 0
    private let maxRetries = 3
    private let retryDelays: [TimeInterval] = [2, 4, 6]

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

        player.play()
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

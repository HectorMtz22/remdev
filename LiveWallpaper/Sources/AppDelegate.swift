import Cocoa
import AVFoundation
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var engines: [CGDirectDisplayID: VideoEngine] = [:]
    private var currentVideoURL: URL?
    private var isPlaying = false
    private var isMuted = true
    private var wasPlayingBeforeSleep = false
    private var pausedByPowerManager = false

    private var playPauseItem: NSMenuItem!
    private var muteItem: NSMenuItem!
    private var screensaverItem: NSMenuItem!
    private var lockscreenItem: NSMenuItem!
    private var convertItem: NSMenuItem!

    private let defaults = UserDefaults.standard
    private let videoPathKey = "lastVideoPath"
    private let screensaverKey = "alsoSetScreensaver"
    private let lockscreenKey = "alsoSetLockscreen"
    private let convertKey = "convertToAerialFormat"

    private var isConvertingLockscreen = false
    private var cachedAerialPath: String? // path to the converted HEVC file
    private var activeAerialTarget: String? // path to the aerial being replaced

    private var powerManager: PowerManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        powerManager = PowerManager()
        powerManager.delegate = self

        // Restore lockscreen aerial cache if available
        if defaults.bool(forKey: lockscreenKey) {
            let cacheDir = NSHomeDirectory() + "/Library/Application Support/LiveWallpaper"
            let cachePath = cacheDir + "/lockscreen-aerial.mov"
            if FileManager.default.fileExists(atPath: cachePath),
               let aerialID = findActiveAerialID() {
                let aerialsDir = NSHomeDirectory()
                    + "/Library/Application Support/com.apple.wallpaper/aerials/videos"
                cachedAerialPath = cachePath
                activeAerialTarget = aerialsDir + "/\(aerialID).mov"
                reapplyAerialLockscreen()
            }
        }

        // Restore last video
        if let path = defaults.string(forKey: videoPathKey),
           FileManager.default.fileExists(atPath: path) {
            setVideo(url: URL(fileURLWithPath: path))
        }

        // Watch for display changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Tear down on sleep/lock, rebuild on wake/unlock
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(displayDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidSleep),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidWake),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        // Screen unlock — re-apply aerial after WallpaperAgent restores the original
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "play.rectangle.fill",
                accessibilityDescription: "Live Wallpaper"
            )
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(
            title: "Select Video...", action: #selector(selectVideo), keyEquivalent: "o"
        ))
        menu.addItem(NSMenuItem.separator())

        playPauseItem = NSMenuItem(
            title: "Pause", action: #selector(togglePlayback), keyEquivalent: "p"
        )
        playPauseItem.isEnabled = false
        menu.addItem(playPauseItem)

        muteItem = NSMenuItem(
            title: "Unmute", action: #selector(toggleMute), keyEquivalent: "m"
        )
        muteItem.isEnabled = false
        menu.addItem(muteItem)

        menu.addItem(NSMenuItem.separator())

        screensaverItem = NSMenuItem(
            title: "Also Set as Screen Saver",
            action: #selector(toggleScreensaver),
            keyEquivalent: "s"
        )
        screensaverItem.state = defaults.bool(forKey: screensaverKey) ? .on : .off
        menu.addItem(screensaverItem)

        lockscreenItem = NSMenuItem(
            title: "Also Set as Lock Screen",
            action: #selector(toggleLockscreen),
            keyEquivalent: "l"
        )
        lockscreenItem.state = defaults.bool(forKey: lockscreenKey) ? .on : .off
        menu.addItem(lockscreenItem)

        convertItem = NSMenuItem(
            title: "  Convert to Aerial Format (ffmpeg)",
            action: #selector(toggleConvert),
            keyEquivalent: ""
        )
        convertItem.state = defaults.bool(forKey: convertKey) ? .on : .off
        menu.addItem(convertItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Remove Wallpaper", action: #selector(removeWallpaper), keyEquivalent: "r"
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit", action: #selector(quit), keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    // MARK: - Video Selection

    @objc private func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video for your live wallpaper"

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Validate video is playable before committing (async to avoid blocking main thread)
        let asset = AVURLAsset(url: url)
        Task { @MainActor in
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            guard isPlayable else {
                showAlert(
                    title: "Unplayable Video",
                    message: "The selected file cannot be played. Choose a different video."
                )
                return
            }

            defaults.set(url.path, forKey: videoPathKey)
            setVideo(url: url)

            if defaults.bool(forKey: screensaverKey) {
                updateScreensaver(videoURL: url)
            }
            if defaults.bool(forKey: lockscreenKey) {
                updateAerialLockscreen(videoURL: url)
            }
        }
    }

    // MARK: - Video Playback

    private func setVideo(url: URL) {
        currentVideoURL = url
        tearDown()

        // Single engine for all displays — one decode pipeline, multiple layers
        // Decode at the largest display's backing pixel size, not the video's native res
        let maxRes = NSScreen.screens
            .map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                          height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height }
        let engine = VideoEngine(url: url, maxResolution: maxRes)
        engine.isMuted = isMuted
        engine.delegate = self

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            engines[displayID] = engine
            setupWindow(for: screen, player: engine.player)
        }

        isPlaying = true
        pausedByPowerManager = false
        playPauseItem.title = "Pause"
        playPauseItem.isEnabled = true
        muteItem.isEnabled = true

        // If on low battery right now, pause immediately
        if powerManager.currentState.shouldPausePlayback {
            pauseForPowerSaving()
        }

    }

    private func setupWindow(for screen: NSScreen, player: AVPlayer) {
        let displayID = screen.displayID

        let window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: false)

        let playerView = VideoPlayerView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            player: player
        )
        playerView.autoresizingMask = [.width, .height]

        window.contentView = playerView
        window.orderFront(nil)

        windows[displayID] = window
    }

    private func tearDown() {
        // Deduplicate since multiple displays share the same engine
        var seen = Set<ObjectIdentifier>()
        for engine in engines.values {
            if seen.insert(ObjectIdentifier(engine)).inserted {
                engine.tearDown()
            }
        }
        engines.removeAll()

        for (_, window) in windows {
            window.close()
        }
        windows.removeAll()
    }

    // MARK: - Controls

    @objc private func togglePlayback() {
        isPlaying.toggle()
        pausedByPowerManager = false
        if let engine = engines.values.first {
            isPlaying ? engine.player.play() : engine.player.pause()
        }
        playPauseItem.title = isPlaying ? "Pause" : "Play"
    }

    @objc private func toggleMute() {
        isMuted.toggle()
        if let engine = engines.values.first {
            engine.isMuted = isMuted
        }
        muteItem.title = isMuted ? "Unmute" : "Mute"
    }

    @objc private func toggleScreensaver() {
        let enabled = screensaverItem.state != .on
        screensaverItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: screensaverKey)

        if enabled, let url = currentVideoURL {
            updateScreensaver(videoURL: url)
        }
    }

    @objc private func toggleLockscreen() {
        let enabled = lockscreenItem.state != .on
        lockscreenItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: lockscreenKey)

        if enabled, let url = currentVideoURL {
            updateAerialLockscreen(videoURL: url)
        }
    }

    @objc private func toggleConvert() {
        let enabled = convertItem.state != .on
        convertItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: convertKey)
    }

    // MARK: - Power Management

    private func pauseForPowerSaving() {
        guard isPlaying else { return }
        pausedByPowerManager = true
        engines.values.first?.player.pause()
        isPlaying = false
        playPauseItem.title = "Play"
    }

    private func resumeFromPowerSaving() {
        guard pausedByPowerManager else { return }
        pausedByPowerManager = false
        engines.values.first?.player.play()
        isPlaying = true
        playPauseItem.title = "Pause"
    }

    // MARK: - Screen Saver Integration

    private func updateScreensaver(videoURL: URL) {
        let fm = FileManager.default
        let saverDest = NSHomeDirectory() + "/Library/Screen Savers/LiveLockscreen.saver"
        let resourcesPath = saverDest + "/Contents/Resources"

        if !fm.fileExists(atPath: saverDest) {
            guard let bundledSaver = Bundle.main.path(forResource: "LiveLockscreen", ofType: "saver") else {
                showAlert(
                    title: "Screen Saver Not Available",
                    message: "LiveLockscreen.saver was not found in the app bundle. Rebuild the app."
                )
                return
            }
            do {
                try fm.copyItem(atPath: bundledSaver, toPath: saverDest)
            } catch {
                showAlert(
                    title: "Installation Failed",
                    message: "Could not install screen saver: \(error.localizedDescription)"
                )
                return
            }
        }

        try? fm.removeItem(atPath: resourcesPath + "/video.mp4")
        try? fm.removeItem(atPath: resourcesPath + "/video.mov")

        let dest = resourcesPath + "/video.\(videoURL.pathExtension)"
        do {
            try fm.copyItem(at: videoURL, to: URL(fileURLWithPath: dest))
        } catch {
            showAlert(
                title: "Video Copy Failed",
                message: error.localizedDescription
            )
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let signProcess = Process()
            signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProcess.arguments = ["--force", "--deep", "--sign", "-", saverDest]
            try? signProcess.run()
            signProcess.waitUntilExit()

            let setProcess = Process()
            setProcess.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            setProcess.arguments = [
                "-currentHost", "write", "com.apple.screensaver",
                "moduleDict", "-dict",
                "moduleName", "LiveLockscreen",
                "path", saverDest,
                "type", "0"
            ]
            try? setProcess.run()
            setProcess.waitUntilExit()
        }
    }

    // MARK: - Lock Screen (Aerial Replacement)

    private func findActiveAerialID() -> String? {
        let plistPath = NSHomeDirectory()
            + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let allSpaces = plist["AllSpacesAndDisplays"] as? [String: Any],
              let desktop = allSpaces["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let first = choices.first,
              let configData = first["Configuration"] as? Data,
              let config = try? PropertyListSerialization.propertyList(
                  from: configData, options: [], format: nil
              ) as? [String: Any],
              let assetID = config["assetID"] as? String
        else { return nil }
        return assetID
    }

    private func updateAerialLockscreen(videoURL: URL) {
        let aerialsDir = NSHomeDirectory()
            + "/Library/Application Support/com.apple.wallpaper/aerials/videos"

        guard let aerialID = findActiveAerialID() else {
            showAlert(
                title: "No Active Aerial",
                message: "Could not detect the active aerial wallpaper. Select an aerial wallpaper in System Settings first."
            )
            return
        }

        let targetFile = aerialsDir + "/\(aerialID).mov"
        guard FileManager.default.fileExists(atPath: targetFile) else {
            showAlert(
                title: "Aerial Not Downloaded",
                message: "The active aerial video is not downloaded yet. Open System Settings > Wallpaper and ensure it's downloaded."
            )
            return
        }

        // Backup original if needed
        let backupFile = targetFile + ".bak"
        if !FileManager.default.fileExists(atPath: backupFile) {
            try? FileManager.default.copyItem(atPath: targetFile, toPath: backupFile)
        }

        let shouldConvert = defaults.bool(forKey: convertKey)
        let inputPath = videoURL.path

        if shouldConvert {
            // Full ffmpeg HEVC conversion
            guard !isConvertingLockscreen else {
                showAlert(
                    title: "Conversion In Progress",
                    message: "A lock screen video conversion is already running. Please wait."
                )
                return
            }

            let ffmpegPath: String
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
                ffmpegPath = "/opt/homebrew/bin/ffmpeg"
            } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") {
                ffmpegPath = "/usr/local/bin/ffmpeg"
            } else {
                showAlert(
                    title: "ffmpeg Required",
                    message: "Install ffmpeg for aerial format conversion:\n\nbrew install ffmpeg"
                )
                return
            }

            isConvertingLockscreen = true
            lockscreenItem.title = "Lock Screen: Converting..."

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tmpFile = NSTemporaryDirectory() + "aerial-\(UUID().uuidString).mov"

                let ffmpeg = Process()
                ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath)
                ffmpeg.arguments = [
                    "-y", "-i", inputPath,
                    "-c:v", "hevc_videotoolbox", "-profile:v", "main10",
                    "-b:v", "12000k", "-maxrate", "16000k", "-bufsize", "24000k",
                    "-tag:v", "hvc1",
                    "-pix_fmt", "p010le",
                    "-vf", "scale=3840:2160:force_original_aspect_ratio=decrease,pad=3840:2160:(ow-iw)/2:(oh-ih)/2,fps=240",
                    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                    "-an",
                    tmpFile
                ]
                ffmpeg.standardOutput = FileHandle.nullDevice
                ffmpeg.standardError = FileHandle.nullDevice

                do {
                    try ffmpeg.run()
                    ffmpeg.waitUntilExit()

                    guard ffmpeg.terminationStatus == 0 else {
                        throw NSError(domain: "LiveWallpaper", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with code \(ffmpeg.terminationStatus)"])
                    }

                    let cacheDir = NSHomeDirectory()
                        + "/Library/Application Support/LiveWallpaper"
                    try FileManager.default.createDirectory(
                        atPath: cacheDir, withIntermediateDirectories: true)
                    let cachePath = cacheDir + "/lockscreen-aerial.mov"
                    try? FileManager.default.removeItem(atPath: cachePath)
                    try FileManager.default.moveItem(atPath: tmpFile, toPath: cachePath)

                    try? FileManager.default.removeItem(atPath: targetFile)
                    try FileManager.default.copyItem(atPath: cachePath, toPath: targetFile)
                    Self.restartWallpaperAgent()

                    DispatchQueue.main.async {
                        self?.isConvertingLockscreen = false
                        self?.cachedAerialPath = cachePath
                        self?.activeAerialTarget = targetFile
                        self?.lockscreenItem.title = "Also Set as Lock Screen"
                    }
                } catch {
                    try? FileManager.default.removeItem(atPath: tmpFile)
                    DispatchQueue.main.async {
                        self?.isConvertingLockscreen = false
                        self?.lockscreenItem.title = "Also Set as Lock Screen"
                        self?.showAlert(
                            title: "Lock Screen Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        } else {
            // Direct copy — no conversion (off main thread for large files)
            let cacheDir = NSHomeDirectory()
                + "/Library/Application Support/LiveWallpaper"
            let cachePath = cacheDir + "/lockscreen-aerial.mov"

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try FileManager.default.createDirectory(
                        atPath: cacheDir, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(atPath: cachePath)
                    try FileManager.default.copyItem(atPath: inputPath, toPath: cachePath)

                    try? FileManager.default.removeItem(atPath: targetFile)
                    try FileManager.default.copyItem(atPath: cachePath, toPath: targetFile)

                    Self.restartWallpaperAgent()

                    DispatchQueue.main.async {
                        self?.cachedAerialPath = cachePath
                        self?.activeAerialTarget = targetFile
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showAlert(
                            title: "Lock Screen Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private static func restartWallpaperAgent() {
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["WallpaperAgent"]
        try? killall.run()
        killall.waitUntilExit()
    }

    /// Re-copy the cached converted aerial over the target (fast, no ffmpeg)
    private func reapplyAerialLockscreen() {
        guard defaults.bool(forKey: lockscreenKey),
              let cache = cachedAerialPath,
              let target = activeAerialTarget,
              FileManager.default.fileExists(atPath: cache)
        else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.copyItem(atPath: cache, toPath: target)
            Self.restartWallpaperAgent()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func removeWallpaper() {
        tearDown()
        currentVideoURL = nil
        isPlaying = false
        defaults.removeObject(forKey: videoPathKey)
        playPauseItem.title = "Pause"
        playPauseItem.isEnabled = false
        muteItem.isEnabled = false
    }

    // MARK: - Screen & Sleep Handling

    @objc private func screensDidChange() {
        guard let url = currentVideoURL else { return }
        setVideo(url: url)
    }

    @objc private func displayDidSleep() {
        guard !windows.isEmpty else { return }
        wasPlayingBeforeSleep = isPlaying
        tearDown()
    }

    @objc private func displayDidWake() {
        reapplyAerialLockscreen()
        guard windows.isEmpty, wasPlayingBeforeSleep, let url = currentVideoURL else { return }
        setVideo(url: url)
    }

    @objc private func screenDidUnlock() {
        // Delay to let WallpaperAgent finish restoring the original aerial,
        // then overwrite it again with our cached version
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reapplyAerialLockscreen()
        }
    }

    @objc private func quit() {
        tearDown()
        NSApp.terminate(nil)
    }
}

// MARK: - PowerManagerDelegate

extension AppDelegate: PowerManagerDelegate {
    func powerStateDidChange(_ state: PowerState) {
        if state.shouldPausePlayback {
            pauseForPowerSaving()
        } else {
            resumeFromPowerSaving()
        }
    }
}

// MARK: - VideoEngineDelegate

extension AppDelegate: VideoEngineDelegate {
    func videoEngineDidFailPermanently(_ engine: VideoEngine, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.showAlert(
                title: "Playback Failed",
                message: error?.localizedDescription ?? "The video could not be played after multiple retries."
            )
        }
    }
}

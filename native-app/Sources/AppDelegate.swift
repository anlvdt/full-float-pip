import Cocoa
import WebKit

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var floatWindow: FloatWindow?
    var messageHandler: NativeMessageHandler?
    var httpServer: LocalHTTPServer?
    let hotkeys = VibeHotkeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start local HTTP server (provides valid Referer for YouTube embed + Vibe-Sync REST API)
        httpServer = LocalHTTPServer()
        httpServer?.onCommand = { [weak self] command, params in
            guard let self = self else {
                return ["success": false, "error": "App not ready"]
            }

            // Ghost preference + status work even when no float window is open.
            switch command {
            case "ghost", "toggleGhost":
                var ghostState = false
                DispatchQueue.main.sync {
                    ghostState = self.toggleGhostPreferringWindow()
                }
                return ["success": true, "isGhost": ghostState]
            case "status":
                if let win = self.floatWindow {
                    var progress: [String: Any] = [:]
                    DispatchQueue.main.sync { progress = win.progressPayload() }
                    return [
                        "success": true,
                        "title": win.videoTitle,
                        "isPlaying": win.isPlaying,
                        "isGhost": win.isGhostMode,
                        "autoNext": FloatWindow.preferredAutoNextEpisode,
                        "skipIntro": FloatWindow.preferredAutoSkipIntro,
                        "sizePreset": FloatWindow.savedSizePreset.rawValue,
                        "opacity": win.alphaValue,
                        "volume": win.currentVolume,
                        "width": win.frame.width,
                        "height": win.frame.height,
                        "currentTime": win.playbackElapsed,
                        "duration": win.playbackDuration,
                        "progress": progress
                    ]
                }
                return [
                    "success": true,
                    "title": "",
                    "isPlaying": false,
                    "isGhost": FloatWindow.preferredGhostMode,
                    "opacity": 1.0,
                    "volume": 1.0,
                    "width": 0,
                    "height": 0,
                    "currentTime": 0,
                    "duration": 0,
                    "progress": [:] as [String: Any]
                ]
            default:
                break
            }

            guard let win = self.floatWindow else {
                return ["success": false, "error": "No active window"]
            }
            switch command {
            case "toggle", "togglePlayPause":
                DispatchQueue.main.async { win.togglePlayPause() }
                return ["success": true, "isPlaying": win.isPlaying]
            case "pause":
                DispatchQueue.main.async { win.pause() }
                return ["success": true, "paused": true]
            case "play":
                DispatchQueue.main.async { win.play() }
                return ["success": true, "playing": true]
            case "forward":
                DispatchQueue.main.async { win.skipForward() }
                return ["success": true]
            case "backward":
                DispatchQueue.main.async { win.skipBackward() }
                return ["success": true]
            case "duck":
                DispatchQueue.main.async { win.duckVolume() }
                return ["success": true, "ducked": true]
            case "unduck":
                DispatchQueue.main.async { win.unduckVolume() }
                return ["success": true, "ducked": false]
            case "opacity":
                if let valStr = params["val"], let val = Double(valStr) {
                    DispatchQueue.main.async { win.setOpacity(val) }
                    return ["success": true, "opacity": val]
                }
                return ["success": false, "error": "Missing val parameter"]
            case "bigger", "grow", "sizeup":
                var size = NSSize.zero
                DispatchQueue.main.sync { size = win.adjustWindowScale(by: 1.18) }
                return ["success": true, "width": size.width, "height": size.height]
            case "smaller", "shrink", "sizedown":
                var size = NSSize.zero
                DispatchQueue.main.sync { size = win.adjustWindowScale(by: 1.0 / 1.18) }
                return ["success": true, "width": size.width, "height": size.height]
            case "size", "resize":
                if let wStr = params["w"] ?? params["width"], let w = Double(wStr) {
                    var size = NSSize.zero
                    DispatchQueue.main.sync { size = win.setWindowWidth(CGFloat(w)) }
                    return ["success": true, "width": size.width, "height": size.height]
                }
                if let factorStr = params["factor"] ?? params["scale"], let factor = Double(factorStr), factor > 0 {
                    var size = NSSize.zero
                    DispatchQueue.main.sync { size = win.adjustWindowScale(by: CGFloat(factor)) }
                    return ["success": true, "width": size.width, "height": size.height]
                }
                return [
                    "success": true,
                    "width": win.frame.width,
                    "height": win.frame.height
                ]
            case "boss":
                var visible = false
                DispatchQueue.main.sync {
                    win.toggleBossHide()
                    visible = win.isWindowVisible
                }
                return ["success": true, "visible": visible]
            case "nextEpisode", "next":
                var ok = false
                DispatchQueue.main.sync { ok = win.switchEpisode(by: 1) }
                return ["success": ok]
            case "prevEpisode", "prev", "previousEpisode":
                var ok = false
                DispatchQueue.main.sync { ok = win.switchEpisode(by: -1) }
                return ["success": ok]
            case "autoNext", "autonext":
                if let val = params["val"] ?? params["on"] {
                    let enabled = ["1","true","on","yes"].contains(val.lowercased())
                    DispatchQueue.main.sync {
                        _ = FloatWindow.setPreferredAutoNextEpisode(enabled)
                        win.refreshWatchAssistFromAPI()
                    }
                    return ["success": true, "autoNext": enabled]
                } else {
                    var enabled = false
                    DispatchQueue.main.sync {
                        win.toggleAutoNextEpisode()
                        enabled = FloatWindow.preferredAutoNextEpisode
                    }
                    return ["success": true, "autoNext": enabled]
                }
            case "skipIntro", "skipintro", "autoSkipIntro":
                if let val = params["val"] ?? params["on"] {
                    let enabled = ["1","true","on","yes"].contains(val.lowercased())
                    DispatchQueue.main.sync {
                        _ = FloatWindow.setPreferredAutoSkipIntro(enabled)
                        win.refreshWatchAssistFromAPI()
                    }
                    return ["success": true, "skipIntro": enabled]
                } else {
                    var enabled = false
                    DispatchQueue.main.sync {
                        win.toggleAutoSkipIntro()
                        enabled = FloatWindow.preferredAutoSkipIntro
                    }
                    return ["success": true, "skipIntro": enabled]
                }
            case "skipIntroNow", "skipintronow":
                DispatchQueue.main.sync { win.manualSkipIntro() }
                return ["success": true]
            case "preset", "sizePreset":
                let name = (params["val"] ?? params["name"] ?? params["id"] ?? "").lowercased()
                let map: [String: FloatWindow.SizePreset] = [
                    "mini": .mini, "nho": .mini, "small": .mini,
                    "standard": .standard, "vua": .standard, "medium": .standard,
                    "wide": .wide, "rong": .wide,
                    "pocket": .pocket, "lon": .pocket, "max": .pocket
                ]
                guard let preset = map[name] else {
                    return ["success": false, "error": "Unknown preset. Use mini|standard|wide|pocket"]
                }
                var width: CGFloat = 0
                DispatchQueue.main.sync {
                    win.applySizePreset(preset)
                    width = win.frame.width
                }
                return ["success": true, "preset": preset.rawValue, "width": width]
            default:
                return ["success": false, "error": "Unknown command \(command)"]
            }
        }

        httpServer?.start { port in
            NSLog("[FloatVideo] HTTP server started on port \(port)")
        }

        // Consumed hotkeys so they do not also type into Cursor / the terminal.
        hotkeys.onRegisterFailed = { [weak self] label in
            DispatchQueue.main.async {
                self?.floatWindow?.showHUD("Phím tắt \(label) lỗi")
            }
        }
        hotkeys.install(
            playPause: { [weak self] in self?.floatWindow?.togglePlayPause() },
            ghost: { [weak self] in
                guard let self = self else { return }
                let state = self.toggleGhostPreferringWindow()
                self.messageHandler?.sendMessage([
                    "type": "status",
                    "isGhost": state
                ])
            },
            boss: { [weak self] in self?.floatWindow?.toggleBossHide() },
            duck: { [weak self] in self?.floatWindow?.toggleDuck() },
            back: { [weak self] in self?.floatWindow?.skipBackward() },
            forward: { [weak self] in self?.floatWindow?.skipForward() },
            volumeUp: { [weak self] in self?.floatWindow?.adjustVolume(by: 0.08) },
            volumeDown: { [weak self] in self?.floatWindow?.adjustVolume(by: -0.08) },
            sizeUp: { [weak self] in self?.floatWindow?.growWindow() },
            sizeDown: { [weak self] in self?.floatWindow?.shrinkWindow() },
            prevEpisode: { [weak self] in self?.floatWindow?.prevEpisode() },
            nextEpisode: { [weak self] in self?.floatWindow?.nextEpisode() },
            sizeMini: { [weak self] in self?.floatWindow?.applySizePreset(.mini) },
            sizeStandard: { [weak self] in self?.floatWindow?.applySizePreset(.standard) },
            sizeWide: { [weak self] in self?.floatWindow?.applySizePreset(.wide) }
        )

        // Start Native Messaging
        messageHandler = NativeMessageHandler()
        messageHandler?.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                self?.handleMessage(message)
            }
        }
        messageHandler?.startListening()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Don't quit when window closes
    }

    func handleMessage(_ msg: [String: Any]) {
        guard let action = msg["action"] as? String else {
            messageHandler?.sendMessage([
                "type": "error",
                "error": "Missing 'action' field"
            ])
            return
        }

        switch action {
        case "open":
            let url = msg["url"] as? String ?? ""
            let videoSrc = msg["videoSrc"] as? String ?? ""
            let embedUrl = msg["embedUrl"] as? String ?? ""
            let title = msg["title"] as? String ?? "Float Video"
            let site = msg["site"] as? String ?? "generic"
            let width = msg["width"] as? CGFloat
                ?? CGFloat(msg["width"] as? Int ?? 640)
            let height = msg["height"] as? CGFloat
                ?? CGFloat(msg["height"] as? Int ?? 360)
            let currentTime = msg["currentTime"] as? Double ?? 0
            let movieContext = (msg["movieContext"] as? [String: Any]).flatMap { MovieContext(dict: $0) }

            // Parse cookies
            var cookies: [[String: Any]] = []
            if let rawCookies = msg["cookies"] as? [[String: Any]] {
                cookies = rawCookies
            }

            openFloatWindow(
                url: url, videoSrc: videoSrc.isEmpty ? nil : videoSrc,
                embedUrl: embedUrl.isEmpty ? nil : embedUrl,
                title: title, width: width, height: height,
                currentTime: currentTime, site: site,
                cookies: cookies,
                playerPrefs: msg["playerPrefs"] as? [String: Any],
                movieContext: movieContext
            )

            messageHandler?.sendMessage([
                "type": "status",
                "status": "opened",
                "title": title,
                "isGhost": currentGhostState()
            ])

        case "close":
            closeFloatWindow()
            messageHandler?.sendMessage([
                "type": "status",
                "status": "closed"
            ])

        case "ping":
            messageHandler?.sendMessage([
                "type": "status",
                "status": "pong"
            ])

        case "toggleGhost":
            let ghostState = toggleGhostPreferringWindow()
            messageHandler?.sendMessage([
                "type": "status",
                "isGhost": ghostState
            ])

        case "togglePlayPause":
            floatWindow?.togglePlayPause()
            messageHandler?.sendMessage([
                "type": "status",
                "isPlaying": floatWindow?.isPlaying ?? false
            ])

        case "pause":
            floatWindow?.pause()
            messageHandler?.sendMessage(["type": "status", "paused": true])

        case "play":
            floatWindow?.play()
            messageHandler?.sendMessage(["type": "status", "playing": true])

        case "skipForward":
            floatWindow?.skipForward()
            messageHandler?.sendMessage(["type": "status", "ok": true])

        case "skipBackward":
            floatWindow?.skipBackward()
            messageHandler?.sendMessage(["type": "status", "ok": true])

        case "duck":
            floatWindow?.duckVolume()
            messageHandler?.sendMessage(["type": "status", "ducked": true])

        case "unduck":
            floatWindow?.unduckVolume()
            messageHandler?.sendMessage(["type": "status", "unducked": true])

        case "setOpacity":
            if let val = msg["value"] as? Double {
                floatWindow?.setOpacity(val)
                messageHandler?.sendMessage(["type": "status", "opacity": val])
            }

        case "toggleBoss":
            floatWindow?.toggleBossHide()
            messageHandler?.sendMessage(["type": "status", "visible": floatWindow?.isWindowVisible ?? false])

        case "nextEpisode":
            let ok = floatWindow?.switchEpisode(by: 1) ?? false
            messageHandler?.sendMessage(["type": "status", "ok": ok])

        case "prevEpisode":
            let ok = floatWindow?.switchEpisode(by: -1) ?? false
            messageHandler?.sendMessage(["type": "status", "ok": ok])

        case "getStatus":
            var progress: [String: Any] = [:]
            if let win = floatWindow {
                progress = win.progressPayload()
            }
            messageHandler?.sendMessage([
                "type": "status",
                "title": floatWindow?.videoTitle ?? "",
                "isPlaying": floatWindow?.isPlaying ?? false,
                "isGhost": currentGhostState(),
                "opacity": floatWindow?.alphaValue ?? 1.0,
                "volume": floatWindow?.currentVolume ?? 1.0,
                "currentTime": floatWindow?.playbackElapsed ?? 0,
                "duration": floatWindow?.playbackDuration ?? 0,
                "progress": progress
            ])

        default:
            messageHandler?.sendMessage([
                "type": "error",
                "error": "Unknown action: \(action)"
            ])
        }
    }

    /// Live window state when open; otherwise the persisted preference (default ON).
    func currentGhostState() -> Bool {
        floatWindow?.isGhostMode ?? FloatWindow.preferredGhostMode
    }

    /// Toggle on the open window, or flip+persist preference when no window exists.
    @discardableResult
    func toggleGhostPreferringWindow() -> Bool {
        if let win = floatWindow {
            win.toggleGhostMode()
            return win.isGhostMode
        }
        return FloatWindow.togglePreferredGhostMode()
    }

    func openFloatWindow(url: String, videoSrc: String?, embedUrl: String?,
                         title: String, width: CGFloat, height: CGFloat,
                         currentTime: Double, site: String,
                         cookies: [[String: Any]] = [],
                         playerPrefs: [String: Any]? = nil,
                         movieContext: MovieContext? = nil) {
        closeFloatWindow()

        floatWindow = FloatWindow(
            videoWidth: width,
            videoHeight: height,
            videoTitle: title
        )

        floatWindow?.applyMovieContext(movieContext)

        floatWindow?.loadVideo(
            url: url, videoSrc: videoSrc, embedUrl: embedUrl,
            currentTime: currentTime, site: site,
            // Provider, not a snapshot: the HTTP server starts asynchronously and
            // its port is still 0 when the first open message arrives.
            httpServerPortProvider: { [weak self] in self?.httpServer?.port ?? 0 },
            cookies: cookies,
            playerPrefs: playerPrefs
        )

        floatWindow?.onProgress = { [weak self] payload in
            self?.messageHandler?.sendMessage(payload)
        }

        floatWindow?.onClose = { [weak self] in
            self?.floatWindow = nil
            self?.messageHandler?.sendMessage([
                "type": "status",
                "status": "closed"
            ])
        }

        floatWindow?.show()
    }

    func closeFloatWindow() {
        // Prefer closeWindow so PROGRESS + cleanup run. Clear onClose first so a
        // replace-open does not spam status:closed to Chrome mid-handoff.
        if let win = floatWindow {
            win.onClose = nil
            win.closeWindow()
        }
        floatWindow = nil
    }
}

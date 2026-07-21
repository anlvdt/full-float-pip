import Cocoa
import WebKit
import QuartzCore

// MARK: - LoadingOverlayView — Loading overlay (auto-centered spinner)

private class LoadingOverlayView: NSView {
    var spinnerLayer: CALayer?

    override func layout() {
        super.layout()
        guard let spinner = spinnerLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        CATransaction.commit()
    }
}

// MARK: - DraggableTitleBar — Title bar that supports drag-to-move window

private class DraggableTitleBar: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - ProgressClickView — Progress bar click area

private class ProgressClickView: NSView {
    var onSeek: ((Double) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let percent = max(0, min(1, Double(loc.x / bounds.width)))
        onSeek?(percent)
    }
}

// MARK: - FloatWindow — Always-on-top floating video window

class FloatWindow: NSPanel, WKNavigationDelegate {

    private var webView: WKWebView!
    private var titleBarView: NSView!
    private var titleLabel: NSTextField!
    private var controlBarView: NSView!
    private var playPauseButton: NSButton!
    private var skipButton: NSButton!
    private var volumeButton: NSButton!
    private var volumeSlider: NSSlider!
    private var timeLabel: NSTextField!
    private var progressBg: NSView!
    private var progressPlayed: NSView!
    private var updateTimer: Timer?
    private var videoTitle: String
    private var isPlaying = true
    private var userWantsMute = false
    private var videoAspectRatio: CGFloat = 16.0 / 9.0

    // Video loading parameters (used by WKNavigationDelegate callbacks)
    private var currentSite: String = "generic"
    private var currentVideoTime: Double = 0
    private var hasInjectedJS = false
    private var hasInjectedAdSkip = false
    private var lastAdSkipCount = 0
    private var lastAdFFCount = 0
    private var currentPageURL: String = ""
    // Queried lazily: the local HTTP server starts asynchronously and its port
    // is still 0 when the open message arrives, so a snapshot taken in
    // loadVideo would permanently disable the YouTube embed fallback.
    private var httpServerPortProvider: (() -> UInt16)?
    private var loadingOverlay: NSView?
    private var hasTriedYouTubeEmbedFallback = false
    private var youtubeEmbedFallbackURL: URL?
    private var youtubeFallbackWorkItem: DispatchWorkItem?
    private var reinjectLayoutWorkItem: DispatchWorkItem?

    private enum LoadingStrategy {
        case directVideo, youtubeEmbed, siteEmbed, fullPageInject
    }
    private var loadingStrategy: LoadingStrategy = .fullPageInject

    private static let frameKey = "FloatVideoWindowFrame"

    var onClose: (() -> Void)?

    // For hover show/hide control bar (cursor-position polling)
    private var isHovering = false
    private var hideTimer: DispatchWorkItem?
    private var cursorPollTimer: Timer?
    private var cursorWasInside = false

    // For window resize dragging
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    // For window resizing
    private var isResizing = false
    private var resizeEdge: ResizeEdge = .none
    private let resizeBorderWidth: CGFloat = 12

    enum ResizeEdge {
        case none
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    init(videoWidth: CGFloat, videoHeight: CGFloat, videoTitle: String) {
        self.videoTitle = videoTitle

        let titleBarHeight: CGFloat = 30
        let windowWidth = max(videoWidth, 320)
        let windowHeight = max(videoHeight, 180)

        self.videoAspectRatio = windowWidth / windowHeight

        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        self.contentAspectRatio = NSSize(width: windowWidth, height: windowHeight)
        configureWindow()
        setupUI(width: windowWidth, height: windowHeight, titleBarHeight: titleBarHeight)
        positionWindow()
    }

    // MARK: - Window Configuration

    private func configureWindow() {
        // Key setting 1: Very high window level -- overlay fullscreen apps
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)

        // Key setting 2: Collection behavior -- visible on all Spaces/desktops
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]

        // Save position after drag ends (performDrag does not trigger mouseUp)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
            object: self, queue: .main) { [weak self] _ in
            self?.saveWindowFrame()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: self, queue: .main) { [weak self] _ in
            self?.scheduleInjectedLayoutRefresh()
        }

        // Key setting 3: Floating panel properties
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear

        // Window size constraints (based on video aspect ratio, prevent minSize from breaking locked aspect ratio)
        let minW: CGFloat = 200
        let maxW: CGFloat = 1920
        self.minSize = NSSize(width: minW, height: minW / videoAspectRatio)
        self.maxSize = NSSize(width: maxW, height: maxW / videoAspectRatio)
    }

    // MARK: - UI Setup

    private func setupUI(width: CGFloat, height: CGFloat, titleBarHeight: CGFloat) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        container.layer?.borderWidth = 0.5

        // Title bar (using DraggableTitleBar for drag support)
        titleBarView = DraggableTitleBar(frame: NSRect(
            x: 0, y: height - titleBarHeight,
            width: width, height: titleBarHeight
        ))
        titleBarView.wantsLayer = true
        titleBarView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        titleBarView.autoresizingMask = [.width, .minYMargin]

        // Close button
        let closeBtn = createCircleButton(
            frame: NSRect(x: 10, y: 7, width: 16, height: 16),
            color: NSColor(red: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
            action: #selector(closeWindow)
        )
        titleBarView.addSubview(closeBtn)

        // Opacity button
        let miniBtn = createCircleButton(
            frame: NSRect(x: 32, y: 7, width: 16, height: 16),
            color: NSColor(red: 1.0, green: 0.82, blue: 0.28, alpha: 1.0),
            action: #selector(toggleOpacity)
        )
        titleBarView.addSubview(miniBtn)

        // Always-on-top indicator
        let pinBtn = createCircleButton(
            frame: NSRect(x: 54, y: 7, width: 16, height: 16),
            color: NSColor(red: 0.27, green: 0.85, blue: 0.46, alpha: 1.0),
            action: nil
        )
        titleBarView.addSubview(pinBtn)

        // Title text
        titleLabel = NSTextField(frame: NSRect(
            x: 78, y: 5,
            width: width - 88, height: 20
        ))
        titleLabel.stringValue = videoTitle
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.autoresizingMask = [.width]
        titleBarView.addSubview(titleLabel)

        // WKWebView (fills entire window, title bar overlays on top)
        let webConfig = WKWebViewConfiguration()
        webConfig.mediaTypesRequiringUserActionForPlayback = []

        let webFrame = NSRect(x: 0, y: 0, width: width, height: height)
        webView = WKWebView(frame: webFrame, configuration: webConfig)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        // Use native Safari User-Agent to avoid JS engine fingerprint mismatch triggering YouTube's "fake browser" bot detection
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"


        container.addSubview(webView)

        // Loading overlay (covers webView during loading)
        let overlay = LoadingOverlayView(frame: webFrame)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.autoresizingMask = [.width, .height]

        let spinnerSize: CGFloat = 36.0
        let spinnerContainer = CALayer()
        spinnerContainer.bounds = CGRect(x: 0, y: 0, width: spinnerSize, height: spinnerSize)
        spinnerContainer.position = CGPoint(x: webFrame.width / 2, y: webFrame.height / 2)

        let arcPath = CGMutablePath()
        arcPath.addArc(
            center: CGPoint(x: spinnerSize / 2, y: spinnerSize / 2),
            radius: spinnerSize / 2 - 2,
            startAngle: 0,
            endAngle: .pi * 1.5,
            clockwise: false
        )
        let arcLayer = CAShapeLayer()
        arcLayer.frame = spinnerContainer.bounds
        arcLayer.path = arcPath
        arcLayer.strokeColor = NSColor(white: 0.5, alpha: 0.8).cgColor
        arcLayer.fillColor = nil
        arcLayer.lineWidth = 2.5
        arcLayer.lineCap = .round
        spinnerContainer.addSublayer(arcLayer)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        spinnerContainer.add(rotation, forKey: "spin")

        overlay.layer?.addSublayer(spinnerContainer)
        overlay.spinnerLayer = spinnerContainer
        container.addSubview(overlay)
        self.loadingOverlay = overlay

        // Title bar (overlays on top of webView and overlay, shown on hover)
        container.addSubview(titleBarView)

        // Bottom control bar (shown on hover, YouTube-style)
        let barH: CGFloat = 44
        controlBarView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barH))
        controlBarView.wantsLayer = true
        controlBarView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        controlBarView.autoresizingMask = [.width, .maxYMargin]
        controlBarView.alphaValue = 0

        // -- Progress bar (top, full-width 4px)
        progressBg = NSView(frame: NSRect(x: 0, y: barH - 4, width: width, height: 4))
        progressBg.wantsLayer = true
        progressBg.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        progressBg.autoresizingMask = [.width]
        controlBarView.addSubview(progressBg)

        progressPlayed = NSView(frame: NSRect(x: 0, y: barH - 4, width: 0, height: 4))
        progressPlayed.wantsLayer = true
        progressPlayed.layer?.backgroundColor = NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0).cgColor
        controlBarView.addSubview(progressPlayed)

        // Progress bar click area (larger hit target)
        let progressHit = ProgressClickView(frame: NSRect(x: 0, y: barH - 12, width: width, height: 12))
        progressHit.autoresizingMask = [.width]
        progressHit.onSeek = { [weak self] percent in self?.seekTo(percent: percent) }
        controlBarView.addSubview(progressHit)

        // -- Control button row (y=0 to barH-4)
        var x: CGFloat = 8

        // Play/Pause
        let ppBtn = makeControlButton(x: x, symbolName: "pause.fill", action: #selector(togglePlayPause))
        self.playPauseButton = ppBtn
        controlBarView.addSubview(ppBtn)
        x += 32

        // Skip 10s
        let skipBtn = makeControlButton(x: x, symbolName: "goforward.10", action: #selector(skipForward))
        self.skipButton = skipBtn
        controlBarView.addSubview(skipBtn)
        x += 32

        // Volume
        let volBtn = makeControlButton(x: x, symbolName: "speaker.wave.2.fill", action: #selector(toggleMute))
        self.volumeButton = volBtn
        controlBarView.addSubview(volBtn)
        x += 28

        // Volume slider
        let slider = NSSlider(frame: NSRect(x: x, y: 10, width: 60, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 1
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        controlBarView.addSubview(slider)
        self.volumeSlider = slider
        x += 64

        // Time label (right-aligned)
        let tLabel = NSTextField(frame: NSRect(x: width - 100, y: 8, width: 92, height: 20))
        tLabel.stringValue = "0:00 / 0:00"
        tLabel.isEditable = false
        tLabel.isBordered = false
        tLabel.drawsBackground = false
        tLabel.textColor = NSColor(white: 0.9, alpha: 1.0)
        tLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tLabel.alignment = .right
        tLabel.lineBreakMode = .byClipping
        tLabel.autoresizingMask = [.minXMargin]
        self.timeLabel = tLabel
        controlBarView.addSubview(tLabel)

        container.addSubview(controlBarView)

        // Hide title bar by default (PiP-style: shown on hover)
        titleBarView.alphaValue = 0

        // Add resize indicator (bottom-right corner)
        let resizeIndicator = NSTextField(frame: NSRect(
            x: width - 20, y: 0, width: 16, height: 16
        ))
        resizeIndicator.stringValue = "⟋"
        resizeIndicator.isEditable = false
        resizeIndicator.isBordered = false
        resizeIndicator.drawsBackground = false
        resizeIndicator.textColor = NSColor(white: 0.5, alpha: 0.6)
        resizeIndicator.font = NSFont.systemFont(ofSize: 12)
        resizeIndicator.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(resizeIndicator)

        self.contentView = container

        // Add tracking area for the entire window (for setting resize cursors)
        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        container.addTrackingArea(trackingArea)
    }

    private func createCircleButton(frame: NSRect, color: NSColor, action: Selector?) -> NSView {
        let btn = NSButton(frame: frame)
        btn.bezelStyle = .circular
        btn.title = ""
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.cgColor
        btn.layer?.cornerRadius = frame.width / 2

        if let action = action {
            btn.target = self
            btn.action = action
        }

        return btn
    }

    // MARK: - Window Positioning

    private func positionWindow() {
        // Try to restore the last saved window position and size
        if let dict = UserDefaults.standard.dictionary(forKey: Self.frameKey),
           let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat,
           let w = dict["w"] as? CGFloat, dict["h"] is CGFloat {
            let restoredW = max(w, self.minSize.width)
            let savedFrame = NSRect(x: x, y: y, width: restoredW, height: restoredW / videoAspectRatio)
            // Ensure the saved position is still on a visible screen
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                self.setFrame(savedFrame, display: false)
                return
            }
        }
        // Default position: bottom-right corner of the screen
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - self.frame.width - 24
        let y = screenFrame.minY + 24
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func saveWindowFrame() {
        let frame = self.frame
        let dict: [String: CGFloat] = [
            "x": frame.origin.x, "y": frame.origin.y,
            "w": frame.size.width, "h": frame.size.height
        ]
        UserDefaults.standard.set(dict, forKey: Self.frameKey)
    }

    // MARK: - Video Loading

    func loadVideo(url: String, videoSrc: String?, embedUrl: String?,
                   currentTime: Double, site: String,
                   httpServerPortProvider: (() -> UInt16)? = nil,
                   cookies: [[String: Any]] = []) {
        // Save parameters for NavigationDelegate use
        self.currentSite = site
        self.currentVideoTime = currentTime
        self.currentPageURL = url
        self.httpServerPortProvider = httpServerPortProvider
        self.hasInjectedJS = false
        self.loadingStrategy = .fullPageInject
        resetYouTubeFallbackState()

        // Suspend all media playback while overlay is visible, prevent audio during loading
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)

        // Priority 1: Direct video source URL
        if let videoSrc = videoSrc, !videoSrc.isEmpty {
            self.loadingStrategy = .directVideo
            let html = buildVideoHTML(videoSrc: videoSrc, currentTime: currentTime)
            webView.loadHTMLString(html, baseURL: URL(string: videoSrc))
            NSLog("[FloatVideo] Loading direct video: \(videoSrc)")
            return
        }

        // Priority 2: YouTube -- prefer watch page + JS injection, keep embed as fallback
        if site == "youtube" {
            refreshYouTubeEmbedFallbackURLIfNeeded()

            if !url.isEmpty, let pageURL = URL(string: url) {
                let loadPage = { [weak self] in
                    self?.loadingStrategy = .fullPageInject
                    self?.webView.load(URLRequest(url: pageURL))
                    NSLog("[FloatVideo] Loading YouTube full page for JS injection: \(url)")
                }

                if !cookies.isEmpty {
                    injectCookies(cookies) {
                        loadPage()
                    }
                } else {
                    loadPage()
                }
                return
            }

            if startYouTubeEmbedFallback(reason: "missing-full-page-url") {
                return
            }
        }

        // Priority 3: Embed URL -- wrap in iframe (non-YouTube sites)
        if let embedUrl = embedUrl, !embedUrl.isEmpty {
            self.loadingStrategy = .siteEmbed
            let html = buildEmbedHTML(embedUrl: embedUrl)
            webView.loadHTMLString(html, baseURL: nil)
            NSLog("[FloatVideo] Loading embed via iframe: \(embedUrl)")
            return
        }

        // Priority 4: Load full page and inject JS
        if !url.isEmpty, let pageURL = URL(string: url) {
            webView.load(URLRequest(url: pageURL))
            NSLog("[FloatVideo] Loading full page: \(url)")
        }
    }

    // MARK: - Cookie Injection

    private func injectCookies(_ cookies: [[String: Any]], completion: @escaping () -> Void) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()

        for cookieData in cookies {
            guard let name = cookieData["name"] as? String,
                  let value = cookieData["value"] as? String else { continue }

            let domain = cookieData["domain"] as? String ?? ".youtube.com"
            let path = cookieData["path"] as? String ?? "/"
            let secure = cookieData["secure"] as? Bool ?? false

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if secure {
                properties[.secure] = "TRUE"
            }

            if let cookie = HTTPCookie(properties: properties) {
                group.enter()
                cookieStore.setCookie(cookie) {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            NSLog("[FloatVideo] All cookies injected")
            completion()
        }
    }

    private func extractYouTubeVideoId(from url: String) -> String? {
        // youtube.com/watch?v=VIDEO_ID
        if let range = url.range(of: "v=") {
            let start = range.upperBound
            let remaining = String(url[start...])
            let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "&# ")).first
            if let id = videoId, !id.isEmpty { return id }
        }
        // youtube.com/shorts/VIDEO_ID
        if let range = url.range(of: "/shorts/") {
            let start = range.upperBound
            let remaining = String(url[start...])
            let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "?&# /")).first
            if let id = videoId, !id.isEmpty { return id }
        }
        return nil
    }

    private func buildYouTubeEmbedFallbackURL(pageURL: String, currentTime: Double,
                                              httpServerPort: UInt16) -> URL? {
        guard httpServerPort > 0,
              let videoId = extractYouTubeVideoId(from: pageURL) else {
            return nil
        }

        let startSeconds = Int(currentTime)
        let safeViewport = youtubeSafeViewportSize()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(httpServerPort)
        components.path = "/play"
        components.queryItems = [
            URLQueryItem(name: "v", value: videoId),
            URLQueryItem(name: "site", value: "youtube"),
            URLQueryItem(name: "t", value: String(startSeconds)),
            URLQueryItem(name: "w", value: String(Int(safeViewport.width))),
            URLQueryItem(name: "h", value: String(Int(safeViewport.height))),
        ]
        return components.url
    }

    private func youtubeSafeViewportSize() -> NSSize {
        let ratio = max(videoAspectRatio, 0.1)
        let minViewport: CGFloat = 200
        let recommendedLongEdge: CGFloat = 480
        let recommendedShortEdge: CGFloat = 270

        if ratio >= 1 {
            let height = max(recommendedShortEdge, recommendedLongEdge / ratio, minViewport)
            let width = max(height * ratio, recommendedLongEdge, minViewport)
            return NSSize(width: ceil(width), height: ceil(height))
        }

        let width = max(recommendedShortEdge, recommendedLongEdge * ratio, minViewport)
        let height = max(width / ratio, recommendedLongEdge, minViewport)
        return NSSize(width: ceil(width), height: ceil(height))
    }

    private func resetYouTubeFallbackState() {
        youtubeFallbackWorkItem?.cancel()
        youtubeFallbackWorkItem = nil
        reinjectLayoutWorkItem?.cancel()
        reinjectLayoutWorkItem = nil
        youtubeEmbedFallbackURL = nil
        hasTriedYouTubeEmbedFallback = false
    }

    /// Builds the embed fallback URL if it couldn't be built earlier. The HTTP
    /// server usually isn't ready yet when loadVideo runs (port still 0), so
    /// callers that need the fallback URL retry here with the live port.
    private func refreshYouTubeEmbedFallbackURLIfNeeded() {
        guard currentSite == "youtube", youtubeEmbedFallbackURL == nil else { return }
        youtubeEmbedFallbackURL = buildYouTubeEmbedFallbackURL(
            pageURL: currentPageURL,
            currentTime: currentVideoTime,
            httpServerPort: httpServerPortProvider?() ?? 0
        )
    }

    private func shouldUseYouTubeFullPagePrimary() -> Bool {
        currentSite == "youtube"
            && loadingStrategy == .fullPageInject
            && youtubeEmbedFallbackURL != nil
    }

    private func scheduleInjectedLayoutRefresh(after delay: TimeInterval = 0.05) {
        guard hasInjectedJS, loadingStrategy == .fullPageInject else { return }
        reinjectLayoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshInjectedLayout()
        }
        reinjectLayoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshInjectedLayout() {
        guard hasInjectedJS, loadingStrategy == .fullPageInject else { return }
        let js = "if (window.__floatVideoApplyLayout) { window.__floatVideoApplyLayout(); true } else { false }"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                NSLog("[FloatVideo] Layout refresh JS error: \(error)")
                return
            }
            if let ok = result as? Bool, !ok {
                self?.injectVideoMaximize(site: self?.currentSite ?? "generic",
                                          currentTime: self?.currentVideoTime ?? 0)
            }
        }
    }

    private func scheduleYouTubeEmbedFallbackCheck(after delay: TimeInterval) {
        guard shouldUseYouTubeFullPagePrimary() else { return }
        youtubeFallbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.shouldUseYouTubeFullPagePrimary(),
                  !self.hasInjectedJS else { return }
            _ = self.startYouTubeEmbedFallback(reason: "inject-timeout")
        }
        youtubeFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @discardableResult
    private func startYouTubeEmbedFallback(reason: String) -> Bool {
        guard !hasTriedYouTubeEmbedFallback,
              let fallbackURL = youtubeEmbedFallbackURL else {
            return false
        }

        hasTriedYouTubeEmbedFallback = true
        youtubeFallbackWorkItem?.cancel()
        youtubeFallbackWorkItem = nil
        loadingStrategy = .youtubeEmbed
        hasInjectedJS = false
        webView.load(URLRequest(url: fallbackURL))
        NSLog("[FloatVideo] Switching YouTube to embed fallback (\(reason)): \(fallbackURL.absoluteString)")
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[FloatVideo] Page loaded (strategy: \(loadingStrategy), site: \(currentSite)), webView: \(webView.frame), container: \(self.contentView?.frame ?? .zero)")

        if loadingStrategy == .fullPageInject {
            // Full page load + JS inject: delay removing overlay after injection to let DOM operations complete
            guard !hasInjectedJS else { return }
            refreshYouTubeEmbedFallbackURLIfNeeded()
            injectVideoMaximize(site: currentSite, currentTime: currentVideoTime)
            // Auto-skip YouTube ads. Idempotent in-page guard (installs a single
            // interval); safe to call alongside the injection retries below.
            // Deliberately NOT gated on shouldUseYouTubeFullPagePrimary(): the
            // guard has no dependency on the embed fallback URL.
            if currentSite == "youtube" {
                injectAdSkip()
            }
            for delay in [1.5, 3.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.hasInjectedJS else { return }
                    self.injectVideoMaximize(site: self.currentSite,
                                             currentTime: self.currentVideoTime)
                }
            }
            if shouldUseYouTubeFullPagePrimary() {
                scheduleYouTubeEmbedFallbackCheck(after: 5.5)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.loadingStrategy == .fullPageInject else { return }
                    self.hideLoadingOverlay()
                }
            }
        } else {
            // Other strategies (direct video, YouTube embed, site embed) have built-in autoplay, remove overlay directly
            hideLoadingOverlay()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[FloatVideo] Page load failed: \(error)")
        refreshYouTubeEmbedFallbackURLIfNeeded()
        if shouldUseYouTubeFullPagePrimary() && startYouTubeEmbedFallback(reason: "didFail") {
            return
        }
        hideLoadingOverlay()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[FloatVideo] Provisional page load failed: \(error)")
        refreshYouTubeEmbedFallbackURLIfNeeded()
        if shouldUseYouTubeFullPagePrimary() && startYouTubeEmbedFallback(reason: "didFailProvisional") {
            return
        }
        hideLoadingOverlay()
    }

    private func buildVideoHTML(videoSrc: String, currentTime: Double) -> String {
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
            video {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                object-fit: cover;
                background: #000;
            }
        </style>
        </head><body>
        <video src="\(videoSrc)" autoplay controls playsinline></video>
        <script>
            const v = document.querySelector('video');
            v.currentTime = \(currentTime);
            v.addEventListener('dblclick', () => {
                if (document.fullscreenElement) {
                    document.exitFullscreen();
                } else {
                    v.requestFullscreen();
                }
            });
        </script>
        </body></html>
        """
    }

    private func buildEmbedHTML(embedUrl: String) -> String {
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
            iframe {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                border: none;
            }
        </style>
        </head><body>
        <iframe src="\(embedUrl)"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                referrerpolicy="strict-origin-when-cross-origin"
                allowfullscreen>
        </iframe>
        </body></html>
        """
    }

    private func injectVideoMaximize(site: String, currentTime: Double) {
        // Thorough JS injection: recursively traverse DOM tree, hide all elements not in the video's ancestor chain
        let js = """
        (function() {
            const site = '\(site)';
            const initialTime = \(currentTime);

            function findMainVideo() {
                const videos = Array.from(document.querySelectorAll('video'));
                if (videos.length === 0) return null;
                if (window.__floatVideoMainVideo && document.contains(window.__floatVideoMainVideo)) {
                    return window.__floatVideoMainVideo;
                }

                let mainVideo = videos[0];
                let maxArea = 0;
                videos.forEach(v => {
                    const rect = v.getBoundingClientRect();
                    const area = rect.width * rect.height;
                    if (area > maxArea) {
                        maxArea = area;
                        mainVideo = v;
                    }
                });
                window.__floatVideoMainVideo = mainVideo;
                return mainVideo;
            }

            function ensureFloatVideoStyle() {
                const styleId = '__floatvideo-style';
                let styleEl = document.getElementById(styleId);
                if (!styleEl) {
                    styleEl = document.createElement('style');
                    styleEl.id = styleId;
                    (document.head || document.documentElement).appendChild(styleEl);
                }

                const youtubeCss = site === 'youtube' ? `
                    ytd-app, ytd-watch-flexy, #page-manager, #content, #columns, #primary,
                    #primary-inner, #player, #player-container, #player-full-bleed-container,
                    #full-bleed-container, #movie_player, .html5-video-player,
                    .html5-video-container {
                        margin: 0 !important;
                        padding: 0 !important;
                        background: #000 !important;
                        transform: none !important;
                        filter: none !important;
                        transition: none !important;
                        overflow: hidden !important;
                    }
                    #secondary, #masthead-container, #below, #related, #chat,
                    .ytp-chrome-top, .ytp-chrome-bottom, .ytp-gradient-top,
                    .ytp-gradient-bottom, .ytp-ce-element, .ytp-pause-overlay,
                    .ytp-cards-teaser, .ytp-paid-content-overlay, [class*="ytp-ce-"] {
                        display: none !important;
                        visibility: hidden !important;
                        opacity: 0 !important;
                    }
                ` : '';

                styleEl.textContent = `
                    html, body {
                        margin: 0 !important;
                        padding: 0 !important;
                        overflow: hidden !important;
                        background: #000 !important;
                        width: 100% !important;
                        height: 100% !important;
                    }
                    .__floatvideo-ancestor {
                        display: block !important;
                        visibility: visible !important;
                        opacity: 1 !important;
                        position: static !important;
                        overflow: visible !important;
                        max-width: none !important;
                        max-height: none !important;
                        width: 100% !important;
                        height: 100% !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        background: #000 !important;
                        transform: none !important;
                        filter: none !important;
                        transition: none !important;
                    }
                    video.__floatvideo-main-video {
                        position: fixed !important;
                        inset: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        left: 0 !important;
                        top: 0 !important;
                        right: auto !important;
                        bottom: auto !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        min-width: 0 !important;
                        min-height: 0 !important;
                        max-width: none !important;
                        max-height: none !important;
                        object-fit: contain !important;
                        object-position: center center !important;
                        transform: none !important;
                        background: #000 !important;
                        z-index: 2147483647 !important;
                    }
                    ${youtubeCss}
                `;
            }

            function hideNonAncestors(element, ancestors, mainVideo) {
                if (!element || !element.children) return;
                Array.from(element.children).forEach(child => {
                    if (child === mainVideo) return;
                    if (ancestors.has(child)) {
                        child.style.setProperty('display', '', 'important');
                        child.style.setProperty('visibility', 'visible', 'important');
                        child.style.setProperty('opacity', '1', 'important');
                        child.style.setProperty('position', 'static', 'important');
                        child.style.setProperty('overflow', 'visible', 'important');
                        child.style.setProperty('max-height', 'none', 'important');
                        child.style.setProperty('max-width', 'none', 'important');
                        child.style.setProperty('width', '100%', 'important');
                        child.style.setProperty('height', '100%', 'important');
                        child.style.setProperty('margin', '0', 'important');
                        child.style.setProperty('padding', '0', 'important');
                        hideNonAncestors(child, ancestors, mainVideo);
                    } else {
                        child.style.setProperty('display', 'none', 'important');
                    }
                });
            }

            function applyLayout() {
                if (window.__floatVideoApplyingLayout) return false;
                const mainVideo = findMainVideo();
                if (!mainVideo) return false;
                window.__floatVideoApplyingLayout = true;

                try {
                    ensureFloatVideoStyle();

                    document.querySelectorAll('.__floatvideo-ancestor').forEach(el => {
                        el.classList.remove('__floatvideo-ancestor');
                    });
                    document.querySelectorAll('.__floatvideo-main-video').forEach(el => {
                        el.classList.remove('__floatvideo-main-video');
                    });

                    const ancestors = new Set();
                    let current = mainVideo;
                    while (current) {
                        ancestors.add(current);
                        if (current.classList) {
                            current.classList.add('__floatvideo-ancestor');
                        }
                        current = current.parentElement;
                    }

                    document.documentElement.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';
                    document.body.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';

                    hideNonAncestors(document.body, ancestors, mainVideo);

                    if (site === 'youtube') {
                        ancestors.forEach(el => {
                            if (el !== mainVideo) {
                                el.style.setProperty('transform', 'none', 'important');
                                el.style.setProperty('filter', 'none', 'important');
                                el.style.setProperty('transition', 'none', 'important');
                                el.style.setProperty('background', '#000', 'important');
                            }
                        });
                    }

                    mainVideo.classList.add('__floatvideo-main-video');
                    mainVideo.style.setProperty('position', 'fixed', 'important');
                    mainVideo.style.setProperty('inset', '0', 'important');
                    mainVideo.style.setProperty('width', '100vw', 'important');
                    mainVideo.style.setProperty('height', '100vh', 'important');
                    mainVideo.style.setProperty('left', '0', 'important');
                    mainVideo.style.setProperty('top', '0', 'important');
                    mainVideo.style.setProperty('object-fit', 'contain', 'important');
                    mainVideo.style.setProperty('object-position', 'center center', 'important');
                    mainVideo.style.setProperty('transform', 'none', 'important');
                    mainVideo.style.setProperty('margin', '0', 'important');
                    mainVideo.style.setProperty('padding', '0', 'important');
                    mainVideo.style.setProperty('background', '#000', 'important');
                    mainVideo.setAttribute('playsinline', '');

                    if (!window.__floatVideoInitialSeekDone && initialTime > 0) {
                        try {
                            mainVideo.currentTime = initialTime;
                        } catch (e) {}
                        window.__floatVideoInitialSeekDone = true;
                    }

                    mainVideo.play().catch(() => {});
                    mainVideo.controls = site === 'youtube' ? false : true;
                    window.__floatVideoMainVideo = mainVideo;
                    return true;
                } finally {
                    window.__floatVideoApplyingLayout = false;
                }
            }

            window.__floatVideoApplyLayout = applyLayout;

            if (!window.__floatVideoResizeHookInstalled) {
                window.__floatVideoResizeHookInstalled = true;
                let delayedLayoutPass = null;
                window.addEventListener('resize', () => {
                    if (delayedLayoutPass) {
                        clearTimeout(delayedLayoutPass);
                    }
                    delayedLayoutPass = setTimeout(() => {
                        if (window.__floatVideoApplyLayout) {
                            window.__floatVideoApplyLayout();
                        }
                    }, 0);
                    setTimeout(() => {
                        if (window.__floatVideoApplyLayout) {
                            window.__floatVideoApplyLayout();
                        }
                    }, 120);
                });
            }

            return applyLayout();
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, err in
            if let err = err {
                NSLog("[FloatVideo] JS injection error: \(err)")
            } else if let found = result as? Bool, found {
                self?.hasInjectedJS = true
                self?.youtubeFallbackWorkItem?.cancel()
                self?.youtubeFallbackWorkItem = nil
                if self?.shouldUseYouTubeFullPagePrimary() == true {
                    self?.hideLoadingOverlay()
                }
            }
        }
    }

    /// Installs a self-contained, idempotent in-page guard that auto-clicks
    /// YouTube's "Skip Ad" button the instant it becomes available.
    ///
    /// Why this is needed: the full-page isolation injection (`injectVideoMaximize`)
    /// hides every element that isn't an ancestor of the <video>, which includes
    /// YouTube's ad container and the Skip button it creates ~15s into an ad. The
    /// button still exists in the DOM, so `HTMLElement.click()` fires its handler
    /// even while it is `display:none` — no CSS/z-index/layout changes required.
    ///
    /// Limitation: this only reaches the same-origin YouTube watch page loaded via
    /// the `.fullPageInject` primary path. The cross-origin IFrame-API fallback
    /// (LocalHTTPServer) hosts YouTube in an <iframe> whose ad DOM is unreachable,
    /// so auto-skip does not apply there.
    private func injectAdSkip() {
        let js = """
        (function() {
            if (window.__floatVideoAdSkipInstalled) return 'already';
            window.__floatVideoAdSkipInstalled = true;
            window.__floatVideoAdSkipCount = window.__floatVideoAdSkipCount || 0;
            window.__floatVideoAdFFCount = window.__floatVideoAdFFCount || 0;

            // Covers old + modern YouTube ad-skip markup.
            var SKIP_SELECTORS = [
                '.ytp-ad-skip-button-modern',
                '.ytp-ad-skip-button',
                '.ytp-skip-ad-button',
                '.ytp-ad-skip-button-slot button',
                '.ytp-ad-skip-button-container button'
            ];

            function findSkipButton() {
                for (var i = 0; i < SKIP_SELECTORS.length; i++) {
                    var el = document.querySelector(SKIP_SELECTORS[i]);
                    if (!el) continue;
                    // Only click a genuinely enabled skip control. YouTube only
                    // inserts the real button once skipping is allowed, but guard
                    // against disabled/aria-disabled states just in case.
                    if (el.disabled) continue;
                    if (el.getAttribute('aria-disabled') === 'true') continue;
                    return el;
                }
                return null;
            }

            // Per-ad-break state machine. Clicking Skip too early (before a real
            // user ever could, ~5s) makes YouTube's ad server treat the ad as
            // improperly delivered and RE-SERVE it — observed as the same break
            // looping 6-7 ads of 1-2s each. Strategy: instance 1 in a break keeps
            // the instant skip (most ads tolerate it); each detected re-serve
            // backs the next click off progressively past human timing.
            var lastAdT = 0;          // ad video currentTime last tick
            var instanceCount = 0;    // ad instances in the current logical break
            var clicks = 0;           // clicks for the current instance (max 3)
            var lastClickAt = 0;
            var ffDone = false;
            var coolOffUntil = 0;     // break-level circuit breaker
            var lastCoolInstance = 0; // instance that last triggered a cool-off
            var adGoneTicks = 0;      // consecutive ticks with no ad showing

            function resetInstance() {
                clicks = 0;
                lastClickAt = 0;
                ffDone = false;
            }

            window.__floatVideoAdSkipTimer = setInterval(function() {
                var player = document.querySelector('#movie_player, .html5-video-player');
                var adShowing = !!(player && (player.classList.contains('ad-showing') ||
                                              player.classList.contains('ad-interrupting')));
                if (!adShowing) {
                    // Between re-serves YouTube drops out of ad state for a few
                    // hundred ms (observed in logs), so only treat the break as
                    // over after 3s without an ad. Real content stretches are
                    // minutes long; a re-serve gap never is.
                    if (++adGoneTicks >= 6 && instanceCount > 0) {
                        instanceCount = 0;
                        lastAdT = 0;
                        coolOffUntil = 0;
                        lastCoolInstance = 0;
                        resetInstance();
                    }
                    return;
                }
                var gapTicks = adGoneTicks;
                adGoneTicks = 0;

                var v = player.querySelector('video') || document.querySelector('video');
                if (!v) return;

                // New ad instance: break just started, ad state came back after
                // a short gap (re-serve), or the ad video's clock jumped
                // backwards (pod advance within continuous ad state).
                if (instanceCount === 0 || gapTicks > 0 || v.currentTime < lastAdT - 1.0) {
                    instanceCount++;
                    resetInstance();
                }
                lastAdT = v.currentTime;

                var now = Date.now();
                if (now < coolOffUntil) return;
                if (instanceCount >= 5 && instanceCount > lastCoolInstance) {
                    // Pathological re-serve loop: pause once per new instance and
                    // let the ad play legitimately for a while before retrying,
                    // instead of locking out (or hammering) for the whole break.
                    lastCoolInstance = instanceCount;
                    coolOffUntil = now + 20000;
                    return;
                }

                // Instance 1: click immediately. Re-served instances: wait 5.2s,
                // 9.2s, 13.2s into the ad — walks past longer skip-offsets
                // (e.g. 15s campaigns) instead of re-triggering the loop.
                var minAdTime = (instanceCount === 1)
                    ? 0
                    : Math.min(5.2 + 4.0 * (instanceCount - 2), 30);
                if (v.currentTime < minAdTime) return;

                var btn = findSkipButton();
                if (!btn) return; // unskippable or button not yet inserted

                if (clicks < 3) {
                    if (now - lastClickAt < 2000) return;
                    btn.click();
                    lastClickAt = now;
                    if (++clicks === 1) window.__floatVideoAdSkipCount++;
                } else if (!ffDone && now - lastClickAt >= 2000) {
                    // 3 clicks ignored (e.g. trusted-event enforcement). Only for
                    // SKIPPABLE ads (button present): end the ad stream directly.
                    // Main content is never touched (adShowing gate).
                    if (isFinite(v.duration) && v.duration > 0) {
                        v.currentTime = v.duration;
                        window.__floatVideoAdFFCount++;
                        ffDone = true;
                    }
                }
            }, 500);

            return 'installed';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, err in
            if let err = err {
                NSLog("[FloatVideo] Ad-skip guard injection error: \(err)")
            } else {
                self?.hasInjectedAdSkip = true
                // Only log fresh installs; the poll-driven self-heal re-invokes
                // this until the flag is visible, which would otherwise spam.
                if (result as? String) == "installed" {
                    NSLog("[FloatVideo] Ad-skip guard installed")
                }
            }
        }
    }

    // MARK: - Window Actions

    func show() {
        // Show title bar during loading (user can see title and close button)
        titleBarView.alphaValue = 1.0
        self.orderFrontRegardless()
        self.makeKeyAndOrderFront(nil)
        // Start cursor-position polling for reliable auto-hide (event-based
        // approaches fail on non-activating panels and under WKWebView).
        startCursorPolling()
        // Safety: hide loading overlay after 8s regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.hideLoadingOverlay()
        }
    }

    private func startCursorPolling() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollCursorPosition()
        }
    }

    private func pollCursorPosition() {
        let cursor = NSEvent.mouseLocation
        let inside = self.frame.contains(cursor)

        if isResizing {
            // Keep controls visible during resize; no hide scheduling.
            if !isHovering { showControls() }
            hideTimer?.cancel()
            hideTimer = nil
            cursorWasInside = inside
            return
        }

        if inside && !cursorWasInside {
            cursorWasInside = true
            hideTimer?.cancel()
            hideTimer = nil
            if !isHovering { showControls() }
        } else if !inside && cursorWasInside {
            cursorWasInside = false
            if isHovering { scheduleHideControls() }
        }
    }

    private func hideLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }
        // Resume media playback and trigger autoplay
        webView.setAllMediaPlaybackSuspended(false) { [weak self] in
            self?.triggerPlayback()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            overlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.loadingOverlay?.removeFromSuperview()
            self?.loadingOverlay = nil
            self?.startUpdateTimer()
            // After loading completes, hide title bar if mouse is not inside the window
            if !(self?.isHovering ?? false) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    self?.titleBarView.animator().alphaValue = 0
                })
            }
        })
    }

    private func triggerPlayback() {
        // Trigger playback for all video elements + trigger YouTube iframe playback via postMessage.
        // Also assert the user's mute intent — WKWebView's autoplay policy will often force
        // audio off without an explicit unmute, and YouTube re-mutes around ad transitions.
        let wantMute = userWantsMute
        let mutedJSBool = wantMute ? "true" : "false"
        let ytMuteCmd = wantMute ? "'mute'" : "'unmute'"
        let js = """
        document.querySelectorAll('video').forEach(v => {
            v.muted = \(mutedJSBool);
            if (!\(mutedJSBool)) v.volume = 1.0;
            v.play().catch(() => {});
        });
        if (window.playerCommand) {
            window.playerCommand(\(ytMuteCmd));
            if (!\(mutedJSBool)) window.playerCommand('volume', 1.0);
            window.playerCommand('play');
        }
        var iframe = document.querySelector('iframe');
        if (iframe) {
            iframe.contentWindow.postMessage(JSON.stringify({event:'command',func:'playVideo',args:[]}), '*');
        }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        // Delayed retry (YouTube iframe may not be ready yet)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc func closeWindow() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
        resetYouTubeFallbackState()
        reinjectLayoutWorkItem?.cancel()
        reinjectLayoutWorkItem = nil
        stopUpdateTimer()
        saveWindowFrame()
        onClose?()
        self.close()
    }

    // MARK: - Hover Controls

    private func showControls() {
        hideTimer?.cancel()
        guard !isHovering else { return }
        isHovering = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            titleBarView.animator().alphaValue = 1.0
            controlBarView.animator().alphaValue = 1.0
        })
    }

    private func scheduleHideControls() {
        hideTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideControls()
        }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func hideControls() {
        guard isHovering else { return }
        if isResizing {
            // Can't hide during resize; reschedule so controls hide once resize ends
            scheduleHideControls()
            return
        }
        isHovering = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            titleBarView.animator().alphaValue = 0
            controlBarView.animator().alphaValue = 0
        })
    }

    private func makeControlButton(x: CGFloat, symbolName: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: 6, width: 28, height: 28))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
            btn.imagePosition = .imageOnly
        } else {
            btn.title = symbolName
            btn.font = NSFont.systemFont(ofSize: 14)
        }
        return btn
    }

    private func setButtonSymbol(_ btn: NSButton, _ symbolName: String) {
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
        } else {
            btn.title = symbolName
        }
    }

    private func videoJS(_ directJS: String, youtubeCmd: String? = nil) {
        var js = "var v = document.querySelector('video'); if(v) { \(directJS) }"
        if let cmd = youtubeCmd {
            js += " else if(window.playerCommand) { \(cmd) }"
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func togglePlayPause() {
        if isPlaying {
            videoJS("v.pause()", youtubeCmd: "playerCommand('pause')")
        } else {
            videoJS("v.play().catch(()=>{})", youtubeCmd: "playerCommand('play')")
        }
        isPlaying.toggle()
        setButtonSymbol(playPauseButton, isPlaying ? "pause.fill" : "play.fill")
    }

    @objc func skipForward() {
        videoJS("v.currentTime += 10",
                youtubeCmd: "playerCommand('seek', (window.getPlayerState()?.ct||0)+10)")
    }

    @objc func toggleMute() {
        userWantsMute.toggle()
        if userWantsMute {
            videoJS("v.muted = true", youtubeCmd: "playerCommand('mute')")
            setButtonSymbol(volumeButton, "speaker.slash.fill")
            volumeSlider.doubleValue = 0
        } else {
            videoJS("v.muted = false; v.volume = 1.0",
                    youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)")
            setButtonSymbol(volumeButton, "speaker.wave.2.fill")
            volumeSlider.doubleValue = 1.0
        }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        let vol = sender.doubleValue
        let muted = vol == 0
        videoJS("v.volume = \(vol); v.muted = \(muted)",
                youtubeCmd: "playerCommand('volume', \(vol)); playerCommand(\(muted ? "'mute'" : "'unmute'"))")
        userWantsMute = muted
        setButtonSymbol(volumeButton, userWantsMute ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    private func seekTo(percent: Double) {
        let js = """
        var v = document.querySelector('video');
        if (v && v.duration) { v.currentTime = v.duration * \(percent); }
        else if (window.getPlayerState && window.playerCommand) {
            var s = window.getPlayerState();
            if (s) playerCommand('seek', s.dur * \(percent));
        }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Control Bar State Polling

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Always run: polling drives audio-intent reconciliation, not just UI.
            // Skipping while controls are hidden would leave the page muted when
            // YouTube re-mutes during ad transitions and the cursor isn't inside.
            self.pollVideoState()
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func pollVideoState() {
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (v) return { ct: v.currentTime, dur: v.duration, vol: v.volume, muted: v.muted, paused: v.paused,
                            skips: window.__floatVideoAdSkipCount || 0,
                            ff: window.__floatVideoAdFFCount || 0,
                            adSkipInstalled: !!window.__floatVideoAdSkipInstalled };
            if (window.getPlayerState) return window.getPlayerState();
            return null;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let dict = result as? [String: Any] else { return }
            let ct = dict["ct"] as? Double ?? 0
            let dur = dict["dur"] as? Double ?? 0
            let vol = dict["vol"] as? Double ?? 1
            let muted = dict["muted"] as? Bool ?? false
            let paused = dict["paused"] as? Bool ?? true

            // Diagnostics: log whenever the in-page ad-skip guard has clicked Skip
            // since the last poll (the guard runs in-page, so surface it natively).
            let skips = (dict["skips"] as? NSNumber)?.intValue ?? 0
            if skips > self.lastAdSkipCount {
                NSLog("[FloatVideo] Auto-skipped ad (total \(skips))")
                self.lastAdSkipCount = skips
            }
            let ff = (dict["ff"] as? NSNumber)?.intValue ?? 0
            if ff > self.lastAdFFCount {
                NSLog("[FloatVideo] Fast-forwarded stuck ad (total \(ff))")
                self.lastAdFFCount = ff
            }

            // Self-healing: a full in-page navigation (autoplay-next, reload)
            // wipes the JS world while Swift-side state blocks re-injection in
            // didFinish. Re-install the ad-skip guard whenever the page reports
            // it missing. Same philosophy as the mute-intent reconciliation below.
            let adSkipInstalled = dict["adSkipInstalled"] as? Bool ?? true
            if !adSkipInstalled, self.currentSite == "youtube",
               self.loadingStrategy == .fullPageInject {
                self.injectAdSkip()
            }

            // Update progress bar
            if dur > 0 {
                let fraction = CGFloat(ct / dur)
                self.progressPlayed.frame.size.width = self.progressBg.frame.width * fraction
            }
            // Update time label
            self.timeLabel.stringValue = "\(self.formatTime(ct)) / \(self.formatTime(dur))"
            // Sync play state (observed)
            self.isPlaying = !paused
            self.setButtonSymbol(self.playPauseButton, paused ? "play.fill" : "pause.fill")

            // Mute/volume: UI reflects user INTENT, not the observed state.
            // If observed drifts from intent (YouTube re-mutes after an ad, audio
            // session interruption, etc.) re-assert intent on the page. Self-healing.
            let desiredMuted = self.userWantsMute
            self.setButtonSymbol(self.volumeButton, desiredMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            if desiredMuted {
                self.volumeSlider.doubleValue = 0
                if !muted {
                    self.videoJS("v.muted = true", youtubeCmd: "playerCommand('mute')")
                }
            } else {
                // Keep the slider visually pinned away from 0 while the user wants audio
                self.volumeSlider.doubleValue = max(vol, 0.01)
                if muted || vol == 0 {
                    self.videoJS("v.muted = false; v.volume = 1.0",
                                 youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)")
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    @objc func toggleOpacity() {
        if self.alphaValue < 1.0 {
            self.alphaValue = 1.0
        } else {
            self.alphaValue = 0.6
        }
    }

    // MARK: - Resize Edge Detection

    private func detectResizeEdge(at point: NSPoint) -> ResizeEdge {
        let w = self.frame.width
        let h = self.frame.height
        let b = resizeBorderWidth

        let onLeft = point.x < b
        let onRight = point.x > w - b
        let onBottom = point.y < b
        let onTop = point.y > h - b

        if onTop && onLeft { return .topLeft }
        if onTop && onRight { return .topRight }
        if onBottom && onLeft { return .bottomLeft }
        if onBottom && onRight { return .bottomRight }
        if onLeft { return .left }
        if onRight { return .right }
        if onBottom { return .bottom }
        if onTop { return .top }
        return .none
    }

    private func cursorForEdge(_ edge: ResizeEdge) -> NSCursor {
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return .crosshair
        case .topRight, .bottomLeft: return .crosshair
        case .none: return .arrow
        }
    }

    // MARK: - Event Interception (intercept resize events before WKWebView)

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let location = event.locationInWindow
            let edge = detectResizeEdge(at: location)
            if edge != .none {
                // When title bar is visible, drag takes priority over top-edge resize
                if titleBarView.alphaValue > 0,
                   titleBarView.frame.contains(location) {
                    break // Let DraggableTitleBar handle the drag
                }
                isResizing = true
                resizeEdge = edge
                initialMouseLocation = NSEvent.mouseLocation
                initialWindowFrame = self.frame
                return
            }
        case .leftMouseDragged:
            if isResizing {
                mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if isResizing {
                mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    // MARK: - Mouse Handling

    override func mouseMoved(with event: NSEvent) {
        // Show/hide driven by cursor polling; only update resize cursor here.
        let location = event.locationInWindow
        let edge = detectResizeEdge(at: location)
        cursorForEdge(edge).set()
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Resize handled by sendEvent interception, title bar drag handled by DraggableTitleBar
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouseLocation.x
        let deltaY = currentMouse.y - initialMouseLocation.y
        var newFrame = initialWindowFrame

        // First calculate new width based on edge
        switch resizeEdge {
        case .right, .topRight, .bottomRight:
            newFrame.size.width += deltaX
        case .left, .topLeft, .bottomLeft:
            newFrame.size.width -= deltaX
        case .top, .bottom:
            // Vertical drag: derive width from height
            let dh = (resizeEdge == .top) ? deltaY : -deltaY
            newFrame.size.height = initialWindowFrame.height + dh
            newFrame.size.width = newFrame.size.height * videoAspectRatio
        case .none:
            break
        }

        // Horizontal/diagonal drag: derive height from width, maintain aspect ratio
        if resizeEdge != .top && resizeEdge != .bottom && resizeEdge != .none {
            newFrame.size.height = newFrame.size.width / videoAspectRatio
        }

        // Enforce minimum size
        let minW = self.minSize.width
        if newFrame.size.width < minW {
            newFrame.size.width = minW
            newFrame.size.height = minW / videoAspectRatio
        }

        // Anchor to opposite edge
        switch resizeEdge {
        case .left, .bottomLeft, .topLeft:
            newFrame.origin.x = initialWindowFrame.maxX - newFrame.size.width
        default: break
        }
        switch resizeEdge {
        case .bottom, .bottomLeft, .bottomRight:
            newFrame.origin.y = initialWindowFrame.maxY - newFrame.size.height
        default: break
        }

        self.setFrame(newFrame, display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            saveWindowFrame()
        }
        isResizing = false
        resizeEdge = .none
        NSCursor.arrow.set()
        super.mouseUp(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing {
            NSCursor.arrow.set()
        }
        super.mouseExited(with: event)
    }

    // Allow window to become key window + respond to first click
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsMouseMovedEvents: Bool {
        get { true }
        set { super.acceptsMouseMovedEvents = newValue }
    }

    // ESC closes the window
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            closeWindow()
        } else {
            super.keyDown(with: event)
        }
    }
}

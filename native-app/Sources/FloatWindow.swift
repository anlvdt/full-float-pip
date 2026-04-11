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
    private var isMuted = false
    private var videoAspectRatio: CGFloat = 16.0 / 9.0

    // Video loading parameters (used by WKNavigationDelegate callbacks)
    private var currentSite: String = "generic"
    private var currentVideoTime: Double = 0
    private var hasInjectedJS = false
    private var loadingOverlay: NSView?

    private enum LoadingStrategy {
        case directVideo, youtubeEmbed, siteEmbed, fullPageInject
    }
    private var loadingStrategy: LoadingStrategy = .fullPageInject

    private static let frameKey = "FloatVideoWindowFrame"

    var onClose: (() -> Void)?

    // For hover show/hide control bar
    private var isHovering = false
    private var hideTimer: DispatchWorkItem?

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
                   httpServerPort: UInt16 = 0,
                   cookies: [[String: Any]] = []) {
        // Save parameters for NavigationDelegate use
        self.currentSite = site
        self.currentVideoTime = currentTime
        self.hasInjectedJS = false
        self.loadingStrategy = .fullPageInject

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

        // Priority 2: YouTube -- load via local HTTP server (provides valid Referer)
        if site == "youtube" && httpServerPort > 0 {
            if let videoId = extractYouTubeVideoId(from: url) {
                self.loadingStrategy = .youtubeEmbed
                let startSeconds = Int(currentTime)
                let localURL = "http://127.0.0.1:\(httpServerPort)/play?v=\(videoId)&site=youtube&t=\(startSeconds)"
                guard let serverURL = URL(string: localURL) else { return }

                // Inject cookies first, then load
                if !cookies.isEmpty {
                    injectCookies(cookies) { [weak self] in
                        self?.webView.load(URLRequest(url: serverURL))
                        NSLog("[FloatVideo] Loading YouTube via local HTTP (with \(cookies.count) cookies): \(localURL)")
                    }
                } else {
                    webView.load(URLRequest(url: serverURL))
                    NSLog("[FloatVideo] Loading YouTube via local HTTP (no cookies): \(localURL)")
                }
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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[FloatVideo] Page loaded (strategy: \(loadingStrategy), site: \(currentSite)), webView: \(webView.frame), container: \(self.contentView?.frame ?? .zero)")

        if loadingStrategy == .fullPageInject {
            // Full page load + JS inject: delay removing overlay after injection to let DOM operations complete
            guard !hasInjectedJS else { return }
            injectVideoMaximize(site: currentSite, currentTime: currentVideoTime)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.hideLoadingOverlay()
            }
            for delay in [1.5, 3.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.hasInjectedJS else { return }
                    self.injectVideoMaximize(site: self.currentSite,
                                             currentTime: self.currentVideoTime)
                }
            }
        } else {
            // Other strategies (direct video, YouTube embed, site embed) have built-in autoplay, remove overlay directly
            hideLoadingOverlay()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[FloatVideo] Page load failed: \(error)")
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
            const videos = document.querySelectorAll('video');
            if (videos.length === 0) return false;

            // Find the largest video element
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

            // Build ancestor chain set for the video
            const ancestors = new Set();
            let current = mainVideo;
            while (current) {
                ancestors.add(current);
                current = current.parentElement;
            }

            // Recursively hide all elements not in the ancestor chain
            function hideNonAncestors(element) {
                if (!element || !element.children) return;
                Array.from(element.children).forEach(child => {
                    if (child === mainVideo) return;
                    if (ancestors.has(child)) {
                        // This child is in the ancestor chain, keep visible but continue traversing down
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
                        hideNonAncestors(child);
                    } else {
                        // Not in the ancestor chain, hide it
                        child.style.setProperty('display', 'none', 'important');
                    }
                });
            }

            document.documentElement.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';
            document.body.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';

            hideNonAncestors(document.body);

            // Make the video element fullscreen
            mainVideo.style.cssText = 'position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;object-fit:contain!important;z-index:2147483647!important;background:#000!important;max-width:none!important;max-height:none!important;';

            // Remove all overlays and modals
            document.querySelectorAll('[class*="overlay"], [class*="modal"], [class*="popup"], [id*="overlay"]').forEach(el => {
                if (!ancestors.has(el)) {
                    el.style.setProperty('display', 'none', 'important');
                }
            });

            // Play
            if (\(currentTime) > 0) {
                mainVideo.currentTime = \(currentTime);
            }
            mainVideo.play().catch(() => {});
            mainVideo.controls = true;
            return true;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, err in
            if let err = err {
                NSLog("[FloatVideo] JS injection error: \(err)")
            } else if let found = result as? Bool, found {
                self?.hasInjectedJS = true
            }
        }
    }

    // MARK: - Window Actions

    func show() {
        // Show title bar during loading (user can see title and close button)
        titleBarView.alphaValue = 1.0
        self.orderFrontRegardless()
        self.makeKeyAndOrderFront(nil)
        // Safety: hide loading overlay after 8s regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.hideLoadingOverlay()
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
        // Trigger playback for all video elements + trigger YouTube iframe playback via postMessage
        let js = """
        document.querySelectorAll('video').forEach(v => v.play().catch(() => {}));
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
        guard isHovering, !isResizing else { return }
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
        isMuted.toggle()
        if isMuted {
            videoJS("v.muted = true", youtubeCmd: "playerCommand('mute')")
            setButtonSymbol(volumeButton, "speaker.slash.fill")
        } else {
            videoJS("v.muted = false", youtubeCmd: "playerCommand('unmute')")
            setButtonSymbol(volumeButton, "speaker.wave.2.fill")
        }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        let vol = sender.doubleValue
        videoJS("v.volume = \(vol)", youtubeCmd: "playerCommand('volume', \(vol))")
        isMuted = vol == 0
        setButtonSymbol(volumeButton, isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
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
            guard let self = self, self.controlBarView.alphaValue > 0 else { return }
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
            if (v) return { ct: v.currentTime, dur: v.duration, vol: v.volume, muted: v.muted, paused: v.paused };
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

            // Update progress bar
            if dur > 0 {
                let fraction = CGFloat(ct / dur)
                self.progressPlayed.frame.size.width = self.progressBg.frame.width * fraction
            }
            // Update time label
            self.timeLabel.stringValue = "\(self.formatTime(ct)) / \(self.formatTime(dur))"
            // Sync play state
            self.isPlaying = !paused
            self.setButtonSymbol(self.playPauseButton, paused ? "play.fill" : "pause.fill")
            // Sync volume
            self.isMuted = muted
            self.setButtonSymbol(self.volumeButton, muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            if !muted { self.volumeSlider.doubleValue = vol }
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

    override func mouseEntered(with event: NSEvent) {
        showControls()
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        showControls()
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
        scheduleHideControls()
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

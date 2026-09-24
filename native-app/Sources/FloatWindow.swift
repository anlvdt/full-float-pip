import Cocoa
import WebKit
import QuartzCore
import Vision
import Speech
import AVFoundation

// MARK: - LoadingOverlayView — Loading overlay (auto-centered spinner)

private final class PlaybackToast: NSView {
    let iconView = NSImageView()
    let textField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.82).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.borderWidth = 0.6
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = NSColor(white: 1, alpha: 0.92)
        addSubview(iconView)

        textField.isEditable = false
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.textColor = .white
        textField.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        textField.maximumNumberOfLines = 4
        textField.lineBreakMode = .byWordWrapping
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        textField.alignment = .left
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(_ message: String, symbol: String, maxWidth: CGFloat) {
        textField.stringValue = message
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            iconView.image = image
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
        }
        let font = textField.font ?? NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let iconSide: CGFloat = iconView.isHidden ? 0 : 14
        let gap: CGFloat = iconView.isHidden ? 0 : 7
        let textMax = max(96, maxWidth - 28 - iconSide - gap)
        let measured = (message as NSString).boundingRect(
            with: NSSize(width: textMax, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let textW = min(textMax, ceil(measured.width) + 4)
        let textH = ceil(measured.height) + 4
        let height = max(32, textH + 14)
        let width = min(maxWidth, textW + 24 + iconSide + gap)
        iconView.frame = NSRect(x: 12, y: (height - iconSide) / 2, width: iconSide, height: iconSide)
        textField.frame = NSRect(x: 12 + iconSide + gap, y: (height - textH) / 2, width: textW, height: textH)
        frame.size = NSSize(width: width, height: height)
        layer?.cornerRadius = min(16, height / 2)
    }
}

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

private final class ControlBarView: NSView {
    static let edgeWidth: CGFloat = 10

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
        for sub in subviews where !sub.isHidden && sub.alphaValue > 0.01 {
            let tip = sub.toolTip ?? ""
            if sub is NSControl || sub is ModernScrubberView || !tip.isEmpty {
                addCursorRect(sub.frame, cursor: .pointingHand)
            }
        }
        let b = Self.edgeWidth
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - b, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
    }
}

/// Transparent border above the video so the resize cursor shows on the edges
/// even while another app is frontmost. The center passes hits through.
private final class ResizeEdgeView: NSView {
    var border: CGFloat = 16

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return isEdge(local) ? self : nil
    }

    override func resetCursorRects() {
        let b = border
        let w = bounds.width
        let h = bounds.height
        guard w > b * 2, h > b * 2 else { return }
        addCursorRect(NSRect(x: 0, y: b, width: b, height: h - b * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - b, y: b, width: b, height: h - b * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b, y: 0, width: w - b * 2, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: b, y: h - b, width: w - b * 2, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: b), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - b, y: 0, width: b, height: b), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: h - b, width: b, height: b), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - b, y: h - b, width: b, height: b), cursor: .resizeLeftRight)
    }

    private func isEdge(_ local: NSPoint) -> Bool {
        let b = border
        return local.x < b || local.x > bounds.width - b || local.y < b || local.y > bounds.height - b
    }
}

private final class ControlStripPanel: NSPanel {
    weak var owner: FloatWindow?
    static let resizeEdgeWidth: CGFloat = ControlBarView.edgeWidth

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Intercept edge presses before subviews so L/R resize stays solid.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let point = event.locationInWindow
            let width = contentView?.bounds.width ?? frame.width
            let edge = Self.resizeEdgeWidth
            if point.x < edge || point.x > width - edge {
                owner?.noteStripInteraction()
                owner?.trackResizeFromStrip()
                return
            }
        }
        super.sendEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner = owner else {
            super.mouseDown(with: event)
            return
        }
        owner.noteStripInteraction()
        let point = event.locationInWindow
        let width = contentView?.bounds.width ?? frame.width
        let edge = Self.resizeEdgeWidth
        // Pin only blocks auto-dock — manual edge resize must always work.
        if point.x < edge || point.x > width - edge {
            owner.trackResizeFromStrip()
            return
        }
        if hitIsControl(point) {
            super.mouseDown(with: event)
            return
        }
        owner.trackMoveFromStrip()
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.noteStripInteraction()
        let point = event.locationInWindow
        let width = contentView?.bounds.width ?? frame.width
        let edge = Self.resizeEdgeWidth
        if point.x < edge || point.x > width - edge {
            NSCursor.resizeLeftRight.set()
        } else {
            owner?.updateStripPointerFeedback()
            super.mouseMoved(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.noteStripInteraction()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        // Defer hide to FloatWindow's idle timer — never thrash on strip exit.
        owner?.noteStripPointerExited()
        super.mouseExited(with: event)
    }

    private func hitIsControl(_ point: NSPoint) -> Bool {
        // Edge grips win over buttons so resize stays discoverable.
        let width = contentView?.bounds.width ?? frame.width
        let edge = Self.resizeEdgeWidth
        if point.x < edge || point.x > width - edge { return false }
        guard let hit = contentView?.hitTest(point) else { return false }
        var view: NSView? = hit
        while let current = view, current !== contentView {
            if current is NSControl || current is ModernScrubberView { return true }
            view = current.superview
        }
        return false
    }
}

private class DraggableTitleBar: NSView {
    var isLocked = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isHidden || alphaValue < 0.05 { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let float = window as? FloatWindow
        if isLocked || float?.isPinned == true { return }
        float?.autoDockPaused = true
        window?.performDrag(with: event)
        float?.autoDockPaused = false
        float?.vibeDock.noteUserDidPlace()
    }
}

// MARK: - ModernScrubberView — Apple-grade video timeline scrubber bar

private class ModernScrubberView: NSView {
    var onSeek: ((Double) -> Void)?
    var isDragging = false

    private let trackBg = NSView()
    private let trackProgress = NSView()
    private let knobView = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    private let normalTrackHeight: CGFloat = 5.0
    private let hoverTrackHeight: CGFloat = 7.0
    private let normalKnobSize: CGFloat = 13.0
    private let hoverKnobSize: CGFloat = 16.0

    private var currentProgress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        // Background track (subtle translucent gray)
        trackBg.wantsLayer = true
        trackBg.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.22).cgColor
        trackBg.layer?.cornerRadius = normalTrackHeight / 2
        addSubview(trackBg)

        // Played track (vivid red accent)
        trackProgress.wantsLayer = true
        trackProgress.layer?.backgroundColor = NSColor(red: 1.0, green: 0.23, blue: 0.36, alpha: 1.0).cgColor
        trackProgress.layer?.cornerRadius = normalTrackHeight / 2
        addSubview(trackProgress)

        // Scrubber Knob (white circle with drop shadow)
        knobView.wantsLayer = true
        knobView.layer?.backgroundColor = NSColor.white.cgColor
        knobView.layer?.cornerRadius = normalKnobSize / 2
        knobView.layer?.shadowColor = NSColor.black.cgColor
        knobView.layer?.shadowOpacity = 0.55
        knobView.layer?.shadowRadius = 3
        knobView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(knobView)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let ta = trackingArea {
            addTrackingArea(ta)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        animateTrack(expand: true)
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            isHovered = false
            animateTrack(expand: false)
        }
    }

    private func animateTrack(expand: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.layoutSublayers(expanded: expand)
        }
    }

    override func layout() {
        super.layout()
        layoutSublayers(expanded: isHovered || isDragging)
    }

    private func layoutSublayers(expanded: Bool) {
        let th = expanded ? hoverTrackHeight : normalTrackHeight
        let ks = expanded ? hoverKnobSize : normalKnobSize
        let trackY = (bounds.height - th) / 2

        trackBg.frame = NSRect(x: 0, y: trackY, width: bounds.width, height: th)
        trackBg.layer?.cornerRadius = th / 2

        let pw = max(0, min(bounds.width, bounds.width * currentProgress))
        trackProgress.frame = NSRect(x: 0, y: trackY, width: pw, height: th)
        trackProgress.layer?.cornerRadius = th / 2

        let knobX = max(0, min(bounds.width - ks, pw - ks / 2))
        let knobY = (bounds.height - ks) / 2
        knobView.frame = NSRect(x: knobX, y: knobY, width: ks, height: ks)
        knobView.layer?.cornerRadius = ks / 2
    }

    func setProgress(_ fraction: CGFloat) {
        guard !isDragging else { return }
        currentProgress = max(0, min(1.0, fraction))
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        animateTrack(expand: true)
        handleMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseEvent(event)
        isDragging = false
        if !isHovered {
            animateTrack(expand: false)
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let percent = max(0, min(1.0, Double(loc.x / bounds.width)))
        currentProgress = CGFloat(percent)
        needsLayout = true
        onSeek?(percent)
    }
}

// MARK: - Movie playlist context (continue-watching / episode nav)

struct MovieEpisodeItem {
    let name: String
    let slug: String
    let linkM3u8: String
    let linkEmbed: String

    init?(dict: [String: Any]) {
        let name = dict["name"] as? String ?? ""
        let slug = dict["slug"] as? String ?? ""
        let m3u8 = dict["linkM3u8"] as? String ?? ""
        let embed = dict["linkEmbed"] as? String ?? ""
        guard !name.isEmpty || !slug.isEmpty || !m3u8.isEmpty || !embed.isEmpty else { return nil }
        self.name = name.isEmpty ? (slug.isEmpty ? "Tập" : slug) : name
        self.slug = slug
        self.linkM3u8 = m3u8
        self.linkEmbed = embed
    }
}

struct MovieServerItem {
    let name: String
    let items: [MovieEpisodeItem]

    init?(dict: [String: Any]) {
        let name = dict["name"] as? String ?? "Server"
        let rawItems = dict["items"] as? [[String: Any]] ?? []
        let items = rawItems.compactMap { MovieEpisodeItem(dict: $0) }
        guard !items.isEmpty else { return nil }
        self.name = name
        self.items = items
    }
}

struct MovieContext {
    var slug: String
    var name: String
    var source: String
    var poster: String
    var serverIdx: Int
    var epIdx: Int
    var servers: [MovieServerItem]

    init?(dict: [String: Any]) {
        let slug = dict["slug"] as? String ?? ""
        guard !slug.isEmpty else { return nil }
        self.slug = slug
        self.name = dict["name"] as? String ?? slug
        self.source = dict["source"] as? String ?? ""
        self.poster = dict["poster"] as? String ?? ""
        self.serverIdx = dict["serverIdx"] as? Int ?? (dict["serverIdx"] as? NSNumber)?.intValue ?? 0
        self.epIdx = dict["epIdx"] as? Int ?? (dict["epIdx"] as? NSNumber)?.intValue ?? 0
        let rawServers = dict["servers"] as? [[String: Any]] ?? []
        self.servers = rawServers.compactMap { MovieServerItem(dict: $0) }
        if self.serverIdx < 0 || self.serverIdx >= self.servers.count {
            self.serverIdx = 0
        }
        if let server = self.servers[safe: self.serverIdx] {
            if self.epIdx < 0 || self.epIdx >= server.items.count {
                self.epIdx = 0
            }
        } else {
            self.epIdx = 0
        }
    }

    var currentEpisode: MovieEpisodeItem? {
        guard let server = servers[safe: serverIdx] else { return nil }
        return server.items[safe: epIdx]
    }

    var hasPlaylist: Bool {
        (servers.first?.items.count ?? 0) > 1 || servers.count > 1
    }

    mutating func moveEpisode(by delta: Int) -> MovieEpisodeItem? {
        guard let server = servers[safe: serverIdx], !server.items.isEmpty else { return nil }
        let next = epIdx + delta
        guard next >= 0, next < server.items.count else { return nil }
        epIdx = next
        return server.items[epIdx]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

// MARK: - FloatWindow — Always-on-top floating video window

class FloatWindow: NSPanel, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var titleBarView: NSView!
    private var titleLabel: NSTextField!
    private var controlBarView: NSView!
    private var scrubberView: ModernScrubberView!
    private var playPauseButton: NSButton!
    private var rewindButton: NSButton!
    private var skipButton: NSButton!
    private var volumeButton: NSButton!
    private var volumeSlider: NSSlider!
    private var speedButton: NSButton!
    private var maximizeButton: NSButton!
    private var sizeDownButton: NSButton?
    private var sizeUpButton: NSButton?
    private var sizePresetMiniButton: NSButton?
    private var sizePresetStandardButton: NSButton?
    private var sizePresetWideButton: NSButton?
    private var selectedSizePreset: SizePreset = .standard
    private var presetHoldWorkItem: DispatchWorkItem?
    private var stripAutoNextButton: NSButton?
    private var stripSkipIntroButton: NSButton?
    /// Per-episode: auto-skip intro already fired / user seeked manually.
    private var didAutoSkipIntroThisEpisode = false
    private var userSeekedThisEpisode = false
    private var didAutoAdvanceThisEpisode = false
    private var lastPlaybackSample: Double = 0
    /// Bumped on every load so a poll of the episode we just left cannot
    /// drive auto-next or a stream-error fallback for the new one.
    private var loadGeneration = 0
    /// True from the start of a load until the new document has actually started.
    private var suppressWatchAssist = false
    private var hasTriedDirectEmbedFallback = false
    private let interstitialQueue = DispatchQueue(label: "floatvideo.adscan")
    private var interstitialScanBusy = false
    private var audioScanBusy = false
    private var didAskSpeech = false
    private var didWarnSpeech = false
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private var interstitialSkipOrigin: Double?
    private var didAnnounceInterstitialSkip = false
    private var timeLabel: NSTextField!
    private var resizeIndicator: NSTextField?
    private var updateTimer: Timer?
    private var pinButton: NSButton?
    private var stripCloseButton: NSButton?
    private var stripGhostButton: NSButton?
    private var stripDuckButton: NSButton?
    private var stripPrevEpisodeButton: NSButton?
    private var stripNextEpisodeButton: NSButton?
    private var stripMoreButton: NSButton?
    /// Visible L/R resize affordances on the external strip (non-interactive views).
    private var stripLeftGrip: NSView?
    private var stripRightGrip: NSView?
    private var controlStrip: NSPanel?
    private var hudToast: PlaybackToast?
    private var resizeEdgeView: ResizeEdgeView?
    private var hudHideWorkItem: DispatchWorkItem?
    var isPinned = false
    var autoDockPaused = false
    var isResizeActive: Bool { isResizing }
    let vibeDock = VibeDock()
    private(set) var playbackElapsed: Double = 0
    private(set) var playbackDuration: Double = 0
    var playbackRate: Double { playbackRates[currentRateIndex] }
    var videoTitle: String
    var isPlaying = false
    private var userWantsMute = false
    private var videoAspectRatio: CGFloat = 16.0 / 9.0
    var isGhostMode = false
    private var preGhostAlpha: CGFloat = 1.0
    private var preDuckVolume: Double = 1.0
    private var isDucked = false
    private var isCodingSafeMode = false
    private var preSafeFrame: NSRect = .zero
    private var preSafeAlpha: CGFloat = 1.0
    private var pausedForBoss = false
    var isWindowVisible = true
    var currentVolume: Double { return volumeSlider?.doubleValue ?? 1.0 }
    private var currentEmbedUrl: String?
    private var hasTriedIframeEmbedFallback = false
    private var isMaximized = false
    private var preMaximizeFrame: NSRect = .zero
    private let playbackRates: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0, 0.75]
    private var currentRateIndex = 0
    private var lastMouseLocation: NSPoint = .zero
    private var mouseIdleTicks = 0
    private var movieContext: MovieContext?
    private var lastProgressSentAt: Date = .distantPast
    private let progressHeartbeatInterval: TimeInterval = 20
    /// Emits continue-watching PROGRESS payloads to Chrome via Native Messaging.
    var onProgress: (([String: Any]) -> Void)?

    // Video loading parameters (used by WKNavigationDelegate callbacks)
    private var currentSite: String = "generic"
    private var currentVideoTime: Double = 0
    private var hasInjectedJS = false
    private var hasInjectedAdSkip = false
    private var lastAdSkipCount = 0
    private var lastAdFFCount = 0
    private var isPostingSyntheticClick = false
    private var playerPrefs: [String: Any]?
    private var preferYouTubeEmbed = false

    func setPreferYouTubeEmbed(_ enabled: Bool) {
        preferYouTubeEmbed = enabled
    }
    private var prefsApplyDeadline: Date?
    private var lastPrefsStatus = "never-ran"
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
    static let ghostPrefKey = "FloatVideoGhostPreferred"
    private static let opacityPrefKey = "FloatVideoCodingOpacity"
    private static let sizePresetKey = "FloatVideoSizePreset"
    static let autoNextEpisodePrefKey = "FloatVideoAutoNextEpisode"
    static let autoSkipIntroPrefKey = "FloatVideoAutoSkipIntro"
    private static let introEndBySlugKey = "FloatVideoIntroEndBySlug"
    /// Conservative OP / cold-open length for VN/KR drama & anime.
    private static let defaultIntroSeconds: Double = 90
    /// Credits and next-episode preview that sit after the story.
    private static let defaultOutroSeconds: Double = 180
    private static let minEpisodeSecondsForIntroSkip: Double = 360

    enum SizePreset: String, CaseIterable {
        case mini, standard, wide, pocket

        var chipTitle: String {
            switch self {
            case .mini: return "Nhỏ"
            case .standard: return "Vừa"
            case .wide: return "Rộng"
            case .pocket: return "Lớn"
            }
        }

        var menuTitle: String {
            switch self {
            case .mini: return "Cỡ Nhỏ (~340px)"
            case .standard: return "Cỡ Vừa (~500px)"
            case .wide: return "Cỡ Rộng (~680px)"
            case .pocket: return "Cỡ Lớn (ô trống lớn nhất)"
            }
        }

        /// Target width; `nil` means fit largest clear pocket.
        var targetWidth: CGFloat? {
            switch self {
            case .mini: return 340
            case .standard: return 500
            case .wide: return 680
            case .pocket: return nil
            }
        }
    }

    static var savedSizePreset: SizePreset {
        let raw = UserDefaults.standard.string(forKey: sizePresetKey) ?? ""
        return SizePreset(rawValue: raw) ?? .standard
    }

    static func persistSizePreset(_ preset: SizePreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: sizePresetKey)
    }

    /// Default ON when never set (series benefit from binge-watch).
    static var preferredAutoNextEpisode: Bool {
        if UserDefaults.standard.object(forKey: autoNextEpisodePrefKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoNextEpisodePrefKey)
    }

    @discardableResult
    static func setPreferredAutoNextEpisode(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: autoNextEpisodePrefKey)
        return enabled
    }

    static var preferredAutoSkipIntro: Bool {
        if UserDefaults.standard.object(forKey: autoSkipIntroPrefKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoSkipIntroPrefKey)
    }

    @discardableResult
    static func setPreferredAutoSkipIntro(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: autoSkipIntroPrefKey)
        return enabled
    }

    private static func rememberedIntroEnd(forSlug slug: String) -> Double? {
        guard !slug.isEmpty,
              let dict = UserDefaults.standard.dictionary(forKey: introEndBySlugKey) as? [String: Double],
              let value = dict[slug], value > 10 else { return nil }
        return value
    }

    private static func rememberIntroEnd(_ seconds: Double, forSlug slug: String) {
        guard !slug.isEmpty, seconds > 10 else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: introEndBySlugKey) as? [String: Double]) ?? [:]
        dict[slug] = seconds
        UserDefaults.standard.set(dict, forKey: introEndBySlugKey)
    }

    /// Preferred click-through state. Defaults ON when never set.
    /// Used by status/toggle even when no float window is open yet.
    static var preferredGhostMode: Bool {
        if UserDefaults.standard.object(forKey: ghostPrefKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: ghostPrefKey)
    }

    @discardableResult
    static func setPreferredGhostMode(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: ghostPrefKey)
        return enabled
    }

    @discardableResult
    static func togglePreferredGhostMode() -> Bool {
        setPreferredGhostMode(!preferredGhostMode)
    }

    var onClose: (() -> Void)?

    func applyMovieContext(_ context: MovieContext?) {
        movieContext = context
        if let ep = context?.currentEpisode {
            videoTitle = context?.name.isEmpty == false
                ? "\(context!.name) — \(ep.name)"
                : ep.name
            titleLabel?.stringValue = videoTitle
        }
        resetEpisodeWatchAssistState()
        updateEpisodeButtons()
        refreshWatchAssistButtonStyles()
        layoutControlBar()
    }

    // For hover show/hide chrome (title + external control strip)
    private var isHovering = false
    private var hideTimer: DispatchWorkItem?
    private var cursorPollTimer: Timer?
    private var cursorWasInside = false
    private var hoverTip: NSPanel?
    private var hoverTipLabel: NSTextField?
    private var hoverTipAnchor: NSView?
    private var hoverTipSince: Date?
    /// Idle delay before PiP chrome auto-hides when the cursor leaves the player/strip.
    private static let chromeHideDelay: TimeInterval = 2.5

    // For window resize dragging
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    // For window resizing
    private var isResizing = false
    private var resizeEdge: ResizeEdge = .none
    private let resizeBorderWidth: CGFloat = 16

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
            self?.syncControlStrip(animated: false)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: self, queue: .main) { [weak self] _ in
            self?.scheduleInjectedLayoutRefresh()
            self?.layoutVideoChrome()
        }

        // Key setting 3: Floating panel properties
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear

        // Window size constraints (based on video aspect ratio, prevent minSize from breaking locked aspect ratio)
        let minW: CGFloat = (videoAspectRatio < 1.0) ? 220 : 200
        let maxW: CGFloat = (videoAspectRatio < 1.0) ? 540 : 1920
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
        titleBarView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        titleBarView.autoresizingMask = [.width, .minYMargin]

        let titleEffect = NSVisualEffectView(frame: titleBarView.bounds)
        titleEffect.autoresizingMask = [.width, .height]
        titleEffect.material = .hudWindow
        titleEffect.blendingMode = .withinWindow
        titleEffect.state = .active
        titleBarView.addSubview(titleEffect, positioned: .below, relativeTo: nil)

        // Close button (red)
        let closeBtn = createCircleButton(
            frame: NSRect(x: 10, y: 8, width: 14, height: 14),
            color: NSColor(red: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
            action: #selector(closeWindow)
        )
        titleBarView.addSubview(closeBtn)

        // Opacity button (yellow)
        let miniBtn = createCircleButton(
            frame: NSRect(x: 30, y: 8, width: 14, height: 14),
            color: NSColor(red: 1.0, green: 0.82, blue: 0.28, alpha: 1.0),
            action: #selector(toggleOpacity)
        )
        titleBarView.addSubview(miniBtn)

        // Pin (green) — locks position and pauses auto-dock
        let zoomBtn = createCircleButton(
            frame: NSRect(x: 50, y: 8, width: 14, height: 14),
            color: NSColor(red: 0.27, green: 0.85, blue: 0.46, alpha: 1.0),
            action: #selector(togglePin)
        )
        zoomBtn.toolTip = "Ghim vị trí — không tự né cửa sổ code"
        pinButton = zoomBtn as? NSButton
        titleBarView.addSubview(zoomBtn)

        // Ghost Mode button (purple / click-through)
        let ghostBtn = createCircleButton(
            frame: NSRect(x: 70, y: 8, width: 14, height: 14),
            color: NSColor(red: 0.68, green: 0.45, blue: 0.98, alpha: 1.0),
            action: #selector(toggleGhostMode)
        )
        ghostBtn.toolTip = "Xuyên chuột — bấm xuyên phim để gõ code. Thanh điều khiển vẫn bấm được."
        titleBarView.addSubview(ghostBtn)
        closeBtn.toolTip = "Đóng"
        miniBtn.toolTip = "Độ mờ"

        // Title text
        titleLabel = NSTextField(frame: NSRect(
            x: 92, y: 5,
            width: max(60, width - 102), height: 20
        ))
        titleLabel.stringValue = videoTitle
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = NSColor(white: 0.92, alpha: 1.0)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.autoresizingMask = [.width]
        titleBarView.addSubview(titleLabel)

        // WKWebView (fills entire window, title bar overlays on top)
        let webConfig = WKWebViewConfiguration()
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        webConfig.userContentController.add(self, name: "adWatch")
        webConfig.userContentController.add(self, name: "adAudio")
        prepareSpeechRecognition()

        let webFrame = NSRect(x: 0, y: 0, width: width, height: height)
        webView = WKWebView(frame: webFrame, configuration: webConfig)
        webView.autoresizingMask = []
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Use native Safari User-Agent to avoid JS engine fingerprint mismatch triggering YouTube's "fake browser" bot detection
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"

        container.addSubview(webView)
        let edges = ResizeEdgeView(frame: container.bounds)
        edges.border = resizeBorderWidth
        edges.autoresizingMask = [.width, .height]
        container.addSubview(edges)
        resizeEdgeView = edges

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

        // Bottom control bar (shown on hover, modern Apple PiP style)
        let barH: CGFloat = VibePlacer.stripHeight
        controlBarView = ControlBarView(frame: NSRect(x: 0, y: 0, width: width, height: barH))
        controlBarView.wantsLayer = true
        controlBarView.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.55).cgColor
        controlBarView.layer?.cornerRadius = 16
        controlBarView.layer?.masksToBounds = true
        controlBarView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        controlBarView.layer?.borderWidth = 0.5
        controlBarView.autoresizingMask = [.width, .maxYMargin]
        controlBarView.alphaValue = 0

        let controlEffect = NSVisualEffectView(frame: controlBarView.bounds)
        controlEffect.autoresizingMask = [.width, .height]
        controlEffect.material = .hudWindow
        controlEffect.blendingMode = .withinWindow
        controlEffect.state = .active
        controlBarView.addSubview(controlEffect, positioned: .below, relativeTo: nil)

        // Modern Scrubber (timeline track + knob)
        scrubberView = ModernScrubberView(frame: NSRect(x: 14, y: barH - 18, width: max(50, width - 28), height: 16))
        scrubberView.onSeek = { [weak self] percent in
            self?.userSeekedThisEpisode = true
            self?.seekTo(percent: percent)
        }
        controlBarView.addSubview(scrubberView)

        // Rewind 10s
        let rewBtn = makeControlButton(symbolName: "gobackward.10", action: #selector(skipBackward))
        self.rewindButton = rewBtn
        controlBarView.addSubview(rewBtn)

        // Play/Pause (prominent primary circular button)
        let ppBtn = makePrimaryPlayButton(action: #selector(togglePlayPause))
        self.playPauseButton = ppBtn
        controlBarView.addSubview(ppBtn)

        let prevEpBtn = makeTextChip(title: "Trước", action: #selector(prevEpisode))
        prevEpBtn.toolTip = "Tập trước"
        prevEpBtn.isHidden = true
        controlBarView.addSubview(prevEpBtn)
        stripPrevEpisodeButton = prevEpBtn

        let nextEpBtn = makeTextChip(title: "Sau", action: #selector(nextEpisode))
        nextEpBtn.toolTip = "Tập sau"
        nextEpBtn.isHidden = true
        controlBarView.addSubview(nextEpBtn)
        stripNextEpisodeButton = nextEpBtn

        // Skip forward 10s
        let fwdBtn = makeControlButton(symbolName: "goforward.10", action: #selector(skipForward))
        self.skipButton = fwdBtn
        controlBarView.addSubview(fwdBtn)

        // Volume Mute toggle
        let volBtn = makeControlButton(symbolName: "speaker.wave.2.fill", action: #selector(toggleMute))
        self.volumeButton = volBtn
        controlBarView.addSubview(volBtn)

        // Volume slider
        let slider = NSSlider(frame: NSRect(x: 0, y: 11, width: 48, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 1
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        controlBarView.addSubview(slider)
        self.volumeSlider = slider

        // Speed badge / button (1.0x -> 1.25x -> 1.5x -> 2.0x -> 0.75x)
        let sBtn = NSButton(frame: NSRect(x: 0, y: 10, width: 38, height: 22))
        sBtn.bezelStyle = .inline
        sBtn.isBordered = false
        sBtn.wantsLayer = true
        sBtn.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        sBtn.layer?.cornerRadius = 6
        sBtn.title = "1.0x"
        sBtn.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        sBtn.contentTintColor = NSColor(white: 0.95, alpha: 1.0)
        sBtn.target = self
        sBtn.action = #selector(cyclePlaybackRate)
        controlBarView.addSubview(sBtn)
        self.speedButton = sBtn

        // Maximize / Restore button
        let maxBtn = makeControlButton(symbolName: "arrow.up.left.and.arrow.down.right", action: #selector(toggleMaximize))
        controlBarView.addSubview(maxBtn)
        self.maximizeButton = maxBtn

        let smallerBtn = makeControlButton(symbolName: "minus.magnifyingglass", action: #selector(shrinkWindow))
        smallerBtn.toolTip = "Thu nhỏ cửa sổ (⌃⌥-)"
        controlBarView.addSubview(smallerBtn)
        sizeDownButton = smallerBtn

        let largerBtn = makeControlButton(symbolName: "plus.magnifyingglass", action: #selector(growWindow))
        largerBtn.toolTip = "Phóng to cửa sổ (⌃⌥=)"
        controlBarView.addSubview(largerBtn)
        sizeUpButton = largerBtn

        // Time label
        let tLabel = NSTextField(frame: NSRect(x: 0, y: 9, width: 90, height: 20))
        tLabel.stringValue = "--:--"
        tLabel.isEditable = false
        tLabel.isBordered = false
        tLabel.drawsBackground = false
        tLabel.textColor = NSColor(white: 0.92, alpha: 1.0)
        tLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        tLabel.alignment = .right
        tLabel.toolTip = "Thời gian"
        tLabel.lineBreakMode = .byClipping
        self.timeLabel = tLabel
        controlBarView.addSubview(tLabel)

        let presetMini = makeSizePresetChip(.mini)
        controlBarView.addSubview(presetMini)
        sizePresetMiniButton = presetMini
        let presetStandard = makeSizePresetChip(.standard)
        controlBarView.addSubview(presetStandard)
        sizePresetStandardButton = presetStandard
        let presetWide = makeSizePresetChip(.wide)
        controlBarView.addSubview(presetWide)
        sizePresetWideButton = presetWide
        selectedSizePreset = Self.savedSizePreset
        refreshSizePresetChipStyles()

        let closeOnStrip = makeControlButton(symbolName: "xmark", action: #selector(closeWindow), pointSize: 11)
        closeOnStrip.contentTintColor = NSColor(red: 1, green: 0.55, blue: 0.5, alpha: 1)
        closeOnStrip.toolTip = "Đóng"
        controlBarView.addSubview(closeOnStrip)
        stripCloseButton = closeOnStrip

        let ghostOnStrip = makeControlButton(symbolName: "eye", action: #selector(toggleGhostMode))
        ghostOnStrip.toolTip = "Xuyên chuột"
        controlBarView.addSubview(ghostOnStrip)
        stripGhostButton = ghostOnStrip

        let duckOnStrip = makeControlButton(symbolName: "ear", action: #selector(toggleDuck))
        duckOnStrip.toolTip = "Hạ tiếng"
        controlBarView.addSubview(duckOnStrip)
        stripDuckButton = duckOnStrip

        let autoNextBtn = makeControlButton(symbolName: "forward.end.alt.fill", action: #selector(toggleAutoNextEpisode), pointSize: 11)
        autoNextBtn.toolTip = "Tự động chuyển tập khi hết tập"
        controlBarView.addSubview(autoNextBtn)
        stripAutoNextButton = autoNextBtn

        let skipIntroBtn = makeControlButton(symbolName: "forward.fill", action: #selector(manualSkipIntro), pointSize: 11)
        skipIntroBtn.toolTip = "Bỏ qua giới thiệu (~90s) — giữ ⌥ để bật/tắt tự động"
        controlBarView.addSubview(skipIntroBtn)
        stripSkipIntroButton = skipIntroBtn

        let moreOnStrip = makeControlButton(symbolName: "ellipsis", action: #selector(showOverflowMenu))
        moreOnStrip.toolTip = "Thêm"
        moreOnStrip.isHidden = true
        controlBarView.addSubview(moreOnStrip)
        stripMoreButton = moreOnStrip

        playPauseButton?.toolTip = "Phát hoặc dừng"
        rewindButton?.toolTip = "Tua −10 giây"
        skipButton?.toolTip = "Tua +10 giây"
        volumeButton?.toolTip = "Tắt tiếng"
        volumeSlider?.toolTip = "Âm lượng"
        scrubberView?.toolTip = "Tua đến vị trí"
        speedButton?.toolTip = "Tốc độ phát"
        maximizeButton?.toolTip = "Phóng hết màn hình"
        refreshWatchAssistButtonStyles()

        container.addSubview(controlBarView, positioned: .above, relativeTo: webView)
        layoutVideoChrome()

        let hud = PlaybackToast(frame: NSRect(x: 12, y: height - 72, width: 160, height: 30))
        hud.alphaValue = 0
        hud.isHidden = true
        hud.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(hud, positioned: .above, relativeTo: webView)
        hudToast = hud

        // Hide title bar by default (PiP-style: shown on hover)
        titleBarView.alphaValue = 0

        // Corner resize grip — visible while hovering so size changes are discoverable
        let resizeIndicator = NSTextField(frame: NSRect(
            x: width - 22, y: 4, width: 18, height: 16
        ))
        resizeIndicator.stringValue = "⟋"
        resizeIndicator.isEditable = false
        resizeIndicator.isBordered = false
        resizeIndicator.drawsBackground = false
        resizeIndicator.textColor = NSColor(white: 0.85, alpha: 0.75)
        resizeIndicator.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        resizeIndicator.autoresizingMask = [.minXMargin, .maxYMargin]
        resizeIndicator.alphaValue = 0
        resizeIndicator.isHidden = false
        container.addSubview(resizeIndicator)
        self.resizeIndicator = resizeIndicator

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
        // Restore last size; placement vs code windows happens in show()/placeAwayFromCode().
        if let dict = UserDefaults.standard.dictionary(forKey: Self.frameKey),
           let w = dict["w"] as? CGFloat, dict["h"] is CGFloat {
            let restoredW = max(w, self.minSize.width)
            let savedH = restoredW / videoAspectRatio
            if let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat {
                let savedFrame = NSRect(x: x, y: y, width: restoredW, height: savedH)
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                    self.setFrame(savedFrame, display: false)
                    return
                }
            }
            // Size only — park top-right until placer runs.
            guard let screen = NSScreen.main else { return }
            let screenFrame = screen.visibleFrame
            let frame = NSRect(
                x: screenFrame.maxX - restoredW - 20,
                y: screenFrame.maxY - savedH - 20,
                width: restoredW,
                height: savedH
            )
            self.setFrame(frame, display: false)
            return
        }
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - self.frame.width - 20
        let y = screenFrame.maxY - self.frame.height - 20
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Prefer a clear pocket away from coding/input; fall back to coding-safe mode.
    func placeAwayFromCode() {
        vibeDock.placeImmediately(self)
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
                   cookies: [[String: Any]] = [],
                   playerPrefs: [String: Any]? = nil) {
        // Save parameters for NavigationDelegate use
        self.currentSite = site
        self.currentVideoTime = currentTime
        self.currentPageURL = url
        self.httpServerPortProvider = httpServerPortProvider
        self.playerPrefs = playerPrefs
        self.hasInjectedJS = false
        self.loadingStrategy = .fullPageInject
        self.loadGeneration += 1
        self.suppressWatchAssist = true
        self.hasTriedDirectEmbedFallback = false
        self.interstitialSkipOrigin = nil
        self.didAnnounceInterstitialSkip = false
        if let embedUrl, !embedUrl.isEmpty {
            self.currentEmbedUrl = embedUrl
        }
        resetYouTubeFallbackState()
        installPlayerPrefsSeedScript()

        // Lofi / live channels ask for the embed path so signed-out WKWebView
        // never hits the youtube.com/watch bot wall.
        if site == "youtube" && preferYouTubeEmbed {
            loadPreferredYouTubeEmbed(pageURL: url, currentTime: currentTime)
            return
        }

        if site == "youtube" {
            // One-line capture summary so caption problems are attributable at
            // a glance: was the track (incl. translation) captured at all?
            var trackDesc = "none"
            if let track = playerPrefs?["captionTrack"] as? [String: Any],
               let lang = track["languageCode"] as? String {
                if let tl = track["translationLanguage"] as? [String: Any],
                   let tlang = tl["languageCode"] as? String {
                    trackDesc = "\(lang)->\(tlang)"
                } else {
                    trackDesc = lang
                }
            }
            let lsCount = (playerPrefs?["localStorage"] as? [String: Any])?.count ?? 0
            let rate = (playerPrefs?["playbackRate"] as? NSNumber)?.doubleValue ?? 1.0
            NSLog("[FloatVideo] playerPrefs received: track=\(trackDesc) lsKeys=\(lsCount) rate=\(rate)")
        }

        // Suspend while the next document boots. The overlay only exists for the
        // first load; later episodes (next/prev) must still be unsuspended or
        // the new <video> stays paused forever.
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        scheduleResumeIfOverlayAlreadyGone()

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

        // Priority 3: Embed URL -- load directly in WKWebView with Referer
        if let embedUrl = embedUrl, !embedUrl.isEmpty, let targetURL = URL(string: embedUrl) {
            self.loadingStrategy = .siteEmbed
            self.currentEmbedUrl = embedUrl
            self.hasTriedIframeEmbedFallback = false
            var request = URLRequest(url: targetURL)
            if !url.isEmpty, let _ = URL(string: url) {
                request.setValue(url, forHTTPHeaderField: "Referer")
            } else if embedUrl.contains("streamc.xyz") {
                request.setValue("https://phim.nguonc.com/", forHTTPHeaderField: "Referer")
            } else if embedUrl.contains("tiktok.com") {
                request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
            }
            webView.load(request)
            NSLog("[FloatVideo] Loading embed directly: \(embedUrl)")
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

    /// Cinema Lofi path. A direct nocookie iframe paints without waiting for the
    /// local HTTP server or the widget API. The local /play page is only a fallback.
    private func loadPreferredYouTubeEmbed(pageURL: String, currentTime: Double, attempt: Int = 0) {
        if let videoId = extractYouTubeVideoId(from: pageURL),
           videoId.range(of: #"^[A-Za-z0-9_-]{6,16}$"#, options: .regularExpression) != nil {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.youtube-nocookie.com"
            components.path = "/embed/\(videoId)"
            var items = [
                URLQueryItem(name: "autoplay", value: "1"),
                URLQueryItem(name: "rel", value: "0"),
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "modestbranding", value: "1"),
            ]
            let start = Int(currentTime)
            if start > 0 {
                items.append(URLQueryItem(name: "start", value: String(start)))
            }
            components.queryItems = items
            if components.url != nil {
                preferYouTubeEmbed = true
                loadingStrategy = .youtubeEmbed
                hasTriedYouTubeEmbedFallback = true
                // A top-level WKWebView navigation sends no Referer, and YouTube
                // answers that with Error 153. loadHTMLString only attaches a
                // Referer when baseURL is the embedding app's own https origin
                // (YouTube's required-minimum-functionality rule). The IFrame
                // Player API then creates the embed from that page.
                let origin = "https://com.aspect.floatvideo"
                let html = """
                <!DOCTYPE html>
                <html><head>
                <meta charset="utf-8">
                <meta name="referrer" content="strict-origin-when-cross-origin">
                <style>
                    html, body, #player { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
                </style>
                </head><body>
                <div id="player"></div>
                <script>
                window.__floatYt = 'pending';
                var tag = document.createElement('script');
                tag.src = 'https://www.youtube.com/iframe_api';
                document.head.appendChild(tag);
                function onYouTubeIframeAPIReady() {
                    new YT.Player('player', {
                        width: '100%',
                        height: '100%',
                        videoId: '\(videoId)',
                        playerVars: {
                            autoplay: 1,
                            rel: 0,
                            playsinline: 1,
                            modestbranding: 1,
                            start: \(start),
                            origin: '\(origin)'
                        },
                        events: {
                            onReady: function(e) {
                                window.__floatYt = 'ready';
                                try { e.target.playVideo(); } catch (err) {}
                            },
                            onError: function(ev) {
                                window.__floatYt = 'error:' + ev.data;
                            }
                        }
                    });
                }
                </script>
                </body></html>
                """
                webView.loadHTMLString(html, baseURL: URL(string: origin + "/")!)
                NSLog("[FloatVideo] Loading preferred YouTube embed: \(videoId) referer=\(origin)/")
                schedulePreferredEmbedHealthCheck()
                return
            }
        }

        refreshYouTubeEmbedFallbackURLIfNeeded()
        if startYouTubeEmbedFallback(reason: "prefer-embed") {
            return
        }
        if attempt >= 25 {
            NSLog("[FloatVideo] preferEmbed gave up; no video id and no HTTP port")
            showEmbedFailure("Không mở được Lofi. Thử lại sau vài giây.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.loadPreferredYouTubeEmbed(pageURL: pageURL, currentTime: currentTime, attempt: attempt + 1)
        }
    }

    private func schedulePreferredEmbedHealthCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, self.preferYouTubeEmbed, self.loadingStrategy == .youtubeEmbed else { return }
            let js = """
            (function() {
                var st = window.__floatYt || '';
                if (st === 'ready') return 'ok';
                if (st.indexOf('error:') === 0) return st;
                var text = (document.body && document.body.innerText || '').slice(0, 240);
                if (/unavailable|private video|sign in|bot|confirm you.re not a bot|error 153/i.test(text)) return 'blocked:' + text;
                if (!document.querySelector('iframe') && st !== 'pending') return 'empty';
                return 'pending';
            })();
            """
            self.webView.evaluateJavaScript(js) { result, _ in
                let status = result as? String ?? "pending"
                if status == "ok" || status == "pending" { return }
                NSLog("[FloatVideo] Preferred embed unhealthy: \(status)")
                self.showEmbedFailure("YouTube không phát được trong cửa sổ này.")
            }
        }
    }

    private func showEmbedFailure(_ message: String) {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            if (document.getElementById('float-embed-error')) return;
            var el = document.createElement('div');
            el.id = 'float-embed-error';
            el.textContent = '\(escaped)';
            el.style.cssText = 'position:fixed;inset:0;display:flex;align-items:center;justify-content:center;padding:24px;background:#111;color:#f4f4f5;font:14px -apple-system,sans-serif;text-align:center;z-index:9;';
            document.body.appendChild(el);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func extractYouTubeVideoId(from url: String) -> String? {
        // youtube.com/watch?v=VIDEO_ID
        if let range = url.range(of: "v=") {
            let start = range.upperBound
            let remaining = String(url[start...])
            let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "&# ")).first
            if let id = videoId, !id.isEmpty { return id }
        }
        // youtube.com/embed/VIDEO_ID and youtu.be/VIDEO_ID
        for marker in ["/embed/", "youtu.be/"] {
            if let range = url.range(of: marker) {
                let start = range.upperBound
                let remaining = String(url[start...])
                let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "?&# /")).first
                if let id = videoId, !id.isEmpty { return id }
            }
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

    /// Mirrors the Chrome tab's `yt-player-*` localStorage (caption stickiness,
    /// quality, playback rate, volume) into this fresh WKWebView session BEFORE
    /// YouTube's code boots, so the floating player starts with the same player
    /// settings the user had in the browser tab.
    private func installPlayerPrefsSeedScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        guard currentSite == "youtube",
              let raw = playerPrefs?["localStorage"] as? [String: Any] else { return }
        let ls = raw.compactMapValues { $0 as? String }
        guard !ls.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ls) else { return }
        let b64 = data.base64EncodedString()
        let source = """
        try {
            var d = JSON.parse(atob('\(b64)'));
            for (var k in d) { try { localStorage.setItem(k, d[k]); } catch (e) {} }
        } catch (e) {}
        """
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    /// Re-applies the exact per-video player state captured from the Chrome tab
    /// at float time: the active caption track (including auto-translate target
    /// language) and the playback rate. Retries until YouTube's player + caption
    /// module are ready; the localStorage seed above already covers the sticky
    /// defaults, this covers the current video's explicit selection.
    private func scheduleApplyPlayerPrefs() {
        guard currentSite == "youtube", loadingStrategy == .fullPageInject,
              playerPrefs != nil else { return }
        // Deadline, not a retry count: a pre-roll ad (or a re-serve loop) can
        // occupy the player for tens of seconds, during which the caption
        // tracklist is the AD's (empty) one. Attempts during ads don't count.
        prefsApplyDeadline = Date().addingTimeInterval(60)
        attemptApplyPlayerPrefs(after: 2.0)
    }

    private func attemptApplyPlayerPrefs(after delay: TimeInterval) {
        guard let deadline = prefsApplyDeadline else { return }
        guard Date() < deadline else {
            NSLog("[FloatVideo] Player prefs give-up after 60s (last status: \(lastPrefsStatus))")
            prefsApplyDeadline = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            var trackB64 = ""
            if let track = self.playerPrefs?["captionTrack"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: track) {
                trackB64 = data.base64EncodedString()
            }
            let rate = (self.playerPrefs?["playbackRate"] as? NSNumber)?.doubleValue ?? 1.0
            let js = """
            (function() {
                if (window.__floatVideoPrefsApplied) return 'done';
                var p = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
                if (!p) return 'retry';
                // While an ad plays, the player exposes the ad's (empty)
                // tracklist — applying now would misfire. Report distinctly so
                // the native side keeps waiting without burning the deadline.
                if (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')) {
                    return 'ad';
                }
                var rate = \(rate);
                if (rate > 0 && rate !== 1 && typeof p.setPlaybackRate === 'function') {
                    try { p.setPlaybackRate(rate); } catch (e) {}
                }
                var trackB64 = '\(trackB64)';
                if (!trackB64) { window.__floatVideoPrefsApplied = true; return 'applied'; }
                if (typeof p.setOption !== 'function' || typeof p.getOption !== 'function') return 'retry';
                // The captions module may be unloaded when CC starts off.
                try { if (typeof p.loadModule === 'function') p.loadModule('captions'); } catch (e) {}
                var list = null;
                try { list = p.getOption('captions', 'tracklist'); } catch (e) { return 'retry'; }
                if (!list || !list.length) return 'retry';
                try {
                    var track = JSON.parse(atob(trackB64));
                    p.setOption('captions', 'track', track);
                    // Verify it took — setOption silently no-ops while the
                    // module is mid-initialization.
                    var cur = p.getOption('captions', 'track');
                    if (!cur || !cur.languageCode) return 'retry';
                    window.__floatVideoPrefsApplied = true;
                    return 'applied';
                } catch (e) { return 'retry'; }
            })();
            """
            self.webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self else { return }
                let status = result as? String ?? "retry"
                self.lastPrefsStatus = status
                switch status {
                case "applied":
                    NSLog("[FloatVideo] Player prefs applied (captions/rate)")
                    self.prefsApplyDeadline = nil
                case "ad":
                    // Ad occupying the player: extend patience past the ad
                    // without counting against the deadline meaningfully.
                    self.prefsApplyDeadline = max(self.prefsApplyDeadline ?? Date(),
                                                  Date().addingTimeInterval(30))
                    self.attemptApplyPlayerPrefs(after: 1.5)
                case "retry":
                    self.attemptApplyPlayerPrefs(after: 1.5)
                default:
                    self.prefsApplyDeadline = nil // 'done' or unexpected
                }
            }
        }
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
                scheduleApplyPlayerPrefs()
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
        } else if loadingStrategy == .siteEmbed {
            // Site embed: inject player automation, auto-play triggers, and hide overlay
            injectEmbedPlayerAutomation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hideLoadingOverlay()
            }
        } else {
            // Other strategies (direct video, YouTube embed) have built-in autoplay, remove overlay directly
            hideLoadingOverlay()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[FloatVideo] Page load failed: \(error)")
        refreshYouTubeEmbedFallbackURLIfNeeded()
        if shouldUseYouTubeFullPagePrimary() && startYouTubeEmbedFallback(reason: "didFail") {
            return
        }
        if loadingStrategy == .siteEmbed && !hasTriedIframeEmbedFallback, let embedUrl = currentEmbedUrl {
            hasTriedIframeEmbedFallback = true
            let html = buildEmbedHTML(embedUrl: embedUrl)
            webView.loadHTMLString(html, baseURL: nil)
            NSLog("[FloatVideo] Direct embed failed, falling back to iframe embed: \(embedUrl)")
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
        if loadingStrategy == .siteEmbed && !hasTriedIframeEmbedFallback, let embedUrl = currentEmbedUrl {
            hasTriedIframeEmbedFallback = true
            let html = buildEmbedHTML(embedUrl: embedUrl)
            webView.loadHTMLString(html, baseURL: nil)
            NSLog("[FloatVideo] Direct embed provisional failed, falling back to iframe embed: \(embedUrl)")
            return
        }
        hideLoadingOverlay()
    }

    /// Direct m3u8/mp4 failed (expired token, 403). The embed page is the
    /// same episode and is what the catalog stored alongside the stream.
    private func fallbackToEmbedIfDirectFailed() {
        guard loadingStrategy == .directVideo,
              !hasTriedDirectEmbedFallback,
              let embed = currentEmbedUrl, !embed.isEmpty,
              let targetURL = URL(string: embed) else { return }
        hasTriedDirectEmbedFallback = true
        loadingStrategy = .siteEmbed
        hasTriedIframeEmbedFallback = false
        suppressWatchAssist = true
        var request = URLRequest(url: targetURL)
        if embed.contains("streamc.xyz") || embed.contains("nguonc.com") {
            request.setValue("https://phim.nguonc.com/", forHTTPHeaderField: "Referer")
        } else if embed.contains("tiktok.com") {
            request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        } else if !currentPageURL.isEmpty {
            request.setValue(currentPageURL, forHTTPHeaderField: "Referer")
        }
        NSLog("[FloatVideo] Direct stream failed, falling back to embed: \(embed)")
        showHUD("Đang đổi nguồn phát")
        webView.load(request)
    }

    private func buildVideoHTML(videoSrc: String, currentTime: Double) -> String {
        let escapedSrc = videoSrc
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100vw; height: 100vh; background: #000; overflow: hidden; }
            video {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                object-fit: contain;
                background: #000;
                cursor: pointer;
            }
            /* Shown only while the burned-in gambling banner is on screen. */
            #float-ad-blur {
                position: fixed;
                z-index: 20;
                left: 0; right: 0; top: 0;
                height: calc(30px + 12%);
                pointer-events: none;
                opacity: 0;
                transition: opacity 0.18s linear;
                -webkit-backdrop-filter: blur(18px) saturate(0.75);
                backdrop-filter: blur(18px) saturate(0.75);
                background: rgba(0, 0, 0, 0.28);
                -webkit-mask-image: linear-gradient(to bottom, #000 78%, transparent);
                mask-image: linear-gradient(to bottom, #000 78%, transparent);
            }
        </style>
        <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
        </head><body>
        <video id="player" autoplay playsinline></video>
        <div id="float-ad-blur"></div>
        <script>
            const v = document.getElementById('player');
            const src = "\(escapedSrc)";
            const startTime = \(currentTime);
            function markStreamFailed() {
                window.__floatStreamFailed = true;
            }

            function playNative(url) {
                v.src = url;
                if (startTime > 0) v.currentTime = startTime;
                v.play().catch(function() {});
            }

            if (src.indexOf('.m3u8') !== -1) {
                if (typeof Hls !== 'undefined' && Hls.isSupported()) {
                    try {
                        const hls = new Hls({ enableWorker: true, lowLatencyMode: false });
                        hls.loadSource(src);
                        hls.attachMedia(v);
                        hls.on(Hls.Events.MANIFEST_PARSED, function() {
                            if (startTime > 0) v.currentTime = startTime;
                            v.play().catch(function() {});
                        });
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                console.warn('[FloatVideo] HLS.js error, falling back to native player', data);
                                hls.destroy();
                                v.addEventListener('error', markStreamFailed, { once: true });
                                playNative(src);
                            }
                        });
                    } catch (e) {
                        v.addEventListener('error', markStreamFailed, { once: true });
                        playNative(src);
                    }
                } else {
                    v.addEventListener('error', markStreamFailed, { once: true });
                    playNative(src);
                }
            } else {
                v.addEventListener('error', markStreamFailed, { once: true });
                playNative(src);
            }

            // The two black bands are inside the frame. Scale so the picture
            // fills the window. The corner logo is allowed to be cropped.
            function applySmartFill() {
                if (!v.videoWidth || v.readyState < 2) return;
                var sampleW = 80, sampleH = 45;
                var canvas = window.__floatFillCanvas || (window.__floatFillCanvas = document.createElement('canvas'));
                canvas.width = sampleW;
                canvas.height = sampleH;
                var ctx = canvas.getContext('2d', { willReadFrequently: true });
                try {
                    ctx.drawImage(v, 0, 0, sampleW, sampleH);
                    var data = ctx.getImageData(0, 0, sampleW, sampleH).data;
                } catch (e) {
                    return;
                }
                function lumaRow(y) {
                    var sum = 0;
                    var o = y * sampleW * 4;
                    for (var x = 4; x < sampleW - 4; x++) {
                        var i = o + x * 4;
                        sum += data[i] * 0.2126 + data[i + 1] * 0.7152 + data[i + 2] * 0.0722;
                    }
                    return sum / (sampleW - 8);
                }
                var edge = 14;
                var top = 0;
                while (top < sampleH * 0.36 && lumaRow(top) < edge) top++;
                var bottom = sampleH - 1;
                while (bottom > sampleH * 0.64 && lumaRow(bottom) < edge) bottom--;
                var mid = lumaRow((sampleH / 2) | 0);
                if (mid < edge + 20) return;
                var topFrac = top / sampleH;
                var botFrac = (bottom + 1) / sampleH;
                if (topFrac < 0.012 && botFrac > 0.988) {
                    if (window.__floatFillLocked) return;
                    v.style.transform = 'none';
                    v.style.objectFit = 'contain';
                    return;
                }
                // Eat a little of the picture so a leftover line and the logo go.
                topFrac = Math.min(0.2, topFrac + 0.015);
                botFrac = Math.max(0.8, botFrac - 0.015);
                var span = botFrac - topFrac;
                if (span < 0.55 || span > 0.98) return;
                var scale = 1 / span;
                var ty = ((scale - 1) * 0.5 - topFrac * scale) * 100;
                v.style.objectFit = 'contain';
                v.style.objectPosition = 'center center';
                v.style.transformOrigin = 'center center';
                v.style.transform = 'translateY(' + ty.toFixed(3) + '%) scale(' + scale.toFixed(4) + ')';
                window.__floatContentTop = topFrac;
                window.__floatFillLocked = true;
            }
            var fillTries = 0;
            function scheduleSmartFill() {
                if (fillTries > 12) return;
                fillTries++;
                applySmartFill();
            }
            v.addEventListener('loadeddata', scheduleSmartFill);
            v.addEventListener('playing', function onPlaying() {
                scheduleSmartFill();
                [600, 1500, 3000, 6000, 10000].forEach(function(ms) {
                    setTimeout(scheduleSmartFill, ms);
                });
                v.removeEventListener('playing', onPlaying);
            });

            // The gambling line is white type with a dark stroke across the top
            // of the picture. Blur only while that pattern is actually there.
            var adBlur = document.getElementById('float-ad-blur');
            var adHits = 0;
            var adMisses = 0;
            var adVisible = false;
            function topBandLooksLikeAd() {
                if (!v.videoWidth || v.readyState < 2) return false;
                var sw = 180, sh = 32;
                var canvas = window.__floatAdCanvas || (window.__floatAdCanvas = document.createElement('canvas'));
                canvas.width = sw;
                canvas.height = sh;
                var ctx = canvas.getContext('2d', { willReadFrequently: true });
                var topFrac = window.__floatContentTop || 0;
                var y0 = Math.min(v.videoHeight - 8, Math.round(v.videoHeight * topFrac));
                var srcH = Math.max(8, Math.round(v.videoHeight * 0.12));
                try {
                    ctx.drawImage(v, 0, y0, v.videoWidth, srcH, 0, 0, sw, sh);
                    var data = ctx.getImageData(0, 0, sw, sh).data;
                } catch (e) {
                    return false;
                }
                var textRows = 0;
                for (var y = 1; y < sh - 1; y++) {
                    var edges = [0, 0, 0];
                    var bright = 0;
                    var prev = 0;
                    for (var x = 1; x < sw; x++) {
                        var i = (y * sw + x) * 4;
                        var luma = data[i] * 0.2126 + data[i + 1] * 0.7152 + data[i + 2] * 0.0722;
                        var j = ((y - 1) * sw + x) * 4;
                        var up = data[j] * 0.2126 + data[j + 1] * 0.7152 + data[j + 2] * 0.0722;
                        if (Math.abs(luma - prev) > 48) edges[x < sw / 3 ? 0 : (x < (sw * 2) / 3 ? 1 : 2)]++;
                        if (luma > 195 && up < 90) bright++;
                        prev = luma;
                    }
                    if (edges[0] > 4 && edges[1] > 4 && edges[2] > 4 && bright > 6) textRows++;
                }
                return textRows >= 3;
            }
            function syncAdBlur() {
                if (!adBlur) return;
                if (v.paused || v.readyState < 2) return;
                if (topBandLooksLikeAd()) {
                    adHits++;
                    adMisses = 0;
                } else {
                    adMisses++;
                    adHits = 0;
                }
                if (!adVisible && adHits >= 2) {
                    adVisible = true;
                    adBlur.style.opacity = '1';
                } else if (adVisible && adMisses >= 4) {
                    adVisible = false;
                    adBlur.style.opacity = '0';
                }
            }
            setInterval(syncAdBlur, 450);

            // Full-screen spots (9922.com and the same gold/red card) get a
            // frame sample. Native OCR decides, then we jump ahead.
            var adShotBusy = false;
            function sampleInterstitial() {
                if (adShotBusy || window.__floatAdSkipping || v.paused || v.readyState < 2) return;
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.adWatch) return;
                var w = 280, h = 158;
                var shot = window.__floatAdShot || (window.__floatAdShot = document.createElement('canvas'));
                shot.width = w;
                shot.height = h;
                var sctx = shot.getContext('2d', { willReadFrequently: true });
                try { sctx.drawImage(v, 0, 0, w, h); } catch (e) { return; }
                var pixels;
                try { pixels = sctx.getImageData(0, 0, w, h).data; } catch (e) {
                    try { window.webkit.messageHandlers.adWatch.postMessage('blocked'); } catch (err) {}
                    return;
                }
                var gold = 0, red = 0, neon = 0, seen = 0;
                for (var y = 0; y < h; y += 3) {
                    for (var x = 0; x < w; x += 3) {
                        var p = (y * w + x) * 4;
                        var r = pixels[p], g = pixels[p + 1], b = pixels[p + 2];
                        seen++;
                        if (r > 170 && g > 120 && b < 110) gold++;
                        if (r > 150 && g < 100 && b < 110) red++;
                        if (g > 160 && r < 130 && g > r + 40) neon++;
                    }
                }
                if (seen < 8) return;
                var hot = gold / seen > 0.06 && red / seen > 0.035 && neon / seen > 0.025;
                if (!hot) return;
                adShotBusy = true;
                try {
                    window.webkit.messageHandlers.adWatch.postMessage(shot.toDataURL('image/jpeg', 0.5));
                } catch (e) {}
                setTimeout(function() { adShotBusy = false; }, 800);
            }
            setInterval(sampleInterstitial, 1100);

            function startAdAudioTap() {
                if (window.__floatAudioTap) return;
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.adAudio) return;
                var AC = window.AudioContext || window.webkitAudioContext;
                if (!AC) return;
                var actx;
                try { actx = new AC(); } catch (e) { return; }
                var node;
                try { node = actx.createMediaElementSource(v); } catch (e) { return; }
                var analyser = actx.createAnalyser();
                analyser.fftSize = 2048;
                node.connect(analyser);
                analyser.connect(actx.destination);
                window.__floatAudioTap = true;
                var wave = new Float32Array(analyser.fftSize);
                var pcm = [];
                function pump() {
                    if (!v.paused && v.readyState >= 2) {
                        if (actx.state === 'suspended') actx.resume();
                        analyser.getFloatTimeDomainData(wave);
                        var rate = actx.sampleRate || 44100;
                        var step = Math.max(1, Math.round(rate / 16000));
                        var energy = 0;
                        for (var i = 0; i < wave.length; i += step) {
                            var s = wave[i];
                            energy += s * s;
                            var q = s < -1 ? -1 : (s > 1 ? 1 : s);
                            pcm.push((q * 32767) | 0);
                        }
                        if (pcm.length >= 32000) {
                            if (energy / (wave.length / step) > 0.0004) {
                                var count = pcm.length;
                                var bytes = new Uint8Array(count * 2);
                                for (var n = 0; n < count; n++) {
                                    var v16 = pcm[n];
                                    bytes[n * 2] = v16 & 255;
                                    bytes[n * 2 + 1] = (v16 >> 8) & 255;
                                }
                                var bin = '';
                                for (var o = 0; o < bytes.length; o += 4096) {
                                    bin += String.fromCharCode.apply(null, bytes.subarray(o, Math.min(bytes.length, o + 4096)));
                                }
                                try { window.webkit.messageHandlers.adAudio.postMessage(btoa(bin)); } catch (e) {}
                            }
                            pcm = [];
                        }
                    }
                    setTimeout(pump, 45);
                }
                v.addEventListener('play', function() { actx.resume(); });
                actx.resume();
                pump();
            }
            v.addEventListener('playing', startAdAudioTap);
            if (!v.paused) startAdAudioTap();

            v.addEventListener('seeked', function() {
                if (!window.__floatAdSkipping) return;
                window.__floatAdSkipping = false;
                setTimeout(sampleInterstitial, 220);
            });

            v.addEventListener('click', function(e) {
                if (e.target === v) {
                    if (v.paused) v.play().catch(function() {});
                    else v.pause();
                }
            });

            v.addEventListener('dblclick', function() {
                if (document.fullscreenElement) {
                    document.exitFullscreen().catch(function() {});
                } else if (v.requestFullscreen) {
                    v.requestFullscreen().catch(function() {});
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
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100vw; height: 100vh; background: #000; overflow: hidden; }
            iframe {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                border: none;
            }
            #float-ad-blur { display: none; }
        </style>
        </head><body>
        <iframe src="\(embedUrl)"
                allow="accelerometer; autoplay *; clipboard-write; encrypted-media; gyroscope; picture-in-picture *; web-share; fullscreen *"
                referrerpolicy="strict-origin-when-cross-origin"
                allowfullscreen>
        </iframe>
        <div id="float-ad-blur"></div>
        </body></html>
        """
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Block popups from video/embed players
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    private func injectEmbedPlayerAutomation() {
        let js = """
        (function() {
            if (window.__floatVideoEmbedAutomationInstalled) return;
            window.__floatVideoEmbedAutomationInstalled = true;

            try {
                document.documentElement.style.overflow = 'hidden';
                document.body.style.overflow = 'hidden';
                document.body.style.margin = '0';
                document.body.style.padding = '0';
                document.body.style.background = '#000';
            } catch(e) {}

            var attempts = 0;
            var maxAttempts = 30; // 30 * 250ms = 7.5 seconds

            var timer = setInterval(function() {
                attempts++;

                // 1. If JWPlayer API is ready, trigger play
                if (window.jwplayer && typeof window.jwplayer === 'function') {
                    try {
                        var jw = window.jwplayer();
                        var state = jw.getState();
                        if (state === 'idle' || state === 'paused') {
                            jw.play();
                        }
                        if (state === 'playing' || state === 'buffering') {
                            clearInterval(timer);
                            return;
                        }
                    } catch(e) {}
                }

                // 2. If <video> element exists, try playing
                var v = document.querySelector('video');
                if (v) {
                    if (v.paused) {
                        v.muted = false;
                        v.play().catch(function() {
                            v.muted = true;
                            v.play().then(function() {
                                setTimeout(function() { v.muted = false; }, 400);
                            }).catch(function() {});
                        });
                    } else {
                        clearInterval(timer);
                        return;
                    }
                }

                // 3. Auto-click splash play buttons / verification buttons
                var playSelectors = [
                    '.jw-display-icon-display',
                    '.jw-display-icon-container',
                    '.jw-icon-display',
                    'button.jw-display-icon-container',
                    '.stream-player-button',
                    '.stream-resume-button',
                    '#verification button:not([hidden])',
                    '#verification-retry',
                    '.play-button',
                    '.vjs-big-play-button',
                    'button[aria-label*="Play" i]',
                    'button[aria-label*="Phát" i]',
                    'button[title*="Play" i]',
                    'button[title*="Phát" i]'
                ];

                for (var i = 0; i < playSelectors.length; i++) {
                    var btn = document.querySelector(playSelectors[i]);
                    if (btn && btn.offsetParent !== null && !btn.disabled) {
                        try { btn.click(); } catch(e) {}
                        break;
                    }
                }

                // 4. Auto-skip embed ads
                var skipBtn = document.querySelector('.jw-skip, .skip-ad, .video-ad-skip');
                if (skipBtn && skipBtn.offsetParent !== null) {
                    try { skipBtn.click(); } catch(e) {}
                }

                if (attempts >= maxAttempts) {
                    clearInterval(timer);
                }
            }, 250);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
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
                    /* Caption overlay: sibling of the <video>, so it must be
                       explicitly kept and painted ABOVE the fullscreen video
                       (same z-index, later in DOM order => on top). Our layout
                       forces the player to viewport size, so YouTube's own
                       caption-window positioning stays valid. */
                    .ytp-caption-window-container {
                        display: block !important;
                        visibility: visible !important;
                        opacity: 1 !important;
                        position: fixed !important;
                        left: 0 !important;
                        top: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        z-index: 2147483647 !important;
                        pointer-events: none !important;
                        background: transparent !important;
                    }
                ` : '';

                const isTikTok = site === 'tiktok';
                const tiktokCss = isTikTok ? `
                    html, body {
                        margin: 0 !important;
                        padding: 0 !important;
                        overflow-x: hidden !important;
                        overflow-y: scroll !important;
                        scroll-snap-type: y mandatory !important;
                        background: #000 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                    }
                    header, [data-e2e="nav-bar"], [data-e2e="side-nav"],
                    [data-e2e="bottom-app-banner"], div[class*="DivBottomBanner"],
                    div[class*="DivModalContainer"], div[class*="DivLoginModal"],
                    div[class*="DivSideNavContainer"], div[class*="DivFloatingCard"],
                    div[class*="DivActionItemContainer"], div[class*="DivShareAction"],
                    button[class*="ButtonAppStore"], [data-e2e="user-follow-button"] {
                        display: none !important;
                        visibility: hidden !important;
                        opacity: 0 !important;
                    }
                    #app, div[class*="DivBodyContainer"], div[class*="DivContentContainer"],
                    div[class*="DivFeedList"], div[class*="DivBrowserModeContainer"],
                    div[class*="DivMainContainer"], main {
                        margin: 0 !important;
                        padding: 0 !important;
                        width: 100vw !important;
                        max-width: 100vw !important;
                        background: #000 !important;
                    }
                    div[data-e2e="recommend-list-item-container"],
                    div[class*="DivVideoCardContainer"],
                    div[class*="DivItemContainer"] {
                        width: 100vw !important;
                        height: 100vh !important;
                        max-width: 100vw !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        scroll-snap-align: start !important;
                        display: flex !important;
                        justify-content: center !important;
                        align-items: center !important;
                        background: #000 !important;
                    }
                    div[data-e2e="recommend-list-item-container"] video,
                    div[class*="DivVideoCardContainer"] video,
                    div[class*="DivItemContainer"] video {
                        width: 100% !important;
                        height: 100% !important;
                        max-width: 100vw !important;
                        max-height: 100vh !important;
                        object-fit: contain !important;
                        background: #000 !important;
                    }
                ` : '';

                const baseHtmlOverflow = isTikTok
                    ? 'overflow-x: hidden !important; overflow-y: scroll !important;'
                    : 'overflow: hidden !important;';

                styleEl.textContent = `
                    html, body {
                        margin: 0 !important;
                        padding: 0 !important;
                        ${baseHtmlOverflow}
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
                        background: #000 !important;
                        z-index: 2147483647 !important;
                    }
                    ${youtubeCss}
                    ${tiktokCss}
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
                        // Caption overlay DOM is a SIBLING of the <video>, not an
                        // ancestor — never hide it, or captions can't render.
                        // The youtubeCss block overlays it above the video.
                        var cls = (typeof child.className === 'string') ? child.className : '';
                        if (cls.indexOf('ytp-caption-window-container') >= 0 ||
                            cls.indexOf('caption-window') >= 0) {
                            return;
                        }
                        child.style.setProperty('display', 'none', 'important');
                    }
                });
            }

            function applySmartFill(video) {
                if (!video || !video.videoWidth || video.readyState < 2) return;
                var vr = video.videoWidth / video.videoHeight;
                var fr = window.innerWidth / Math.max(window.innerHeight, 1);
                video.style.setProperty('transform', 'none', 'important');
                video.style.setProperty('object-position', 'center center', 'important');
                video.style.setProperty('object-fit', vr > fr + 0.01 ? 'cover' : 'contain', 'important');
                window.__floatContentTop = 0;
                window.__floatFillLocked = true;
            }

            function applyLayout() {
                if (window.__floatVideoApplyingLayout) return false;

                if (site === 'tiktok') {
                    window.__floatVideoApplyingLayout = true;
                    try {
                        ensureFloatVideoStyle();

                        const handleTikTokMedia = () => {
                            document.querySelectorAll('video').forEach(v => {
                                if (v.muted) v.muted = false;
                                v.volume = 1.0;
                                v.setAttribute('playsinline', '');
                            });
                            const closeBtn = document.querySelector('[data-e2e="modal-close-inner-button"], [aria-label="Close"], button[class*="ButtonClose"], [data-e2e="login-modal"] button');
                            if (closeBtn) try { closeBtn.click(); } catch(e) {}
                        };
                        handleTikTokMedia();

                        if (!window.__tiktokTimer) {
                            window.__tiktokTimer = setInterval(handleTikTokMedia, 1000);
                        }

                        if (!window.__tiktokNavInstalled) {
                            window.__tiktokNavInstalled = true;
                            window.addEventListener('keydown', (e) => {
                                if (e.key === 'ArrowDown' || e.key === 'j' || e.key === 'PageDown') {
                                    e.preventDefault();
                                    window.scrollBy({ top: window.innerHeight, behavior: 'smooth' });
                                } else if (e.key === 'ArrowUp' || e.key === 'k' || e.key === 'PageUp') {
                                    e.preventDefault();
                                    window.scrollBy({ top: -window.innerHeight, behavior: 'smooth' });
                                }
                            });
                        }

                        const currentVid = findMainVideo();
                        if (currentVid) {
                            currentVid.play().catch(() => {});
                            window.__floatVideoMainVideo = currentVid;
                        }
                        return true;
                    } finally {
                        window.__floatVideoApplyingLayout = false;
                    }
                }

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
                    applySmartFill(mainVideo);
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
                '.ytp-skip-ad button',
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

            // --- Trusted-click support -----------------------------------
            // YouTube now ignores untrusted (JS-synthesized) clicks on the
            // skip button, so the actual press is performed by the native app
            // as a real mouse event. To make that possible the button must be
            // renderable and hit-testable: reveal its ancestor chain (siblings
            // stay hidden — they carry their own inline display:none), keep
            // the button itself at 2% opacity so nothing is visible over the
            // video, then publish its center point for the Swift side, which
            // consumes it via the state poll and posts real mouse events.
            var revealed = [];

            function prepareForTrustedClick(btn) {
                try {
                    var node = btn;
                    while (node && node !== document.body) {
                        // The chain shared with the <video> is already visible
                        // and must keep receiving pointer events — skip it.
                        if (node.classList && node.classList.contains('__floatvideo-ancestor')) {
                            node = node.parentElement;
                            continue;
                        }
                        node.style.setProperty('display', 'block', 'important');
                        node.style.setProperty('visibility', 'visible', 'important');
                        if (node === btn) {
                            node.style.setProperty('opacity', '0.02', 'important');
                            node.style.setProperty('pointer-events', 'auto', 'important');
                            node.style.setProperty('position', 'relative', 'important');
                            node.style.setProperty('z-index', '2147483647', 'important');
                        } else {
                            node.style.setProperty('pointer-events', 'none', 'important');
                        }
                        if (revealed.indexOf(node) < 0) revealed.push(node);
                        node = node.parentElement;
                    }
                    var r = btn.getBoundingClientRect();
                    if (!r || r.width < 2 || r.height < 2) return null;
                    var x = r.left + r.width / 2;
                    var y = r.top + r.height / 2;
                    if (x < 1 || y < 1 || x > window.innerWidth - 1 || y > window.innerHeight - 1) return null;
                    return { x: x, y: y };
                } catch (e) { return null; }
            }

            function restoreRevealed() {
                while (revealed.length) {
                    var n = revealed.pop();
                    try {
                        n.style.setProperty('display', 'none', 'important');
                        n.style.removeProperty('pointer-events');
                        n.style.removeProperty('z-index');
                    } catch (e) {}
                }
                window.__floatVideoPendingTrustedClick = null;
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
                    restoreRevealed();
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
                    restoreRevealed();
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
                    // Free first shot: some player builds expose an internal
                    // skipAd(); harmless no-op elsewhere.
                    try { if (typeof player.skipAd === 'function') player.skipAd(); } catch (e) {}
                    var pt = prepareForTrustedClick(btn);
                    if (pt) {
                        // Native side consumes this via the state poll and posts
                        // a real (trusted) mouse click at these page coordinates.
                        window.__floatVideoPendingTrustedClick = { x: pt.x, y: pt.y, ts: now };
                    } else {
                        // Could not obtain a hit-testable rect — fall back to the
                        // untrusted click (better than nothing).
                        btn.click();
                    }
                    lastClickAt = now;
                    if (++clicks === 1) window.__floatVideoAdSkipCount++;
                } else if (!ffDone && now - lastClickAt >= 2000) {
                    // 3 clicks ignored. Only for SKIPPABLE ads (button present):
                    // jump to just before the end and let 'ended' fire naturally,
                    // which the ad pipeline credits as a completion far more
                    // reliably than a hard seek to duration (fewer re-serves).
                    // Main content is never touched (adShowing gate).
                    if (isFinite(v.duration) && v.duration > 0.5) {
                        restoreRevealed();
                        v.currentTime = Math.max(0, v.duration - 0.15);
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

    /// Posts a real mouse down/up pair at the given page coordinates (CSS px,
    /// top-left origin) inside the WKWebView. Real AppKit events produce
    /// TRUSTED DOM events in WebKit — required because YouTube now ignores
    /// untrusted (JS-synthesized) clicks on the ad Skip button.
    private func performTrustedClick(pageX: Double, pageY: Double) {
        let bounds = webView.bounds
        guard pageX >= 1, pageY >= 1,
              pageX <= Double(bounds.width) - 1,
              pageY <= Double(bounds.height) - 1 else { return }

        // Page Y grows downward; AppKit view coordinates grow upward.
        let viewPoint = NSPoint(x: pageX, y: bounds.height - CGFloat(pageY))

        // Never click through our own overlay UI; the guard retries in <=2s,
        // by which time the hover bars are usually hidden again.
        if let container = webView.superview {
            let containerPoint = webView.convert(viewPoint, to: container)
            if titleBarView.alphaValue > 0.01, titleBarView.frame.contains(containerPoint) { return }
            if controlBarView.alphaValue > 0.01, controlBarView.frame.contains(containerPoint) { return }
        }

        let windowPoint = webView.convert(viewPoint, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
                                            modifierFlags: [], timestamp: time,
                                            windowNumber: windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
                                          modifierFlags: [], timestamp: time + 0.05,
                                          windowNumber: windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return }

        isPostingSyntheticClick = true
        sendEvent(down)
        sendEvent(up)
        isPostingSyntheticClick = false
        NSLog("[FloatVideo] Trusted click at page (\(Int(pageX)), \(Int(pageY)))")
    }

    // MARK: - Window Actions

    func show() {
        titleBarView.alphaValue = 1.0
        // Restore vibe-coding prefs before first paint.
        applyPreferredGhostOnOpen()
        mountControlStrip()
        placeAwayFromCode()
        // Apply last vibe size preset when reasonable (not already near that width).
        let preset = Self.savedSizePreset
        selectedSizePreset = preset
        refreshSizePresetChipStyles()
        if preset != .pocket, let target = preset.targetWidth, abs(frame.width - target) > 48 {
            applySizePreset(preset)
        }
        ensureVisibleOnScreen()
        syncControlStrip(animated: false)
        refreshWatchAssistButtonStyles()
        // Never activate or become key — the IDE must keep the keyboard.
        self.orderFrontRegardless()
        showControls()
        scheduleHideControls(after: Self.chromeHideDelay)
        // Force another front pass after AppKit settles collection/space membership.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.ensureVisibleOnScreen()
            self.orderFrontRegardless()
            if self.isHovering {
                self.setStripChromeVisible(true, animated: false)
            }
            NSLog("[FloatVideo] Window shown frame=\(NSStringFromRect(self.frame)) alpha=\(self.alphaValue) ghost=\(self.isGhostMode) screen=\(self.screen?.localizedName ?? "nil")")
        }
        vibeDock.attach(self)
        VibeNowPlaying.install(target: self)
        startCursorPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.hideLoadingOverlay()
        }
    }

    /// Keep the player on a real visible display — never leave it off-screen after dock/restore.
    func ensureVisibleOnScreen() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let pad: CGFloat = 8
        var frame = self.frame
        if frame.width < minSize.width || frame.height < 80 || frame.width.isNaN || frame.height.isNaN {
            let w = max(minSize.width, 420)
            frame.size = NSSize(width: w, height: w / max(videoAspectRatio, 0.2))
        }

        let intersects = screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 24, dy: 24)) }
        let screen = (intersects ? (self.screen ?? NSScreen.main) : nil) ?? NSScreen.main ?? screens[0]
        let vis = screen.visibleFrame

        if frame.width > vis.width - pad * 2 {
            frame.size.width = max(minSize.width, vis.width - pad * 2)
            frame.size.height = frame.size.width / max(videoAspectRatio, 0.2)
        }
        if frame.height > vis.height - VibePlacer.stripHeight - pad * 2 {
            frame.size.height = max(minSize.height, vis.height - VibePlacer.stripHeight - pad * 2)
            frame.size.width = frame.size.height * max(videoAspectRatio, 0.2)
        }

        frame.origin.x = min(max(frame.origin.x, vis.minX + pad), vis.maxX - frame.width - pad)
        frame.origin.y = min(max(frame.origin.y, vis.minY + pad + VibePlacer.stripHeight), vis.maxY - frame.height - pad)

        if frame != self.frame {
            setFrame(frame, display: true)
            syncControlStrip(animated: false)
        }

        // Never open invisibly soft — coding-safe soft opacity still stays readable.
        if alphaValue < 0.45 {
            alphaValue = 0.72
        }
    }

    private func startCursorPolling() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollCursorPosition()
        }
    }

    private func pollCursorPosition() {
        let hoveringChrome = isPointerOverChrome()

        if isResizing || isInteractingWithChrome {
            // Keep chrome visible during resize / scrubber drag; freeze hide.
            keepChromeVisibleForInteraction()
            cursorWasInside = true
            return
        }

        if hoveringChrome {
            cursorWasInside = true
            hideTimer?.cancel()
            hideTimer = nil
            if !isHovering {
                showControls()
            } else {
                // Strip shown: never leave ignoresMouseEvents=true under the cursor.
                ensureStripAcceptsMouseWhileVisible()
            }
            updateStripPointerFeedback()
        } else if cursorWasInside {
            cursorWasInside = false
            hideHoverTip()
            if isHovering { scheduleHideControls(after: Self.chromeHideDelay) }
        }
    }

    /// The strip is a non-key panel, so AppKit will not show view tooltips or
    /// change the cursor while the IDE stays frontmost. Do both ourselves.
    func updateStripPointerFeedback() {
        guard let strip = controlStrip, let content = strip.contentView else {
            hideHoverTip()
            return
        }
        let local = strip.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard content.bounds.contains(local), let hit = content.hitTest(local) else {
            hideHoverTip()
            return
        }
        let edge = ControlBarView.edgeWidth
        if local.x < edge || local.x > content.bounds.width - edge {
            NSCursor.resizeLeftRight.set()
            hideHoverTip()
            return
        }
        var control: NSView?
        var view: NSView? = hit
        while let current = view, current !== content {
            let tip = current.toolTip ?? ""
            if !current.isHidden, (current is NSControl || current is ModernScrubberView), !tip.isEmpty {
                control = current
                break
            }
            view = current.superview
        }
        guard let control, let text = control.toolTip, !text.isEmpty else {
            NSCursor.arrow.set()
            hideHoverTip()
            return
        }
        NSCursor.pointingHand.set()
        if hoverTipAnchor !== control {
            hoverTipAnchor = control
            hoverTipSince = Date()
            hideHoverTip(keepAnchor: true)
            return
        }
        guard let since = hoverTipSince, Date().timeIntervalSince(since) >= 0.35 else { return }
        showHoverTip(text, anchor: control)
    }

    private func showHoverTip(_ text: String, anchor: NSView) {
        guard let strip = controlStrip else { return }
        let label = hoverTipLabel ?? NSTextField(labelWithString: "")
        hoverTipLabel = label
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.drawsBackground = false
        label.isBezeled = false
        label.isBordered = false
        let width = min(240, ceil((text as NSString).size(withAttributes: [.font: label.font as Any]).width) + 18)
        let height: CGFloat = 22
        label.frame = NSRect(x: 0, y: 3, width: width, height: 16)
        let panel: NSPanel
        if let existing = hoverTip {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 4)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let bg = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
            bg.layer?.cornerRadius = 6
            created.contentView = bg
            hoverTip = created
            panel = created
        }
        if label.superview == nil {
            panel.contentView?.addSubview(label)
        }
        panel.contentView?.frame.size = NSSize(width: width, height: height)
        let anchorOnScreen = strip.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(NSRect(
            x: anchorOnScreen.midX - width / 2,
            y: anchorOnScreen.maxY + 6,
            width: width,
            height: height
        ), display: true)
        panel.orderFrontRegardless()
    }

    private func hideHoverTip(keepAnchor: Bool = false) {
        hoverTip?.orderOut(nil)
        if !keepAnchor {
            hoverTipAnchor = nil
            hoverTipSince = nil
        }
    }

    /// True while the user is actively using strip controls (scrubber, etc.).
    private var isInteractingWithChrome: Bool {
        scrubberView?.isDragging == true
    }

    /// Cursor over video, strip, or the small gap between them — keep chrome stable.
    private func isPointerOverChrome(at point: NSPoint = NSEvent.mouseLocation) -> Bool {
        if isResizing || isInteractingWithChrome { return true }
        // Inflate by stripGap so the band between video and strip does not thrash hide/show.
        let pad = VibePlacer.stripGap + 4
        if frame.insetBy(dx: -2, dy: -pad).contains(point) { return true }
        if let strip = controlStrip, strip.frame.insetBy(dx: -2, dy: -pad).contains(point) {
            return true
        }
        return false
    }

    private func keepChromeVisibleForInteraction() {
        hideTimer?.cancel()
        hideTimer = nil
        if !isHovering { showControls() }
        else { ensureStripAcceptsMouseWhileVisible() }
    }

    /// Called from the external strip panel so hover/click keeps chrome visible.
    func noteStripInteraction() {
        cursorWasInside = true
        keepChromeVisibleForInteraction()
    }

    /// Strip mouseExited — only start the long idle hide if pointer left video+strip.
    func noteStripPointerExited() {
        if isResizing || isInteractingWithChrome { return }
        if isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
            return
        }
        scheduleHideControls(after: Self.chromeHideDelay)
    }

    /// While chrome is up, the strip must receive mouse (grips/buttons) — never click-through.
    private func ensureStripAcceptsMouseWhileVisible() {
        guard isHovering, let strip = controlStrip else { return }
        if strip.ignoresMouseEvents {
            strip.ignoresMouseEvents = false
            strip.acceptsMouseMovedEvents = true
        }
        if strip.alphaValue < 0.95 {
            strip.alphaValue = 1
        }
    }

    /// First load hides the overlay and resumes there. A later episode has
    /// already removed the overlay, so didFinish used to return without ever
    /// clearing the suspend — next episode loaded and stayed silent.
    private func scheduleResumeIfOverlayAlreadyGone() {
        guard loadingOverlay == nil else { return }
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, self.loadGeneration == generation else { return }
            self.resumeMediaPlayback()
        }
    }

    private func resumeMediaPlayback() {
        webView.setAllMediaPlaybackSuspended(false) { [weak self] in
            guard let self = self else { return }
            self.triggerPlayback()
            let generation = self.loadGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, self.loadGeneration == generation else { return }
                self.suppressWatchAssist = false
            }
        }
    }

    private func hideLoadingOverlay() {
        resumeMediaPlayback()
        guard let overlay = loadingOverlay else {
            startUpdateTimer()
            return
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
                self?.hideControls()
            }
        })
    }

    private func triggerPlayback() {
        let wantMute = userWantsMute
        let mutedJSBool = wantMute ? "true" : "false"
        let ytMuteCmd = wantMute ? "'mute'" : "'unmute'"
        // Never force volume 1.0 while ducked — keep the ducked level.
        let playVol: Double = {
            if wantMute { return 0 }
            if isDucked {
                return volumeSlider?.doubleValue ?? max(0.05, preDuckVolume * 0.2)
            }
            let chosen = volumeSlider?.doubleValue ?? 1
            return chosen > 0 ? chosen : 1
        }()
        let jwVol = Int(playVol * 100)
        let js = """
        (function() {
            var wantMute = \(mutedJSBool);
            var playVol = \(playVol);
            document.querySelectorAll('video').forEach(function(v) {
                v.muted = wantMute;
                if (!wantMute) v.volume = playVol;
                try { v.playbackRate = \(playbackRate); } catch (e) {}
                v.play().catch(function() {});
            });
            if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    jw.setMute(wantMute);
                    if (!wantMute) jw.setVolume(\(jwVol));
                    if (jw.getState() !== 'playing') jw.play();
                } catch(e) {}
            }
            if (window.playerCommand) {
                window.playerCommand(\(ytMuteCmd));
                if (!wantMute) window.playerCommand('volume', playVol);
                window.playerCommand('play');
            }
            var iframe = document.querySelector('iframe');
            if (iframe) {
                try {
                    iframe.contentWindow.postMessage(JSON.stringify({event:'command',func:'playVideo',args:[]}), '*');
                } catch(e) {}
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? String else { return }
        if message.name == "adAudio" {
            hearAdvertisement(payload)
            return
        }
        guard message.name == "adWatch" else { return }
        if payload == "blocked" {
            NSLog("[FloatVideo] Ad scan could not read the video frame")
            return
        }
        guard !interstitialScanBusy else { return }
        interstitialScanBusy = true
        interstitialQueue.async { [weak self] in
            let image = Self.image(fromDataURL: payload)
            let visual = image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(Self.looksLikeSlotFrame) ?? false
            let text = image.flatMap { Self.readText(in: $0) } ?? ""
            let textual = Self.looksLikeInterstitialAd(text)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.interstitialScanBusy = false
                if visual || textual {
                    NSLog("[FloatVideo] Interstitial ad frame visual=\(visual) text=\(text.prefix(80))")
                    self.skipInterstitialAd()
                } else if self.interstitialSkipOrigin == nil {
                    self.didAnnounceInterstitialSkip = false
                }
            }
        }
    }

    private static func image(fromDataURL payload: String) -> NSImage? {
        guard let comma = payload.firstIndex(of: ",") else { return nil }
        let b64 = String(payload[payload.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    /// Slot spots are gold + red character + neon green at once. A drama frame is not.
    private static func looksLikeSlotFrame(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        var gold = 0, red = 0, neon = 0, n = 0
        let step = 3
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                    n += 1
                    if r > 0.62 && g > 0.42 && b < 0.45 { gold += 1 }
                    if r > 0.55 && g < 0.42 && b < 0.45 { red += 1 }
                    if g > 0.58 && r < 0.5 && g > r + 0.16 { neon += 1 }
                }
                x += step
            }
            y += step
        }
        guard n > 20 else { return false }
        let gn = Double(gold) / Double(n)
        let rn = Double(red) / Double(n)
        let nn = Double(neon) / Double(n)
        return gn > 0.07 && rn > 0.04 && nn > 0.03
    }

    private static func readText(in image: NSImage) -> String {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["vi-VN", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ")
    }

    private func prepareSpeechRecognition() {
        guard !didAskSpeech else { return }
        didAskSpeech = true
        SFSpeechRecognizer.requestAuthorization { status in
            NSLog("[FloatVideo] Speech recognition auth \(status.rawValue)")
        }
    }

    /// Two seconds of 16 kHz mono PCM from the video element, not the microphone.
    private func hearAdvertisement(_ base64: String) {
        guard !audioScanBusy else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            if !didWarnSpeech {
                didWarnSpeech = true
                NSLog("[FloatVideo] Speech recognition is not authorized yet")
            }
            return
        }
        guard speechRecognizer?.isAvailable == true, let data = Data(base64Encoded: base64), data.count > 4000 else { return }
        audioScanBusy = true
        let sampleCount = data.count / 2
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.floatChannelData?[0] else {
            audioScanBusy = false
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                dst[i] = Float(Int16(littleEndian: src[i])) / 32768
            }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.append(buffer)
        request.endAudio()
        speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            let done = (result?.isFinal == true) || error != nil
            if let text = result?.bestTranscription.formattedString, Self.looksLikeInterstitialAd(text) {
                NSLog("[FloatVideo] Heard ad: \(text.prefix(80))")
                DispatchQueue.main.async { self.skipInterstitialAd() }
            }
            if done {
                DispatchQueue.main.async { self.audioScanBusy = false }
            }
        }
    }

    private static func looksLikeInterstitialAd(_ text: String) -> Bool {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi")).lowercased()
        if folded.range(of: #"\d{2,6}\s*\.\s*(com|vip|net|cc|xyz|club|fun|bet|top|live)\b"#, options: .regularExpression) != nil {
            return true
        }
        let phrases = ["ban ca", "song bai", "no hu", "casino", "jackpot", "big win", "game bai", "rut tien", "dang ky", "nap tien", "9922", "tin dung", "bung no", "cuoc", "quang cao", "tai tro", "khuyen mai", "choi ngay", "gioi thieu", "tap truoc"]
        return phrases.contains { folded.contains($0) }
    }

    private func skipInterstitialAd() {
        let js = """
        (function() {
            var v = document.getElementById('player');
            if (!v || !isFinite(v.duration) || v.duration < 30) return '';
            return v.currentTime || 0;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            let now = (result as? NSNumber)?.doubleValue ?? Double(result as? String ?? "") ?? 0
            let origin = self.interstitialSkipOrigin ?? now
            self.interstitialSkipOrigin = origin
            if now - origin > 180 { return }
            let intro = self.movieContext == nil ? 0 : self.introEndSeconds(forDuration: max(self.playbackDuration, 600))
            // Opening ads sit inside the intro. Clear both in one jump.
            let target = (self.movieContext != nil && now < intro - 2) ? intro : now + 20
            if !self.didAnnounceInterstitialSkip {
                self.didAnnounceInterstitialSkip = true
                self.showHUD(target == intro ? "Đã tua qua giới thiệu" : "Đã tua qua quảng cáo")
            }
            let jump = """
            (function() {
                var v = document.getElementById('player');
                if (!v || !isFinite(v.duration)) return;
                var next = Math.min(v.duration - 1.5, \(target));
                if (next <= (v.currentTime || 0) + 0.4) return;
                window.__floatAdSkipping = true;
                v.currentTime = next;
                v.play().catch(function() {});
            })();
            """
            self.webView.evaluateJavaScript(jump, completionHandler: nil)
        }
    }

    @objc func closeWindow() {
        emitProgress(force: true)
        hideTimer?.cancel()
        hideTimer = nil
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
        vibeDock.stop()
        VibeNowPlaying.clear()
        hideHoverTip()
        controlStrip?.orderOut(nil)
        controlStrip?.close()
        controlStrip = nil
        resetYouTubeFallbackState()
        reinjectLayoutWorkItem?.cancel()
        reinjectLayoutWorkItem = nil
        stopUpdateTimer()
        saveWindowFrame()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "adWatch")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "adAudio")
        onClose?()
        self.close()
    }

    // MARK: - Hover Controls

    private func showControls() {
        hideTimer?.cancel()
        let alreadyShown = isHovering && titleBarView.alphaValue > 0.98
        isHovering = true
        setStripChromeVisible(true, animated: !alreadyShown)
        // Restarting the fade on every hover poll made the corner grip blink.
        guard !alreadyShown else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            titleBarView.animator().alphaValue = 1.0
            resizeIndicator?.animator().alphaValue = 0.9
        })
    }

    private func scheduleHideControls(after delay: TimeInterval = 2.5) {
        if isResizing || isInteractingWithChrome || isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
            return
        }
        hideTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideControls()
        }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Schedule idle hide only when the pointer has left video + strip.
    private func scheduleHideControlsIfPointerLeft(after delay: TimeInterval = 2.5) {
        if isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
            keepChromeVisibleForInteraction()
            return
        }
        scheduleHideControls(after: delay)
    }

    private func hideControls() {
        guard isHovering else { return }
        if isResizing || isInteractingWithChrome || isPointerOverChrome() {
            // Pointer returned (or still on strip/grips) — restore solid chrome, no flicker.
            hideTimer = nil
            keepChromeVisibleForInteraction()
            return
        }
        isHovering = false
        setStripChromeVisible(false, animated: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            titleBarView.animator().alphaValue = 0
            resizeIndicator?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.isHovering else { return }
            if let view = self.contentView { self.invalidateCursorRects(for: view) }
        })
    }

    /// Fade the external strip. When hidden, ignore mouse so the band does not
    /// block the IDE; cursor polling still reveals via strip frame hit-test.
    /// Never set ignoresMouseEvents=true while the pointer is over the strip.
    private func setStripChromeVisible(_ visible: Bool, animated: Bool) {
        guard let strip = controlStrip else { return }
        let target: CGFloat = visible ? 1 : 0
        if visible {
            strip.ignoresMouseEvents = false
            strip.acceptsMouseMovedEvents = true
            if isWindowVisible { strip.orderFrontRegardless() }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = visible ? 0.16 : 0.2
                strip.animator().alphaValue = target
            }, completionHandler: { [weak self, weak strip] in
                guard let self = self, let strip = strip else { return }
                if visible {
                    strip.ignoresMouseEvents = false
                    return
                }
                // Click-through only when fully hidden AND pointer is away from chrome.
                if !self.isHovering && !self.isPointerOverChrome() {
                    strip.ignoresMouseEvents = true
                } else {
                    strip.ignoresMouseEvents = false
                    if self.isPointerOverChrome() {
                        self.isHovering = true
                        strip.alphaValue = 1
                    }
                }
            })
        } else {
            strip.alphaValue = target
            if visible {
                strip.ignoresMouseEvents = false
            } else if !isPointerOverChrome() {
                strip.ignoresMouseEvents = true
            } else {
                strip.ignoresMouseEvents = false
            }
        }
    }

    private func makeStripResizeGrip(isLeft: Bool) -> NSView {
        let width = ControlStripPanel.resizeEdgeWidth
        let grip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 58))
        grip.wantsLayer = true
        grip.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor

        let pillW: CGFloat = 5
        let pillH: CGFloat = 22
        let pill = NSView(frame: NSRect(
            x: isLeft ? 10 : width - 10 - pillW,
            y: (58 - pillH) / 2,
            width: pillW,
            height: pillH
        ))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 1, alpha: 0.38).cgColor
        pill.layer?.cornerRadius = pillW / 2
        pill.autoresizingMask = [.minYMargin, .maxYMargin]
        grip.addSubview(pill)
        grip.toolTip = "Kéo để đổi kích thước"
        return grip
    }

    private func makeTextChip(title: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 52, height: 26))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        btn.layer?.cornerRadius = 7
        btn.title = title
        btn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        return btn
    }

    private func makeSizePresetChip(_ preset: SizePreset) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 7
        btn.title = preset.chipTitle
        btn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        btn.contentTintColor = .white
        btn.target = self
        btn.action = #selector(sizePresetChipClicked(_:))
        let chips: [SizePreset] = [.mini, .standard, .wide]
        btn.tag = chips.firstIndex(of: preset) ?? 0
        btn.toolTip = "Cỡ \(preset.chipTitle.lowercased())"
        return btn
    }

    @objc private func sizePresetChipClicked(_ sender: NSButton) {
        let presets: [SizePreset] = [.mini, .standard, .wide]
        let idx = sender.tag
        guard presets.indices.contains(idx) else { return }
        applySizePreset(presets[idx])
    }

    func applySizePreset(_ preset: SizePreset) {
        noteStripInteraction()
        selectedSizePreset = preset
        Self.persistSizePreset(preset)
        refreshSizePresetChipStyles()

        isMaximized = false
        setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")

        // Freeze auto-dock briefly so placer does not shrink the new size away.
        presetHoldWorkItem?.cancel()
        autoDockPaused = true
        isResizing = true

        let screen = self.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? frame
        let old = frame
        var targetW: CGFloat
        var targetH: CGFloat
        var origin = old.origin

        if preset == .pocket {
            let maxW = min(vis.width - 32, maxSize.width)
            let maxH = min(vis.height - VibePlacer.stripHeight - 32, maxW / videoAspectRatio)
            targetW = min(maxW, maxH * videoAspectRatio)
            targetH = targetW / videoAspectRatio
            let obstacles = vibeDock.liveObstacles(on: vis)
            if let decision = VibePlacer.bestFrame(
                size: NSSize(width: targetW, height: targetH),
                screen: vis,
                obstacles: obstacles
            ) {
                applyDock(videoFrame: decision.frame, animated: true)
                showHUD("Cỡ Lớn — \(Int(decision.frame.width))×\(Int(decision.frame.height))")
                finishPresetHold()
                return
            }
        } else {
            targetW = preset.targetWidth ?? 500
        }

        let minW = minSize.width
        let maxW = max(maxSize.width, minW)
        targetW = min(max(targetW, minW), maxW)
        if let screen = screen {
            targetW = min(targetW, max(minW, screen.visibleFrame.width - 16))
        }
        targetH = targetW / videoAspectRatio
        if let screen = screen {
            let maxH = max(minW / videoAspectRatio, screen.visibleFrame.height - VibePlacer.stripHeight - 24)
            if targetH > maxH {
                targetH = maxH
                targetW = targetH * videoAspectRatio
            }
        }

        // Keep the nearest screen-corner anchor so the player stays where it was docked.
        let preferRight = old.midX >= vis.midX
        let preferTop = old.midY >= vis.midY
        origin.x = preferRight ? old.maxX - targetW : old.minX
        origin.y = preferTop ? old.maxY - targetH : old.minY
        origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - targetW - 4)
        origin.y = min(max(origin.y, vis.minY + 4 + VibePlacer.stripHeight), vis.maxY - targetH - 4)

        let newFrame = NSRect(origin: origin, size: NSSize(width: targetW, height: targetH))
        setFrame(newFrame, display: true, animate: false)
        syncControlStrip(animated: false)
        layoutControlBar()
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
        showHUD("\(preset.chipTitle) — \(Int(targetW))px")
        finishPresetHold()
    }

    private func finishPresetHold() {
        presetHoldWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isResizing = false
            self.autoDockPaused = false
            self.scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
        }
        presetHoldWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func refreshSizePresetChipStyles() {
        let map: [(NSButton?, SizePreset)] = [
            (sizePresetMiniButton, .mini),
            (sizePresetStandardButton, .standard),
            (sizePresetWideButton, .wide),
        ]
        for (button, preset) in map {
            guard let button = button else { continue }
            let on = selectedSizePreset == preset
            button.layer?.backgroundColor = (on ? NSColor.white : NSColor(white: 1.0, alpha: 0.08)).cgColor
            button.contentTintColor = on ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.92, alpha: 1)
        }
    }

    // MARK: - Auto next episode / skip intro

    var isAutoNextEpisodeEnabled: Bool { Self.preferredAutoNextEpisode }
    var isAutoSkipIntroEnabled: Bool { Self.preferredAutoSkipIntro }

    @objc func toggleAutoNextEpisode() {
        let next = Self.setPreferredAutoNextEpisode(!Self.preferredAutoNextEpisode)
        refreshWatchAssistButtonStyles()
        showHUD(next ? "Tự chuyển tập: Bật" : "Tự chuyển tập: Tắt")
        noteStripInteraction()
    }

    @objc func toggleAutoSkipIntro() {
        let next = Self.setPreferredAutoSkipIntro(!Self.preferredAutoSkipIntro)
        refreshWatchAssistButtonStyles()
        showHUD(next ? "Tự bỏ GT: Bật" : "Tự bỏ GT: Tắt")
        noteStripInteraction()
    }

    @objc func manualSkipIntro() {
        // Option-click toggles auto preference instead of seeking.
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            toggleAutoSkipIntro()
            return
        }
        noteStripInteraction()
        let end = introEndSeconds(forDuration: max(playbackDuration, 600))
        userSeekedThisEpisode = true
        didAutoSkipIntroThisEpisode = true
        if let slug = movieContext?.slug {
            Self.rememberIntroEnd(end, forSlug: slug)
        }
        seekTo(seconds: end)
        showHUD("Đã bỏ qua giới thiệu")
    }

    private func introEndSeconds(forDuration duration: Double) -> Double {
        let slug = movieContext?.slug ?? ""
        if let remembered = Self.rememberedIntroEnd(forSlug: slug) {
            return min(remembered, max(30, duration * 0.15))
        }
        return min(Self.defaultIntroSeconds, max(30, duration * 0.15))
    }

    /// Called from vibe-sync / HTTP API after toggling prefs.
    func refreshWatchAssistFromAPI() {
        refreshWatchAssistButtonStyles()
        layoutControlBar()
    }

    private func refreshWatchAssistButtonStyles() {
        if let btn = stripAutoNextButton {
            let on = Self.preferredAutoNextEpisode
            setButtonSymbol(btn, on ? "forward.end.alt.fill" : "forward.end.alt")
            btn.contentTintColor = on ? NSColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1) : .white
            btn.toolTip = on
                ? "Tự chuyển tập: Bật — bấm để tắt"
                : "Tự chuyển tập: Tắt — bấm để bật"
            btn.isHidden = true
        }
        if let btn = stripSkipIntroButton {
            let on = Self.preferredAutoSkipIntro
            btn.contentTintColor = on ? NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1) : .white
            btn.toolTip = on
                ? "Bỏ qua GT (bấm). ⌥+bấm: tắt tự động"
                : "Bỏ qua GT (bấm). ⌥+bấm: bật tự động"
            btn.isHidden = true
        }
    }

    private func resetEpisodeWatchAssistState() {
        didAutoSkipIntroThisEpisode = false
        userSeekedThisEpisode = false
        didAutoAdvanceThisEpisode = false
        lastPlaybackSample = 0
    }

    private func handleWatchAssist(currentTime ct: Double, duration dur: Double, paused: Bool, ended: Bool = false) {
        // The page we just left still reports "at the credits" for a moment.
        // Acting on that sample skips the episode that is trying to start.
        guard !suppressWatchAssist else { return }
        // Detect manual seeks (scrub / skip) so auto-intro does not fight the user.
        if lastPlaybackSample > 0, abs(ct - lastPlaybackSample) > 3.5, abs(ct - lastPlaybackSample) < 600 {
            // Large jump while playing usually means seek (not episode reload).
            if ct + 1 < lastPlaybackSample || ct > lastPlaybackSample + 4 {
                userSeekedThisEpisode = true
            }
        }
        lastPlaybackSample = ct

        let playing = !paused || ended
        guard playing, dur.isFinite, dur > 1 else { return }

        // Auto skip intro — once per episode, long-form only.
        if Self.preferredAutoSkipIntro,
           !didAutoSkipIntroThisEpisode,
           !userSeekedThisEpisode,
           movieContext != nil,
           dur >= Self.minEpisodeSecondsForIntroSkip {
            let introEnd = introEndSeconds(forDuration: dur)
            if ct >= 0.8, ct < introEnd - 1 {
                didAutoSkipIntroThisEpisode = true
                seekTo(seconds: introEnd)
                showHUD("Đã bỏ qua giới thiệu")
                return
            }
            if ct >= introEnd {
                didAutoSkipIntroThisEpisode = true
            }
        }

        // Skip the end credits and next-episode preview, then open the next one.
        guard Self.preferredAutoNextEpisode,
              movieContext?.hasPlaylist == true,
              !didAutoAdvanceThisEpisode else { return }
        let watchedEnough = ct > max(Self.defaultIntroSeconds + 30, dur * 0.5)
        let inOutro = dur >= Self.minEpisodeSecondsForIntroSkip && ct >= dur - Self.defaultOutroSeconds
        let fileEnded = ended && ct > 60
        if watchedEnough && (inOutro || fileEnded) {
            didAutoAdvanceThisEpisode = true
            NSLog("[FloatVideo] Skip outro ct=\(Int(ct)) dur=\(Int(dur)) ended=\(ended)")
            showHUD("Đã bỏ qua giới thiệu cuối")
            _ = switchEpisode(by: 1)
        }
    }

    private func layoutControlBar() {
        guard let controlBar = controlBarView else { return }
        let w = controlBar.bounds.width
        let barH = max(controlBar.bounds.height, VibePlacer.stripHeight)
        let inset: CGFloat = 14
        let rowY: CGFloat = 8
        let rowH: CGFloat = 32

        // Timeline is its own row so the thumb and the clock stay easy to hit.
        let timeW: CGFloat = 92
        timeLabel?.isHidden = false
        timeLabel?.alignment = .right
        timeLabel?.frame = NSRect(x: w - inset - timeW, y: barH - 26, width: timeW, height: 18)
        let scrubX = inset
        let scrubW = max(48, timeLabel!.frame.minX - 8 - scrubX)
        scrubberView?.frame = NSRect(x: scrubX, y: barH - 30, width: scrubW, height: 22)

        // Magnify, speed and maximize stay in the ••• menu.
        sizeUpButton?.isHidden = true
        sizeDownButton?.isHidden = true
        stripSkipIntroButton?.isHidden = true
        stripAutoNextButton?.isHidden = true
        maximizeButton?.isHidden = true
        speedButton?.isHidden = true

        // Size chips and the menu are reserved first, so a narrow strip
        // cannot push them off the bar.
        let reservedRight: CGFloat = 28 + 8 + 44 + 3 + 44 + 3 + 44 + 10 + 28 + 4 + 28 + 4 + 28 + inset
        let leftLimit = max(inset + 36, w - reservedRight)

        var x: CGFloat = inset
        func placeLeft(_ button: NSButton?, width: CGFloat, show: Bool = true, gap: CGFloat = 4) {
            guard let button = button else { return }
            guard show, x + width <= leftLimit else {
                button.isHidden = true
                return
            }
            button.isHidden = false
            let bh = min(rowH, button == playPauseButton ? 32 : 26)
            button.frame = NSRect(x: x, y: rowY + (rowH - bh) / 2, width: width, height: bh)
            x += width + gap
        }

        let hasEpNav = movieContext?.hasPlaylist == true
        placeLeft(playPauseButton, width: 32, gap: 10)
        placeLeft(rewindButton, width: 30)
        placeLeft(skipButton, width: 30, gap: 8)
        placeLeft(stripPrevEpisodeButton, width: 52, show: hasEpNav)
        placeLeft(stripNextEpisodeButton, width: 44, show: hasEpNav, gap: 8)
        placeLeft(volumeButton, width: 28)

        var right = w - inset
        func placeRight(_ button: NSButton?, width: CGFloat, gap: CGFloat = 4) {
            guard let button = button else { return }
            right -= width
            button.isHidden = false
            button.frame = NSRect(x: right, y: rowY + (rowH - 26) / 2, width: width, height: 26)
            right -= gap
        }

        placeRight(stripCloseButton, width: 28, gap: 8)
        placeRight(stripGhostButton, width: 28)
        placeRight(stripDuckButton, width: 28, gap: 10)
        placeRight(sizePresetWideButton, width: 44, gap: 3)
        placeRight(sizePresetStandardButton, width: 44, gap: 3)
        placeRight(sizePresetMiniButton, width: 44, gap: 8)
        placeRight(stripMoreButton, width: 28, gap: 4)

        let showSlider = right - 64 >= x + 4
        volumeSlider?.isHidden = !showSlider
        if showSlider {
            volumeSlider?.frame = NSRect(x: x, y: rowY + 6, width: min(84, right - x - 8), height: 20)
        }
        controlBarView.window?.invalidateCursorRects(for: controlBarView)
    }

    private func makePrimaryPlayButton(action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.white.cgColor
        btn.layer?.cornerRadius = 16
        btn.layer?.borderWidth = 0
        btn.contentTintColor = NSColor(white: 0.08, alpha: 1)
        btn.target = self
        btn.action = action
        if let img = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Phát/Tạm dừng") {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
            btn.imagePosition = .imageOnly
        }
        return btn
    }

    private func makeControlButton(symbolName: String, action: Selector, pointSize: CGFloat = 13) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.layer?.cornerRadius = 8
        btn.contentTintColor = NSColor(white: 0.95, alpha: 1.0)
        btn.target = self
        btn.action = action
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
            btn.imagePosition = .imageOnly
        } else {
            btn.title = symbolName
            btn.font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        }
        return btn
    }

    private func setButtonSymbol(_ btn: NSButton, _ symbolName: String, pointSize: CGFloat? = nil) {
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let ps = pointSize ?? ((btn == playPauseButton) ? 15 : 13)
            let config = NSImage.SymbolConfiguration(pointSize: ps, weight: (btn == playPauseButton) ? .bold : .semibold)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
        } else {
            btn.title = symbolName
        }
    }

    private func videoJS(_ directJS: String, youtubeCmd: String? = nil, jwAction: String? = nil) {
        var js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            if (v) {
                \(directJS)
            } else if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    \(jwAction ?? "")
                } catch(e) {}
            }
        """
        if let cmd = youtubeCmd {
            js += """
            else if (window.playerCommand) {
                \(cmd)
            }
            """
        }
        js += "})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func togglePlayPause() {
        if isPlaying {
            videoJS("v.pause()",
                    youtubeCmd: "playerCommand('pause')",
                    jwAction: "jw.pause()")
            isPlaying = false
        } else {
            videoJS("v.play().catch(()=>{})",
                    youtubeCmd: "playerCommand('play')",
                    jwAction: "jw.play()")
            isPlaying = true
        }
        setButtonSymbol(playPauseButton, isPlaying ? "pause.fill" : "play.fill")
    }

    @objc func skipBackward() {
        userSeekedThisEpisode = true
        videoJS("v.currentTime = Math.max(0, v.currentTime - 10)",
                youtubeCmd: "playerCommand('seek', Math.max(0, (window.getPlayerState()?.ct||0)-10))",
                jwAction: "jw.seek(Math.max(0, (jw.getPosition()||0) - 10))")
    }

    @objc func skipForward() {
        userSeekedThisEpisode = true
        videoJS("v.currentTime = Math.min(v.duration || 999999, v.currentTime + 10)",
                youtubeCmd: "playerCommand('seek', (window.getPlayerState()?.ct||0)+10)",
                jwAction: "jw.seek((jw.getPosition()||0) + 10)")
    }

    @objc func toggleMute() {
        userWantsMute.toggle()
        if userWantsMute {
            videoJS("v.muted = true",
                    youtubeCmd: "playerCommand('mute')",
                    jwAction: "jw.setMute(true)")
            setButtonSymbol(volumeButton, "speaker.slash.fill")
            volumeSlider.doubleValue = 0
        } else {
            videoJS("v.muted = false; v.volume = 1.0",
                    youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)",
                    jwAction: "jw.setMute(false); jw.setVolume(100)")
            setButtonSymbol(volumeButton, "speaker.wave.2.fill")
            volumeSlider.doubleValue = 1.0
        }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        let vol = sender.doubleValue
        let muted = vol == 0
        videoJS("v.volume = \(vol); v.muted = \(muted)",
                youtubeCmd: "playerCommand('volume', \(vol)); playerCommand(\(muted ? "'mute'" : "'unmute'"))",
                jwAction: "jw.setVolume(\(Int(vol * 100))); jw.setMute(\(muted))")
        userWantsMute = muted
        setButtonSymbol(volumeButton, userWantsMute ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    func adjustVolume(by delta: Double) {
        let current = userWantsMute ? 0 : volumeSlider.doubleValue
        let newVol = max(0, min(1.0, current + delta))
        volumeSlider.doubleValue = newVol
        volumeChanged(volumeSlider)
    }

    @objc func cyclePlaybackRate() {
        currentRateIndex = (currentRateIndex + 1) % playbackRates.count
        let rate = playbackRates[currentRateIndex]
        let rateStr = (rate == 1.0) ? "1.0x" : (rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate)).0x" : "\(rate)x")
        speedButton.title = rateStr
        videoJS("v.playbackRate = \(rate)",
                youtubeCmd: "playerCommand('setPlaybackRate', \(rate))",
                jwAction: "jw.setPlaybackRate(\(rate))")
    }

    @objc func toggleMaximize() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        if isMaximized {
            isMaximized = false
            setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")
            if preMaximizeFrame != .zero && vis.intersects(preMaximizeFrame) {
                applyDock(videoFrame: preMaximizeFrame, animated: true)
            } else {
                let defaultW: CGFloat = 640
                let defaultH = defaultW / videoAspectRatio
                let frame = NSRect(
                    x: vis.maxX - defaultW - 24,
                    y: vis.maxY - defaultH - 24,
                    width: defaultW,
                    height: defaultH
                )
                applyDock(videoFrame: frame, animated: true)
                placeAwayFromCode()
            }
        } else {
            isMaximized = true
            preMaximizeFrame = self.frame
            setButtonSymbol(maximizeButton, "arrow.down.right.and.arrow.up.left")
            // Fit the largest size that still clears coding/input pockets when possible.
            let maxWidth = min(vis.width - 48, maxSize.width)
            let maxHeight = min(vis.height - 48 - VibePlacer.stripHeight, maxWidth / videoAspectRatio)
            var targetW = maxHeight * videoAspectRatio
            var targetH = maxHeight
            if targetW > maxWidth {
                targetW = maxWidth
                targetH = targetW / videoAspectRatio
            }
            let obstacles = vibeDock.liveObstacles(on: vis)
            if let decision = VibePlacer.bestFrame(
                size: NSSize(width: targetW, height: targetH),
                screen: vis,
                obstacles: obstacles
            ), decision.isClear {
                applyDock(videoFrame: decision.frame, animated: true)
            } else if let decision = VibePlacer.bestFrame(
                size: NSSize(width: min(targetW, 720), height: min(targetW, 720) / videoAspectRatio),
                screen: vis,
                obstacles: obstacles
            ), decision.isClear {
                applyDock(videoFrame: decision.frame, animated: true)
            } else {
                // No pocket for a large player — use coding-safe corner instead of covering the IDE.
                isMaximized = false
                setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")
                let preferred = NSRect(
                    x: vis.maxX - 400 - 14,
                    y: vis.maxY - 400 / videoAspectRatio - 14,
                    width: 400,
                    height: 400 / videoAspectRatio
                )
                applyCodingSafeMode(preferred: preferred)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.layoutControlBar()
            self?.syncControlStrip(animated: true)
        }
    }

    @objc func applySizePresetMini() { applySizePreset(.mini) }
    @objc func applySizePresetStandard() { applySizePreset(.standard) }
    @objc func applySizePresetWide() { applySizePreset(.wide) }
    @objc func applySizePresetPocket() { applySizePreset(.pocket) }

    @objc func growWindow() {
        adjustWindowScale(by: 1.18)
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    @objc func shrinkWindow() {
        adjustWindowScale(by: 1.0 / 1.18)
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    /// Scale the floating window while keeping aspect ratio and staying on-screen.
    @discardableResult
    func adjustWindowScale(by factor: CGFloat) -> NSSize {
        guard factor > 0 else { return frame.size }
        isMaximized = false
        setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")

        let minW = minSize.width
        let maxW = max(maxSize.width, minW)
        var newW = frame.width * factor
        newW = min(max(newW, minW), maxW)
        var newH = newW / videoAspectRatio

        if let screen = screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            let maxFitW = max(minW, vis.width - 16)
            let maxFitH = max(minW / videoAspectRatio, vis.height - VibePlacer.stripHeight - 24)
            if newW > maxFitW {
                newW = maxFitW
                newH = newW / videoAspectRatio
            }
            if newH > maxFitH {
                newH = maxFitH
                newW = newH * videoAspectRatio
            }
        }

        var newFrame = frame
        // Grow/shrink from the center so the window feels anchored in place.
        newFrame.origin.x += (frame.width - newW) / 2
        newFrame.origin.y += (frame.height - newH) / 2
        newFrame.size = NSSize(width: newW, height: newH)

        if let screen = screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            newFrame.origin.x = min(max(newFrame.origin.x, vis.minX + 4), vis.maxX - newFrame.width - 4)
            newFrame.origin.y = min(max(newFrame.origin.y, vis.minY + 4 + VibePlacer.stripHeight), vis.maxY - newFrame.height - 4)
        }

        setFrame(newFrame, display: true, animate: false)
        syncControlStrip(animated: false)
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
        layoutControlBar()
        return newFrame.size
    }

    /// Absolute width setter used by vibe-sync / API (`height` follows aspect ratio).
    @discardableResult
    func setWindowWidth(_ width: CGFloat) -> NSSize {
        guard width > 0 else { return frame.size }
        let factor = width / max(frame.width, 1)
        return adjustWindowScale(by: factor)
    }

    private func seekTo(percent: Double) {
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            if (v && v.duration) {
                v.currentTime = v.duration * \(percent);
            } else if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var dur = window.jwplayer().getDuration();
                    if (dur > 0) window.jwplayer().seek(dur * \(percent));
                } catch(e) {}
            } else if (window.getPlayerState && window.playerCommand) {
                var s = window.getPlayerState();
                if (s && s.dur) playerCommand('seek', s.dur * \(percent));
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func seekTo(seconds: Double) {
        let safe = max(0, seconds)
        let js = """
        (function() {
            var t = \(safe);
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            if (v && isFinite(v.duration)) {
                v.currentTime = Math.min(t, Math.max(0, v.duration - 0.25));
            } else if (window.jwplayer && typeof window.jwplayer === 'function') {
                try { window.jwplayer().seek(t); } catch(e) {}
            } else if (window.playerCommand) {
                playerCommand('seek', t);
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Control Bar State Polling

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollVideoState()
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func pollVideoState() {
        let generation = loadGeneration
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            if (v) {
                var tc = window.__floatVideoPendingTrustedClick || null;
                window.__floatVideoPendingTrustedClick = null;
                var mp = document.querySelector('#movie_player, .html5-video-player');
                var ads = !!(mp && (mp.classList.contains('ad-showing') ||
                                    mp.classList.contains('ad-interrupting')));
                var dur = v.duration;
                if (!isFinite(dur) || dur < 1) {
                    try {
                        if (v.seekable && v.seekable.length) {
                            dur = v.seekable.end(v.seekable.length - 1);
                        }
                    } catch (e) {}
                }
                return { ct: v.currentTime || 0, dur: (isFinite(dur) ? dur : 0), vol: v.volume, muted: v.muted, paused: v.paused,
                         ended: !!v.ended,
                         streamFailed: !!window.__floatStreamFailed,
                         skips: window.__floatVideoAdSkipCount || 0,
                         ff: window.__floatVideoAdFFCount || 0,
                         adSkipInstalled: !!window.__floatVideoAdSkipInstalled,
                         tc: tc, ads: ads };
            }
            if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    var state = jw.getState();
                    return {
                        ct: jw.getPosition() || 0,
                        dur: jw.getDuration() || 0,
                        vol: (jw.getVolume() || 100) / 100,
                        muted: jw.getMute() || false,
                        paused: (state !== 'playing' && state !== 'buffering'),
                        skips: 0,
                        ff: 0,
                        adSkipInstalled: true,
                        tc: null,
                        ads: (state === 'ad')
                    };
                } catch(e) {}
            }
            if (window.getPlayerState) return window.getPlayerState();
            return null;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, self.loadGeneration == generation,
                  let dict = result as? [String: Any] else { return }
            if (dict["streamFailed"] as? Bool) == true {
                self.fallbackToEmbedIfDirectFailed()
            }
            let ct = (dict["ct"] as? NSNumber)?.doubleValue ?? 0
            let dur = (dict["dur"] as? NSNumber)?.doubleValue ?? 0
            let vol = (dict["vol"] as? NSNumber)?.doubleValue ?? 1
            let muted = dict["muted"] as? Bool ?? false
            let paused = dict["paused"] as? Bool ?? true
            let ended = dict["ended"] as? Bool ?? false

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

            let adSkipInstalled = dict["adSkipInstalled"] as? Bool ?? true
            if !adSkipInstalled, self.currentSite == "youtube",
               self.loadingStrategy == .fullPageInject {
                self.injectAdSkip()
            }

            if let tc = dict["tc"] as? [String: Any],
               (dict["ads"] as? Bool) == true,
               let px = (tc["x"] as? NSNumber)?.doubleValue,
               let py = (tc["y"] as? NSNumber)?.doubleValue {
                self.performTrustedClick(pageX: px, pageY: py)
            }

            // Update progress bar
            if dur > 0 && !dur.isNaN {
                let fraction = CGFloat(ct / dur)
                self.scrubberView?.setProgress(fraction)
                self.timeLabel.stringValue = "\(self.formatTime(ct)) / \(self.formatTime(dur))"
            } else {
                self.scrubberView?.setProgress(0)
                if self.loadingOverlay != nil {
                    self.timeLabel.stringValue = "Đang tải..."
                } else if ct > 0 {
                    self.timeLabel.stringValue = self.formatTime(ct)
                } else {
                    self.timeLabel.stringValue = "--:--"
                }
            }

            // Sync play state
            self.isPlaying = !paused
            self.playbackElapsed = ct
            self.playbackDuration = dur
            self.handleWatchAssist(currentTime: ct, duration: dur, paused: paused, ended: ended)
            self.setButtonSymbol(self.playPauseButton, paused ? "play.fill" : "pause.fill")
            VibeNowPlaying.update(
                title: self.videoTitle,
                elapsed: ct,
                duration: dur,
                playing: !paused,
                rate: self.playbackRate
            )
            if !paused {
                self.emitProgress(force: false)
            }

            // Mute/volume reconciliation — never force 1.0 while ducked
            let desiredMuted = self.userWantsMute
            self.setButtonSymbol(self.volumeButton, desiredMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            if desiredMuted {
                self.volumeSlider.doubleValue = 0
                if !muted {
                    self.videoJS("v.muted = true", youtubeCmd: "playerCommand('mute')", jwAction: "jw.setMute(true)")
                }
            } else if self.isDucked {
                let duckedVol = self.volumeSlider?.doubleValue ?? max(0.05, self.preDuckVolume * 0.2)
                self.volumeSlider.doubleValue = duckedVol
                if muted || abs(vol - duckedVol) > 0.08 {
                    self.videoJS("v.muted = false; v.volume = \(duckedVol)",
                                 youtubeCmd: "playerCommand('unmute'); playerCommand('volume', \(duckedVol))",
                                 jwAction: "jw.setMute(false); jw.setVolume(\(Int(duckedVol * 100)))")
                }
            } else {
                self.volumeSlider.doubleValue = max(vol, 0.01)
                if muted || vol == 0 {
                    self.videoJS("v.muted = false; v.volume = 1.0",
                                 youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)",
                                 jwAction: "jw.setMute(false); jw.setVolume(100)")
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
        // Cycle: full → soft (coding) → dim → full
        let current = self.alphaValue
        if current > 0.9 {
            self.alphaValue = 0.72
        } else if current > 0.58 {
            self.alphaValue = 0.45
        } else {
            self.alphaValue = 1.0
        }
        if !isGhostMode {
            preGhostAlpha = self.alphaValue
        }
        UserDefaults.standard.set(Double(self.alphaValue), forKey: Self.opacityPrefKey)
    }

    @objc func play() {
        if !isPlaying { togglePlayPause() }
    }

    @objc func pause() {
        if isPlaying { togglePlayPause() }
    }

    @objc func duckVolume() {
        if !isDucked {
            preDuckVolume = volumeSlider?.doubleValue ?? 1.0
            let ducked = max(0.05, preDuckVolume * 0.2)
            volumeSlider?.doubleValue = ducked
            if let slider = volumeSlider { volumeChanged(slider) }
            isDucked = true
            showHUD("Đã hạ tiếng")
            NSLog("[FloatVideo] Audio ducked to 20% for AI review")
        }
    }

    @objc func unduckVolume() {
        if isDucked {
            volumeSlider?.doubleValue = preDuckVolume
            if let slider = volumeSlider { volumeChanged(slider) }
            isDucked = false
            showHUD("Khôi phục âm lượng")
            NSLog("[FloatVideo] Audio restored to 100%")
        }
    }

    private func applyPreferredGhostOnOpen() {
        setGhostMode(Self.preferredGhostMode, persist: false)
        if let saved = UserDefaults.standard.object(forKey: Self.opacityPrefKey) as? Double {
            // Ignore near-invisible saved values that make the player seem "gone".
            setOpacity(max(0.5, saved))
        }
    }

    /// Solid opacity for a clickable player — never the coding-safe / ghost soft values.
    private static func preferredSolidOpacity(fallback: CGFloat) -> CGFloat {
        if let saved = UserDefaults.standard.object(forKey: opacityPrefKey) as? Double {
            let v = CGFloat(saved)
            if v >= 0.9 { return min(1.0, v) }
        }
        if fallback >= 0.9 { return min(1.0, fallback) }
        return 1.0
    }

    func setGhostMode(_ enabled: Bool, persist: Bool = true) {
        isGhostMode = enabled
        // Only the video window passes clicks through. The control strip stays live.
        self.ignoresMouseEvents = enabled
        if enabled {
            if self.alphaValue > 0.9 {
                preGhostAlpha = 1.0
                self.alphaValue = 0.72
            } else {
                preGhostAlpha = max(self.alphaValue, 0.45)
            }
            if let stripGhostButton {
                setButtonSymbol(stripGhostButton, "eye.slash")
                stripGhostButton.contentTintColor = NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)
            }
            stripGhostButton?.toolTip = "Đang xuyên chuột"
        } else {
            // User wants a solid, clickable picture. Restore full/preferred opacity —
            // do not leave coding-safe washout (~0.55) even if layout stays shrunk.
            let solid = Self.preferredSolidOpacity(fallback: preGhostAlpha)
            self.alphaValue = solid
            preGhostAlpha = solid
            if let stripGhostButton {
                setButtonSymbol(stripGhostButton, "eye")
                stripGhostButton.contentTintColor = .white
            }
            stripGhostButton?.toolTip = "Xuyên chuột"
            // Keep isCodingSafeMode for size/placement; opacity follows ghost preference.
        }
        mountControlStrip()
        syncControlStrip(animated: false)
        if persist {
            Self.setPreferredGhostMode(enabled)
        }
    }

    @objc func toggleGhostMode() {
        setGhostMode(!isGhostMode, persist: true)
    }

    /// No clear pocket over the IDE — shrink, soften, park in least-bad corner.
    /// Suggests ghost only on enter when preferredGhostMode is true; never re-forces
    /// ghost on later dock ticks so a manual OFF stays OFF.
    func applyCodingSafeMode(preferred: NSRect) {
        let entering = !isCodingSafeMode
        if entering {
            preSafeFrame = frame
            preSafeAlpha = alphaValue
            // Suggest click-through once when entering, only if user still prefers it.
            if Self.preferredGhostMode && !isGhostMode {
                setGhostMode(true, persist: false)
            }
        }
        isCodingSafeMode = true
        // Soft dim only while ghost/click-through is on. If the user turned ghost
        // OFF for a solid player, keep coding-safe size/placement but do not re-wash.
        if isGhostMode && alphaValue > 0.6 {
            animator().alphaValue = 0.55
        }

        // On first enter, shrink toward a coding-safe width. Later ticks only
        // reposition — never undo a manual +/- or strip-edge resize.
        let codingCap = max(minSize.width, 380)
        var targetW = entering
            ? min(max(preferred.width, minSize.width), codingCap)
            : max(frame.width, minSize.width)
        var targetH = targetW / videoAspectRatio
        if let screen = screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            let maxH = max(minSize.height, vis.height * 0.34)
            if targetH > maxH {
                targetH = maxH
                targetW = targetH * videoAspectRatio
            }
            var frame = NSRect(
                x: preferred.midX - targetW / 2,
                y: preferred.midY - targetH / 2,
                width: targetW,
                height: targetH
            )
            // Prefer the upper corners so the caret/input band stays free.
            let corners = [
                NSPoint(x: vis.maxX - targetW - 14, y: vis.maxY - targetH - 14),
                NSPoint(x: vis.minX + 14, y: vis.maxY - targetH - 14),
                NSPoint(x: vis.maxX - targetW - 14, y: vis.minY + VibePlacer.stripHeight + 20),
                NSPoint(x: vis.minX + 14, y: vis.minY + VibePlacer.stripHeight + 20),
            ]
            let obstacles = vibeDock.liveObstacles(on: vis)
            let ranked = corners.map { origin -> (NSRect, CGFloat) in
                let candidate = NSRect(origin: origin, size: NSSize(width: targetW, height: targetH))
                let foot = VibePlacer.footprint(video: candidate, screen: vis)
                let overlap = obstacles.reduce(CGFloat(0)) { sum, o in
                    sum + max(0, foot.intersection(o.frame.insetBy(dx: -o.pad, dy: -o.pad)).width)
                        * max(0, foot.intersection(o.frame.insetBy(dx: -o.pad, dy: -o.pad)).height)
                        * o.weight
                }
                return (candidate, -overlap)
            }.sorted { $0.1 > $1.1 }
            frame = ranked.first?.0 ?? frame
            applyDock(videoFrame: frame, animated: true)
        } else {
            applyDock(videoFrame: preferred, animated: true)
        }
        if entering {
            showHUD("Coding-safe — thu nhỏ để chừa chỗ gõ")
            NSLog("[FloatVideo] Coding-safe mode: shrink + soft opacity (ghost preferred=\(Self.preferredGhostMode))")
        }
    }

    func exitCodingSafeModeIfClear() {
        guard isCodingSafeMode else { return }
        isCodingSafeMode = false
        let restore = preSafeFrame
        preSafeFrame = .zero
        if restore.width >= minSize.width && restore.height >= minSize.height {
            applyDock(videoFrame: restore, animated: true)
        }
        // Keep ghost preference; restore opacity — solid when ghost is off.
        if isGhostMode {
            if let saved = UserDefaults.standard.object(forKey: Self.opacityPrefKey) as? Double {
                animator().alphaValue = CGFloat(max(0.45, saved))
            } else {
                animator().alphaValue = max(preSafeAlpha, 0.72)
            }
        } else {
            animator().alphaValue = Self.preferredSolidOpacity(fallback: preSafeAlpha)
        }
        showHUD("Đã phóng lại kích thước trước")
    }

    @objc func togglePin() {
        isPinned.toggle()
        (titleBarView as? DraggableTitleBar)?.isLocked = isPinned
        pinButton?.alphaValue = isPinned ? 1 : 0.45
        pinButton?.toolTip = isPinned ? "Đang ghim — bấm để tự né lại" : "Ghim vị trí — không tự né cửa sổ code"
        if !isPinned { vibeDock.attach(self) }
    }

    @objc func toggleDuck() {
        if isDucked { unduckVolume() } else { duckVolume() }
        if let stripDuckButton {
            setButtonSymbol(stripDuckButton, isDucked ? "ear.fill" : "ear")
            stripDuckButton.contentTintColor = isDucked ? NSColor(red: 1, green: 0.23, blue: 0.36, alpha: 1) : .white
        }
    }

    // MARK: - HUD / Progress / Episodes

    func showHUD(_ message: String, duration: TimeInterval = 1.6) {
        guard let hud = hudToast, let container = contentView else {
            NSLog("[FloatVideo] HUD: \(message)")
            return
        }
        let maxWidth = max(120, container.bounds.width - 24)
        hud.present(message, symbol: Self.toastSymbol(for: message), maxWidth: maxWidth)
        hud.isHidden = false
        let y = container.bounds.height - 30 - 10 - hud.frame.height
        hud.frame.origin = CGPoint(
            x: max(12, (container.bounds.width - hud.frame.width) / 2),
            y: max(12, y)
        )
        hud.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hud.animator().alphaValue = 1
        })
        hudHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let hud = self?.hudToast else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                hud.animator().alphaValue = 0
            }, completionHandler: {
                hud.isHidden = true
            })
        }
        hudHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func toastSymbol(for message: String) -> String {
        let text = message.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi")).lowercased()
        if text.contains("quang cao") { return "forward.fill" }
        if text.contains("gioi thieu") || text.contains("bo gt") { return "forward.end" }
        if text.contains("tap") || text.contains("mua") { return "film" }
        if text.contains("tieng") || text.contains("am luong") { return "speaker.wave.2.fill" }
        if text.contains("coding") || text.contains("phong lai") { return "arrow.down.right.and.arrow.up.left" }
        if text.contains("loi") || text.contains("phim tat") { return "exclamationmark.circle" }
        if text.contains("nguon") { return "arrow.triangle.2.circlepath" }
        if text.contains("nho") || text.contains("vua") || text.contains("rong") || text.contains("lon") || text.contains("px") {
            return "aspectratio"
        }
        return "checkmark.circle"
    }

    func emitProgress(force: Bool) {
        guard movieContext != nil || playbackElapsed > 0 else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastProgressSentAt) < progressHeartbeatInterval {
            return
        }
        lastProgressSentAt = now
        let payload = progressPayload()
        guard !payload.isEmpty else { return }
        onProgress?(payload)
    }

    func progressPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "type": "PROGRESS",
            "currentTime": playbackElapsed,
            "duration": playbackDuration,
        ]
        if let ctx = movieContext {
            payload["slug"] = ctx.slug
            payload["name"] = ctx.name
            payload["source"] = ctx.source
            payload["poster"] = ctx.poster
            payload["serverIdx"] = ctx.serverIdx
            payload["epIdx"] = ctx.epIdx
            if let ep = ctx.currentEpisode {
                payload["epName"] = ep.name
                payload["epSlug"] = ep.slug
                payload["linkM3u8"] = ep.linkM3u8
                payload["linkEmbed"] = ep.linkEmbed
            }
        } else {
            payload["name"] = videoTitle
            payload["linkEmbed"] = currentEmbedUrl ?? ""
            payload["linkM3u8"] = ""
        }
        return payload
    }

    private func updateEpisodeButtons() {
        let hasNav = movieContext?.hasPlaylist == true
        stripPrevEpisodeButton?.isHidden = !hasNav
        stripNextEpisodeButton?.isHidden = !hasNav
        if let ctx = movieContext, let server = ctx.servers[safe: ctx.serverIdx] {
            stripPrevEpisodeButton?.isEnabled = ctx.epIdx > 0
            stripNextEpisodeButton?.isEnabled = ctx.epIdx + 1 < server.items.count
        }
        layoutControlBar()
    }

    @objc func prevEpisode() {
        switchEpisode(by: -1)
    }

    @objc func nextEpisode() {
        switchEpisode(by: 1)
    }

    @discardableResult
    func switchEpisode(by delta: Int) -> Bool {
        guard var ctx = movieContext else {
            showHUD("Không có danh sách tập")
            return false
        }
        guard let ep = ctx.moveEpisode(by: delta) else {
            showHUD(delta < 0 ? "Đã ở tập đầu" : "Hết mùa / hết danh sách")
            return false
        }
        movieContext = ctx
        reloadEpisode(ep, context: ctx)
        return true
    }

    private func reloadEpisode(_ ep: MovieEpisodeItem, context: MovieContext) {
        emitProgress(force: true)
        videoTitle = context.name.isEmpty ? ep.name : "\(context.name) — \(ep.name)"
        titleLabel?.stringValue = videoTitle
        currentVideoTime = 0
        playbackElapsed = 0
        playbackDuration = 0
        hasInjectedJS = false
        resetEpisodeWatchAssistState()
        updateEpisodeButtons()
        refreshWatchAssistButtonStyles()
        showHUD(ep.name)

        let m3u8 = ep.linkM3u8
        let embed = ep.linkEmbed
        let pageURL = !embed.isEmpty ? embed : currentPageURL
        NSLog("[FloatVideo] Episode \(ep.name) m3u8=\(!m3u8.isEmpty) embed=\(!embed.isEmpty)")
        loadVideo(
            url: pageURL,
            videoSrc: m3u8.isEmpty ? nil : m3u8,
            embedUrl: embed.isEmpty ? nil : embed,
            currentTime: 0,
            site: currentSite == "generic" || currentSite.isEmpty ? "movie" : currentSite,
            httpServerPortProvider: httpServerPortProvider,
            cookies: [],
            playerPrefs: playerPrefs
        )
        // Episode change itself is a progress checkpoint (time 0 on new ep).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.emitProgress(force: true)
        }
    }

    @objc func showOverflowMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "More")
        func item(_ title: String, action: Selector) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            it.target = self
            return it
        }
        menu.addItem(item("Tua −10 giây", action: #selector(skipBackward)))
        menu.addItem(item("Tua +10 giây", action: #selector(skipForward)))
        menu.addItem(item(userWantsMute ? "Bật tiếng" : "Tắt tiếng", action: #selector(toggleMute)))
        menu.addItem(item("Tốc độ phát", action: #selector(cyclePlaybackRate)))
        menu.addItem(item(isMaximized ? "Khôi phục kích thước" : "Phóng tối đa", action: #selector(toggleMaximize)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item(SizePreset.mini.menuTitle, action: #selector(applySizePresetMini)))
        menu.addItem(item(SizePreset.standard.menuTitle, action: #selector(applySizePresetStandard)))
        menu.addItem(item(SizePreset.wide.menuTitle, action: #selector(applySizePresetWide)))
        menu.addItem(item(SizePreset.pocket.menuTitle, action: #selector(applySizePresetPocket)))
        menu.addItem(item("Phóng to (+)", action: #selector(growWindow)))
        menu.addItem(item("Thu nhỏ (−)", action: #selector(shrinkWindow)))
        if movieContext != nil {
            menu.addItem(NSMenuItem.separator())
            let autoNextTitle = Self.preferredAutoNextEpisode ? "✓ Tập sau, bỏ qua cuối phim" : "Tập sau, bỏ qua cuối phim"
            menu.addItem(item(autoNextTitle, action: #selector(toggleAutoNextEpisode)))
            let autoIntroTitle = Self.preferredAutoSkipIntro ? "✓ Tự bỏ qua giới thiệu" : "Tự bỏ qua giới thiệu"
            menu.addItem(item(autoIntroTitle, action: #selector(toggleAutoSkipIntro)))
            menu.addItem(item("Bỏ qua GT ngay", action: #selector(manualSkipIntro)))
        }
        if movieContext?.hasPlaylist == true {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item("Tập trước", action: #selector(prevEpisode)))
            menu.addItem(item("Tập sau", action: #selector(nextEpisode)))
        }
        let point = NSPoint(x: sender.bounds.midX, y: sender.bounds.minY - 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc func setOpacity(_ val: Double) {
        let clamped = max(0.15, min(1.0, CGFloat(val)))
        self.animator().alphaValue = clamped
        if !isGhostMode { preGhostAlpha = clamped }
    }

    @objc func toggleBossHide() {
        if isWindowVisible {
            emitProgress(force: true)
            hideTimer?.cancel()
            hideTimer = nil
            if isPlaying {
                pause()
                pausedForBoss = true
            } else {
                pausedForBoss = false
            }
            controlStrip?.orderOut(nil)
            self.orderOut(nil)
            isWindowVisible = false
            isHovering = false
        } else {
            self.orderFrontRegardless()
            isWindowVisible = true
            syncControlStrip(animated: false)
            showControls()
            scheduleHideControls(after: Self.chromeHideDelay)
            if pausedForBoss {
                play()
                pausedForBoss = false
            }
        }
    }

    func applyDock(videoFrame: NSRect, animated: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduced {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(videoFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.syncControlStrip(animated: false)
            })
        } else {
            setFrame(videoFrame, display: true)
            syncControlStrip(animated: false)
        }
    }

    func syncControlStrip(animated: Bool) {
        guard let strip = controlStrip else { return }
        let target = predictedStripFrame(for: frame)
        if animated {
            strip.animator().setFrame(target, display: true)
        } else {
            strip.setFrame(target, display: true)
        }
        if isWindowVisible { strip.orderFrontRegardless() }
        layoutControlBar()
    }

    private func predictedStripFrame(for video: NSRect) -> NSRect {
        let screen = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? video
        return VibePlacer.stripFrame(video: video, screen: screen)
    }

    private func mountControlStrip() {
        guard let bar = controlBarView else { return }
        if controlStrip != nil {
            syncControlStrip(animated: false)
            return
        }
        bar.removeFromSuperview()
        let panel = ControlStripPanel(
            contentRect: NSRect(x: 0, y: 0, width: frame.width, height: VibePlacer.stripHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.owner = self
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        bar.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: frame.width, height: VibePlacer.stripHeight)
        bar.autoresizingMask = [.width, .height]
        bar.alphaValue = 1
        bar.isHidden = false
        panel.contentView = bar
        // Tracking so mouseMoved delivers edge cursors on the strip.
        if let content = panel.contentView {
            let tracking = NSTrackingArea(
                rect: content.bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: panel,
                userInfo: nil
            )
            content.addTrackingArea(tracking)
        }
        controlStrip = panel
        syncControlStrip(animated: false)
        layoutVideoChrome()
    }

    private func layoutVideoChrome() {
        guard let container = contentView, let webView = webView else { return }
        let bounds = container.bounds
        // Controls live on the external strip — video uses the full panel.
        webView.frame = bounds
        resizeEdgeView?.frame = bounds
        loadingOverlay?.frame = webView.frame
        if titleBarView != nil {
            let titleH = titleBarView.frame.height > 0 ? titleBarView.frame.height : 30
            titleBarView.frame = NSRect(x: 0, y: bounds.height - titleH, width: bounds.width, height: titleH)
        }
    }

    func trackMoveFromStrip() {
        guard !isPinned, let strip = controlStrip else { return }
        autoDockPaused = true
        let startMouse = NSEvent.mouseLocation
        let startOrigin = frame.origin
        strip.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] event, stop in
            guard let self = self, let event = event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let mouse = NSEvent.mouseLocation
            self.setFrameOrigin(NSPoint(
                x: startOrigin.x + mouse.x - startMouse.x,
                y: startOrigin.y + mouse.y - startMouse.y
            ))
            self.syncControlStrip(animated: false)
        }
        autoDockPaused = false
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
    }

    func trackResizeFromStrip() {
        guard let strip = controlStrip else { return }
        noteStripInteraction()
        autoDockPaused = true
        isResizing = true
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = frame
        resizeEdge = NSEvent.mouseLocation.x > frame.midX ? .right : .left
        strip.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] event, stop in
            guard let self = self, let event = event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            self.mouseDragged(with: event)
        }
        isResizing = false
        resizeEdge = .none
        autoDockPaused = false
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    // MARK: - Resize Edge Detection

    private func detectResizeEdge(at point: NSPoint) -> ResizeEdge {
        let w = self.frame.width
        let h = self.frame.height
        let b = resizeBorderWidth

        // The drawn grip is the resize handle, including the part above the thin edge.
        if let grip = resizeIndicator, grip.alphaValue > 0.2,
           grip.frame.insetBy(dx: -8, dy: -8).contains(point) {
            return .bottomRight
        }

        // The playback bar owns the bottom of the window. Don't turn it into a resize edge.
        if isOnPlaybackBar(point), point.x >= b, point.x <= w - b {
            return .none
        }

        let onLeft = point.x < b
        let onRight = point.x > w - b
        let onBottom = point.y < b && !isOnPlaybackBar(point)
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
        case .left, .right, .topLeft, .bottomRight, .topRight, .bottomLeft:
            return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .none: return .arrow
        }
    }

    // MARK: - Event Interception (intercept resize events before WKWebView)

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Synthetic trusted clicks (ad skip) must reach the web view even
            // when they land inside the resize border.
            if isPostingSyntheticClick { break }
            // Pin only blocks auto-dock; allow manual edge/corner resize.
            let location = event.locationInWindow
            if isOnPlaybackBar(location) {
                if !playbackHitIsControl(location) {
                    autoDockPaused = true
                    performDrag(with: event)
                    autoDockPaused = false
                    vibeDock.noteUserDidPlace()
                    return
                }
                break
            }
            let edge = detectResizeEdge(at: location)
            if edge != .none {
                // When title bar is visible, drag takes priority over top-edge resize
                if titleBarView.alphaValue > 0,
                   titleBarView.frame.contains(location) {
                    break // Let DraggableTitleBar handle the drag
                }
                // Ghost mode passes clicks through — edge resize is unavailable on the
                // video panel; strip L/R grips and +/- / hotkeys still resize.
                if isGhostMode { break }
                isResizing = true
                resizeEdge = edge
                initialMouseLocation = NSEvent.mouseLocation
                initialWindowFrame = self.frame
                showControls()
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

    private func isOnPlaybackBar(_ point: NSPoint) -> Bool {
        guard isHovering, let bar = controlBarView, !bar.isHidden, bar.superview != nil, bar.alphaValue > 0.05 else { return false }
        return bar.frame.contains(point)
    }

    private func playbackHitIsControl(_ point: NSPoint) -> Bool {
        guard let container = contentView, let hit = container.hitTest(point) else { return false }
        var view: NSView? = hit
        while let current = view {
            if current === controlBarView { return false }
            if current is NSControl || current is ModernScrubberView { return true }
            view = current.superview
        }
        return false
    }

    private func cursorForPlaybackBar(at point: NSPoint) -> NSCursor {
        playbackHitIsControl(point) ? .pointingHand : .openHand
    }

    override func mouseMoved(with event: NSEvent) {
        let location = event.locationInWindow
        if isOnPlaybackBar(location) {
            cursorForPlaybackBar(at: location).set()
            return
        }
        if titleBarView.alphaValue > 0.05, titleBarView.frame.contains(location) {
            NSCursor.openHand.set()
            return
        }
        let edge = detectResizeEdge(at: location)
        cursorForEdge(edge).set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let loc = event.locationInWindow
            let onControlBar = (controlBarView.alphaValue > 0.1 && controlBarView.frame.contains(loc))
            if !onControlBar {
                toggleMaximize()
                return
            }
        }
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
        let aspect = videoAspectRatio

        // Corner drags follow whichever axis the pointer moved more, then lock aspect.
        func width(fromX: CGFloat, fromY: CGFloat, corner: Bool) -> CGFloat {
            if !corner || abs(deltaX) >= abs(deltaY) { return fromX }
            return fromY
        }
        switch resizeEdge {
        case .right:
            newFrame.size.width = initialWindowFrame.width + deltaX
        case .left:
            newFrame.size.width = initialWindowFrame.width - deltaX
        case .top:
            newFrame.size.width = (initialWindowFrame.height + deltaY) * aspect
        case .bottom:
            newFrame.size.width = (initialWindowFrame.height - deltaY) * aspect
        case .topRight:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width + deltaX,
                fromY: (initialWindowFrame.height + deltaY) * aspect,
                corner: true
            )
        case .bottomRight:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width + deltaX,
                fromY: (initialWindowFrame.height - deltaY) * aspect,
                corner: true
            )
        case .topLeft:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width - deltaX,
                fromY: (initialWindowFrame.height + deltaY) * aspect,
                corner: true
            )
        case .bottomLeft:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width - deltaX,
                fromY: (initialWindowFrame.height - deltaY) * aspect,
                corner: true
            )
        case .none:
            break
        }
        if resizeEdge != .none {
            newFrame.size.height = newFrame.size.width / aspect
        }

        // Enforce min/max size while keeping aspect ratio
        let minW = self.minSize.width
        let maxW = max(self.maxSize.width, minW)
        if newFrame.size.width < minW {
            newFrame.size.width = minW
            newFrame.size.height = minW / videoAspectRatio
        } else if newFrame.size.width > maxW {
            newFrame.size.width = maxW
            newFrame.size.height = maxW / videoAspectRatio
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
        syncControlStrip(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            saveWindowFrame()
            vibeDock.noteUserDidPlace()
        }
        isResizing = false
        resizeEdge = .none
        NSCursor.arrow.set()
        super.mouseUp(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        hideTimer?.cancel()
        showControls()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing {
            NSCursor.arrow.set()
        }
        // Long idle only — short delay raced strip reveal and caused flicker.
        if isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
        } else {
            scheduleHideControls(after: Self.chromeHideDelay)
        }
        super.mouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Option+scroll (or trackpad pinch-like vertical scroll) resizes while hovering.
        // Works when ghost is OFF (video receives events). Ghost ON: use strip +/- or ⌃⌥=/−.
        let wantsResize = event.modifierFlags.contains(.option)
            || detectResizeEdge(at: event.locationInWindow) != .none
        guard wantsResize, !isGhostMode else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.2 else { return }
        let factor: CGFloat = delta > 0 ? 1.06 : (1.0 / 1.06)
        adjustWindowScale(by: factor)
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    // Allow window to become key window + respond to first click
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsMouseMovedEvents: Bool {
        get { true }
        set { super.acceptsMouseMovedEvents = newValue }
    }

    // Comprehensive keyboard shortcuts (Space, Arrows, M, F, J, K, L, Digits 0-9, ESC)
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            if isMaximized {
                toggleMaximize()
            } else {
                closeWindow()
            }
        case 49, 40: // Space, K -> Play/Pause
            togglePlayPause()
            showControls()
            scheduleHideControls(after: 2.0)
        case 123, 38: // Left Arrow, J -> Rewind 10s
            skipBackward()
            showControls()
            scheduleHideControls(after: 2.0)
        case 124, 37: // Right Arrow, L -> Forward 10s
            skipForward()
            showControls()
            scheduleHideControls(after: 2.0)
        case 126: // Up Arrow -> Volume Up
            adjustVolume(by: 0.1)
            showControls()
            scheduleHideControls(after: 2.0)
        case 125: // Down Arrow -> Volume Down
            adjustVolume(by: -0.1)
            showControls()
            scheduleHideControls(after: 2.0)
        case 46: // M -> Mute
            toggleMute()
            showControls()
            scheduleHideControls(after: 2.0)
        case 3: // F -> Fullscreen / Maximize
            toggleMaximize()
        case 5: // G -> Ghost Mode (Click-through)
            toggleGhostMode()
            showControls()
            scheduleHideControls(after: 2.0)
        case 11: // B -> Boss Key (Hide / Show)
            toggleBossHide()
        case 24, 69: // = / keypad + -> grow
            growWindow()
            showControls()
            scheduleHideControls(after: 1.5)
        case 27, 78: // - / keypad - -> shrink
            shrinkWindow()
            showControls()
            scheduleHideControls(after: 1.5)
        default:
            if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), digit >= 0 && digit <= 9 {
                seekTo(percent: Double(digit) / 10.0)
                showControls()
                scheduleHideControls(after: 2.0)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

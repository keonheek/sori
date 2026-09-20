import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Floating panel (Spokenly-style, bottom center)
final class WaveView: NSView {
    var levels: [CGFloat] = Array(repeating: 0.06, count: 28)
    override var isOpaque: Bool { false }   // never paint a white background into corners
    func push(_ level: CGFloat) { levels.removeFirst(); levels.append(max(0.06, level)); needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        let n = levels.count, gap: CGFloat = 4
        let barW = (bounds.width - 32 - gap * CGFloat(n - 1)) / CGFloat(n)
        let midY = bounds.midY, maxH = bounds.height * 0.6
        NSColor(calibratedRed: 0.80, green: 0.18, blue: 0.23, alpha: 1).setFill()
        for (i, lv) in levels.enumerated() {
            let h = max(3, lv * maxH)
            let rect = NSRect(x: 16 + CGFloat(i) * (barW + gap), y: midY - h/2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barW/2, yRadius: barW/2).fill()
        }
    }
}

// Three dots that bob up and down — shown while listening before real speech arrives.
final class DotsView: NSView {
    private var dots: [CALayer] = []
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if dots.isEmpty { setup() }
        if window != nil { start() } else { stop() }
    }
    private func setup() {
        wantsLayer = true
        let r: CGFloat = 4, gap: CGFloat = 8
        let total = r * 2 * 3 + gap * 2
        let startX = (bounds.width - total) / 2
        let cy = bounds.midY - r
        let color = NSColor(calibratedRed: 0.80, green: 0.18, blue: 0.23, alpha: 1).cgColor
        for i in 0..<3 {
            let d = CALayer()
            d.backgroundColor = color
            d.cornerRadius = r
            d.frame = CGRect(x: startX + CGFloat(i) * (r * 2 + gap), y: cy, width: r * 2, height: r * 2)
            layer?.addSublayer(d); dots.append(d)
        }
    }
    func start() {
        for (i, d) in dots.enumerated() {
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = -3; a.toValue = 3
            a.duration = 0.45; a.autoreverses = true; a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.15
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            d.add(a, forKey: "bob")
        }
    }
    func stop() { dots.forEach { $0.removeAllAnimations() } }
}

// A small monochrome equalizer-style bar cluster — the compact panel's "recognizing audio"
// indicator, styled after Wispr Flow's floating widget (feedback from live-testing the panel,
// 2026-07-09: replaced an earlier single red pulsing dot — wanted grayscale, not brand-colored,
// and fluid spring motion rather than a linear resize). Each bar springs to a level-driven
// height with slight per-bar phase/response variation so the motion looks organic, not robotic.
final class LevelBarsView: NSView {
    override var isOpaque: Bool { false }
    private var bars: [CALayer] = []
    private var minH: CGFloat = 2, maxH: CGFloat = 16
    // Current smoothed 0...1 value PER BAR — the whole point is that these drift apart from each
    // other, not a single shared value fanned out (feedback, 2026-07-09: "all five dots move the
    // same way... Wispr Flow does it differently... fluid movement"). Each bar reaches a different
    // peak (responses) via its own independent attack/release RATE (attackRates/releaseRates) —
    // fast snap up, much slower ease down (VU-meter ballistics), with the rates themselves varying
    // bar-to-bar so a real transient visibly ripples through the cluster instead of all 5 jumping
    // in lockstep. This is a single scalar mic level, not real per-band audio data, so decorrelated
    // per-bar TIMING is what has to stand in for genuine frequency-band independence.
    //
    // The rates are TIME CONSTANTS in seconds, not per-callback fractions: the audio tap's buffer
    // size is a hint the system is free to ignore, so a per-callback rate silently changes the
    // ballistics with the hardware. These taus reproduce the original per-push rates at the
    // nominal ~48 Hz callback but now hold at any callback rate.
    private var smoothed: [CGFloat] = []
    private var lastPush: CFTimeInterval = 0
    private let responses:    [CGFloat] = [0.88, 1.0, 0.82, 0.95, 0.9]
    private let attackTaus:   [CGFloat] = [0.035, 0.011, 0.023, 0.007, 0.026]
    private let releaseTaus:  [CGFloat] = [0.41, 0.15, 0.29, 0.12, 0.25]
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard bars.isEmpty, window != nil else { return }
        wantsLayer = true
        let n = responses.count
        smoothed = Array(repeating: 0, count: n)
        let barW: CGFloat = 4, gap: CGFloat = 2.5
        let total = CGFloat(n) * barW + CGFloat(n - 1) * gap
        let startX = bounds.midX - total / 2
        maxH = max(8, bounds.height - 2)   // use nearly the full box height
        minH = max(2, maxH * 0.06)         // near-zero baseline -> maximum visible swing
        for i in 0..<n {
            let l = CALayer()
            l.backgroundColor = NSColor.white.cgColor
            l.cornerRadius = 1.0   // rounded RECTANGLE, not a pill/oval (feedback, 2026-07-09)
            l.frame = CGRect(x: startX + CGFloat(i) * (barW + gap), y: bounds.midY - minH / 2, width: barW, height: minH)
            layer?.addSublayer(l); bars.append(l)
        }
    }
    private func setBarHeight(_ i: Int, _ h: CGFloat, _ dur: CFTimeInterval = 0.08) {
        let l = bars[i]
        let anim = CABasicAnimation(keyPath: "bounds.size.height")
        anim.fromValue = l.bounds.height; anim.toValue = h
        anim.duration = dur; anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.bounds = CGRect(x: 0, y: 0, width: l.bounds.width, height: h)
        l.position = CGPoint(x: l.position.x, y: bounds.midY)
        l.add(anim, forKey: "h")
    }
    // level is the 0...1 the recorder already normalised against this recording's own noise floor
    // (see AudioRecorder.displayLevel). No curve is applied here any more: the old sqrt(level)*1.5
    // existed only to rescue an amplitude-domain level that hugged the bottom of the range, and
    // stacking it on top of a dB-mapped level would just peg every bar near full height.
    func push(_ level: CGFloat) {
        guard !bars.isEmpty else { return }
        let now = CACurrentMediaTime()
        // First push of a recording has no meaningful dt; clamp so a stalled tap can't teleport.
        let dt = lastPush == 0 ? 0.02 : min(0.2, max(0.001, now - lastPush))
        lastPush = now
        let shaped = max(0, min(1, level))
        for i in 0..<bars.count {
            let target = max(0, min(1, shaped * responses[i]))
            let tau = target > smoothed[i] ? attackTaus[i] : releaseTaus[i]
            let k = 1 - exp(-CGFloat(dt) / tau)
            smoothed[i] += k * (target - smoothed[i])
            setBarHeight(i, minH + smoothed[i] * (maxH - minH), min(0.1, max(0.016, dt)))
        }
    }
    func reset() {
        guard !bars.isEmpty else { return }
        lastPush = 0
        for i in 0..<bars.count { smoothed[i] = 0; setBarHeight(i, minH) }
    }
}

// Hover feedback + click-vs-drag detection for the compact panel: hovering shows it's
// interactive, a plain click starts/stops dictation (an alternative to Right ⌘ — "either"
// should work, feedback 2026-07-09), and a right-click opens the app menu. The indicator no
// longer MOVES on drag (pinned bottom-center since 2026-07-27), but drag detection stays:
// a press that slides is not a deliberate click, and the dictation it started must be
// cancelled rather than pasted. We handle mouseDown/dragged/up ourselves
// (mouseDownCanMoveWindow = false) instead of NSWindow's automatic
// isMovableByWindowBackground, because that would swallow the mouseDown before we ever see
// it — there'd be no way to tell "click" from "drag".
final class CompactInteractionView: NSView {
    var onHover: ((Bool) -> Void)?
    var onPressDown: (() -> Void)?
    var onDragDetected: (() -> Void)?          // fires once, the moment a press turns into a drag
    var onPressUp: ((_ wasDrag: Bool) -> Void)?
    var onRightClick: (() -> Void)?            // context menu; never a dictation press
    override var mouseDownCanMoveWindow: Bool { false }
    private var area: NSTrackingArea?
    private var dragStartMouse: NSPoint = .zero
    private var didDrag = false
    // 5pt, not a hair-trigger 2-3pt — a firm trackpad click can carry a few points of finger
    // drift, and misreading that as a drag silently cancels the dictation with no feedback.
    private let dragThreshold: CGFloat = 5

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragStartMouse = NSEvent.mouseLocation
        onPressDown?()
    }
    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x, dy = now.y - dragStartMouse.y
        if !didDrag, max(abs(dx), abs(dy)) > dragThreshold {
            didDrag = true
            onDragDetected?()
        }
    }
    override func mouseUp(with event: NSEvent) { onPressUp?(didDrag) }
    // Deliberately does NOT call super: the default path would try to build a contextual
    // menu from the view, and it must not go through mouseDown's press/dictation logic
    // either — a right-click is a menu, never a recording.
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
}

final class RecordingPanel {
    private var window: NSWindow?
    private var wave: WaveView?
    private var label: NSTextField?
    private var dots: DotsView?
    // Bumped on every show(); a pending hide()-completion from a PREVIOUS cycle must not
    // orderOut a panel that was just re-shown (rapid stop->start races here).
    private var generation = 0

    // "classic" (this file's original full-preview panel, default) or "compact" (a small
    // always-visible indicator pinned bottom-center — see the MARK below). Set by AppDelegate
    // from Config at launch and whenever Settings is saved.
    var style: String = "classic" { didSet { if style != oldValue { styleChanged() } } }

    // Hide the compact indicator without leaving compact style: the app keeps recording and
    // pasting, it just draws nothing on screen (feedback 2026-07-27). Set by AppDelegate from
    // Config at launch and from the "Floating Indicator" menu item.
    var compactHidden: Bool = false { didSet { if compactHidden != oldValue { hiddenChanged() } } }

    // Wired once by AppDelegate so a click on the compact indicator can start/stop dictation
    // the same way Right ⌘ does — RecordingPanel has no idea what "recording" means, it just relays.
    var onCompactPressDown: (() -> Void)?
    var onCompactDragDetected: (() -> Void)?
    var onCompactPressUp: ((_ wasDrag: Bool) -> Void)?
    var onCompactRightClick: (() -> Void)?

    // Real speech (not a blank-audio artifact) → show text; otherwise keep the dots.
    private func isPlaceholder(_ t: String) -> Bool {
        let n = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-—\n\t\""))
        return n.isEmpty || n == "[blank_audio]" || n == "blank_audio" || n == "listening" || n == "you"
    }
    private func showDots(_ on: Bool) {
        dots?.isHidden = !on; label?.isHidden = on
        if on { dots?.start() } else { dots?.stop() }
    }

    func show() {
        if style == "compact" { showCompactActive(); return }
        DispatchQueue.main.async {
            if self.window == nil { self.build() }
            guard let win = self.window else { return }
            self.generation += 1
            self.label?.stringValue = ""
            self.showDots(true)                  // start in the listening-dots state
            self.wave?.levels = Array(repeating: 0.06, count: 28); self.wave?.needsDisplay = true
            self.relayout()                      // reset to single-line height
            self.repositionToActiveScreen(win)   // follow the screen with the cursor (after sizing)
            win.alphaValue = 0; win.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; win.animator().alphaValue = 1 }
        }
    }
    func setLevel(_ l: Float) {
        // Called from the AVAudioEngine tap thread, not main — read `style` only after
        // hopping to main (it's written from Settings/launch on the main thread).
        DispatchQueue.main.async {
            if self.style == "compact" { self.compactLevelBars?.push(CGFloat(l)) }
            else { self.wave?.push(CGFloat(l)) }
        }
    }
    func setTranscribing() {
        if style == "compact" { showCompactTranscribing(); return }
        DispatchQueue.main.async {
            // Keep dots if we never got real text; otherwise leave the text up.
            if self.label?.isHidden ?? true { self.showDots(true) }
        }
    }
    // Live partial transcription text shown above the waveform; panel grows UPWARD as text wraps.
    func setPartial(_ s: String) {
        if style == "compact" { return }   // compact drops the live-text preview — no room at this size
        DispatchQueue.main.async {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.isPlaceholder(t) {
                self.showDots(true)              // still no real speech — keep animated dots
            } else {
                self.showDots(false)
                self.label?.stringValue = self.tailTrim(t)
                self.relayout()
            }
        }
    }

    // Hands-free (tap-to-toggle) vs hold: a 3pt dot at the right end of the active pill says
    // "locked — tap to stop". Both styles; classic shows it in the label line.
    func setLocked(_ on: Bool) {
        DispatchQueue.main.async {
            self.compactLockDot?.isHidden = !on || self.compactIdleBar?.isHidden == false
            self.lockedNow = on
        }
    }
    private var lockedNow = false

    // Command Mode: the pill takes the accent while the instruction is being spoken/applied.
    func setCommandMode(_ on: Bool) {
        DispatchQueue.main.async {
            if self.style == "compact" {
                self.compactChip?.layer?.backgroundColor = on ? NSColor.systemBlue.withAlphaComponent(0.7).cgColor : Self.compactChipColor
            } else if on {
                self.setPartial("Command — say what to do with the selection")
            }
        }
    }

    // Transient failure the user must see (engine down, no audio): the compact chip flashes red
    // for 1.6 s and returns to idle; classic shows the message in the panel.
    func setError(_ msg: String) {
        DispatchQueue.main.async {
            if self.style == "compact" {
                guard let chip = self.compactChip, !self.compactHidden else { return }
                self.compactWin?.orderFrontRegardless()
                chip.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    chip.layer?.backgroundColor = Self.compactChipColor
                    self.showCompactIdle()
                }
            } else {
                self.setPartial("⚠︎ \(msg)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.hide() }
            }
        }
    }

    // Trim text from the FRONT so that it always fits in 3 lines, showing the most recent speech.
    private func tailTrim(_ text: String) -> String {
        guard let label = self.label, let font = label.font else { return text }
        let textW = panelW - 32
        let lineH = ceil(font.ascender - font.descender + font.leading) + 2
        let maxH = lineH * 3
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let fullH = attr.boundingRect(with: NSSize(width: textW, height: 10000),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        guard ceil(fullH) > maxH else { return text }
        // Binary search for the shortest suffix that fits.
        var lo = 0, hi = text.count
        let chars = Array(text)
        while lo < hi {
            let mid = (lo + hi) / 2
            let candidate = String(chars[mid...])
            let a = NSAttributedString(string: candidate, attributes: [.font: font])
            let h = a.boundingRect(with: NSSize(width: textW, height: 10000),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if ceil(h) <= maxH { hi = mid } else { lo = mid + 1 }
        }
        // Trim to a word boundary so we don't start mid-word.
        var suffix = String(chars[lo...])
        if let space = suffix.firstIndex(of: " ") { suffix = String(suffix[suffix.index(after: space)...]) }
        return suffix
    }

    // Wrap text and resize the window vertically, keeping the BOTTOM edge fixed so it grows up.
    private let panelW: CGFloat = 320
    private let wavH: CGFloat = 30, padTop: CGFloat = 14, padBottom: CGFloat = 12, gap: CGFloat = 8
    private func relayout() {
        guard let win = self.window, let label = self.label, let wave = self.wave else { return }
        let textW = panelW - 32
        let text = label.stringValue
        // Measure wrapped height for the current text.
        let attr = NSAttributedString(string: text, attributes: [.font: label.font as Any])
        let bounding = attr.boundingRect(with: NSSize(width: textW, height: 10000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Cap at 3 lines so the panel doesn't grow taller than that.
        let lineH = ceil((label.font?.ascender ?? 12) - (label.font?.descender ?? -3) + (label.font?.leading ?? 0)) + 2
        let maxTextH = lineH * 3
        let textH = max(20, min(ceil(bounding.height), maxTextH))
        let newH = padBottom + wavH + gap + textH + padTop
        let oldFrame = win.frame
        let bottomY = oldFrame.minY   // keep bottom fixed -> window grows upward
        let newFrame = NSRect(x: oldFrame.minX, y: bottomY, width: panelW, height: newH)
        win.setFrame(newFrame, display: true)
        win.contentView?.frame = NSRect(x: 0, y: 0, width: panelW, height: newH)
        // Re-apply the rounded mask at the new size so corners never show white.
        if let vev = win.contentView as? NSVisualEffectView { vev.maskImage = Self.roundedMask(18) }
        // Waveform pinned to the bottom; text fills the area above it.
        wave.frame = NSRect(x: 0, y: padBottom, width: panelW, height: wavH)
        label.frame = NSRect(x: 16, y: padBottom + wavH + gap, width: textW, height: textH)
        // Dots occupy the same region as the text line when shown.
        dots?.frame = NSRect(x: 16, y: padBottom + wavH + gap, width: textW, height: max(20, textH))
    }

    // A resizable rounded-rect mask image so the vibrancy view clips cleanly (no white corners).
    static func roundedMask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
    // Move the panel to whichever screen currently contains the mouse pointer.
    private func repositionToActiveScreen(_ win: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let sf = screen?.frame else { return }
        let w = win.frame.width, h = win.frame.height
        win.setFrameOrigin(NSPoint(x: sf.midX - w/2, y: sf.minY + 90))
    }
    func hide() {
        if style == "compact" { showCompactIdle(); return }
        DispatchQueue.main.async {
            guard let win = self.window else { return }
            let gen = self.generation
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.18; win.animator().alphaValue = 0 },
                                                 completionHandler: {
                // Only orderOut if no newer show() started while we were fading.
                if gen == self.generation { win.orderOut(nil) }
            })
        }
    }
    private func build() {
        let w = panelW
        let h = padBottom + wavH + gap + 20 + padTop   // single-line starting height
        // Initial origin = screen with the cursor (repositioned again on every show()).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let sf = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let win = NSWindow(contentRect: NSRect(x: sf.midX - w/2, y: sf.minY + 90, width: w, height: h),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        // .screenSaver, not .statusBar: a native full-screen window gets its own Space where the
        // menu-bar band (24/25) is where the auto-hiding menu bar and Dock live, and the panel
        // could land under them. 1000 is clear of that band and still far below the lock-screen
        // shield, so it never draws over the lock screen (2026-07-28).
        win.isOpaque = false; win.backgroundColor = .clear; win.level = .screenSaver
        win.ignoresMouseEvents = true
        // .fullScreenAuxiliary is REQUIRED for the panel to appear over full-screen apps /
        // other Spaces — without it the panel silently stays on the original desktop.
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.hasShadow = true
        let c = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        c.material = .hudWindow; c.blendingMode = .behindWindow; c.state = .active
        // maskImage is the correct way to round a vibrancy view — layer cornerRadius alone
        // leaves the window backing square, which is what showed white at the corners.
        c.maskImage = Self.roundedMask(18)
        // Waveform pinned to the bottom.
        let wave = WaveView(frame: NSRect(x: 0, y: padBottom, width: w, height: wavH)); wave.wantsLayer = true
        c.addSubview(wave)
        // Live text ABOVE the waveform — wraps to multiple lines; window grows upward.
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .regular); label.textColor = .labelColor
        label.alignment = .center; label.isBezeled = false; label.drawsBackground = false
        label.isEditable = false; label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.frame = NSRect(x: 16, y: padBottom + wavH + gap, width: w - 32, height: 20)
        c.addSubview(label)
        // Animated listening dots in the same region; shown until real speech arrives.
        let dots = DotsView(frame: NSRect(x: 16, y: padBottom + wavH + gap, width: w - 32, height: 20))
        c.addSubview(dots)
        win.contentView = c; self.window = win; self.wave = wave; self.label = label; self.dots = dots
        installSpaceObserver()
    }

    // MARK: - Compact style: a small, always-visible indicator pinned to bottom-center.
    // Unlike the classic panel (built fresh per show(), hidden the rest of the time), this
    // window is persistent — up from launch to say "online and available" — and just swaps
    // between an idle (thin line) and active (monochrome level-bars, "recognizing audio")
    // appearance. No live-text preview: at this footprint there's no room for it (setPartial
    // is a no-op in compact — see above).
    private var compactWin: NSPanel?
    private var compactIdleBar: NSView?
    private var compactLevelBars: LevelBarsView?
    private var compactHoverBacking: NSView?
    private var compactChip: NSView?
    private var compactLockDot: NSView?
    private static let compactChipColor = NSColor.black.withAlphaComponent(0.45).cgColor
    private var compactScreenFollowTimer: Timer?
    private var compactCurrentScreen: NSScreen?
    private var spaceObserver: Any?
    // Apple's point is defined as 1/72 inch (2.54cm) regardless of actual screen PPI —
    // the same convention Preview/Print use for "actual size" — so this is an exact physical
    // conversion, not a guess, and holds at any display's default (non-custom) scaling.
    private static let ptPerCm: CGFloat = 72.0 / 2.54
    private static let compactSize = NSSize(width: 1.5 * ptPerCm, height: 0.7 * ptPerCm)  // ~42.5 x 19.8pt
    // Neutral/idle draws SMALLER than active — "when it's neutral, it should be smaller"
    // (2026-07-29). Only the visible pill shrinks; the WINDOW stays at compactSize, so the click
    // target is unchanged from before and LevelBarsView — which lays its 5 bars out once, from its
    // own bounds, in viewDidMoveToWindow — never sees a resize it can't respond to.
    private static let compactIdlePill = NSSize(width: compactSize.width * 0.66,
                                                height: compactSize.height * 0.58)  // ~28 x 11.5pt
    // Bottom-center, clear of the Dock — NOT screen-middle (feedback, 2026-07-09: "the
    // default position should be at the bottom mid, not directly the middle... slightly above the
    // Dock"). Same pragmatic fixed-offset approach the classic panel already uses (sf.minY + 90),
    // just expressed as a fraction since compact must also work out on any monitor it follows to.
    // Since 2026-07-27 this is the ONLY position it ever takes: it "moved out of place a lot"
    // because system-initiated window moves (display reconfig, monitor sleep/wake) fired the same
    // didMoveNotification a user drag did, and got persisted as if he had put it there.
    private static let defaultFracX: CGFloat = 0.5
    private static let defaultFracY: CGFloat = 0.06

    private static func pinnedOrigin(on screen: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: screen.minX + defaultFracX * screen.width - size.width / 2,
                y: screen.minY + defaultFracY * screen.height - size.height / 2)
    }

    private func styleChanged() {
        if style == "compact" {
            guard !compactHidden else { return }   // stays off screen until the menu turns it back on
            if compactWin == nil { buildCompact() }
            showCompactIdle()
            startScreenFollow()
        } else {
            compactWin?.orderOut(nil)
            compactScreenFollowTimer?.invalidate(); compactScreenFollowTimer = nil
        }
    }

    private func hiddenChanged() {
        DispatchQueue.main.async {
            guard self.style == "compact" else { return }
            if self.compactHidden {
                self.compactWin?.orderOut(nil)
                self.compactScreenFollowTimer?.invalidate(); self.compactScreenFollowTimer = nil
            } else {
                if self.compactWin == nil { self.buildCompact() }
                self.recenterCompact()
                // orderFrontRegardless, not showCompactIdle: whatever idle/active appearance it
                // had is still correct — unhiding mid-dictation must not reset it to idle.
                self.compactWin?.orderFrontRegardless()
                self.startScreenFollow()
            }
        }
    }

    // The screen that currently contains the mouse — same idea as the classic panel's
    // repositionToActiveScreen, but compact is persistent (not only shown while recording),
    // so it needs to keep following as the user moves between monitors ("so I could recognize
    // it's working" — feedback from live-testing, 2026-07-09).
    private static func screenAt(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func startScreenFollow() {
        compactScreenFollowTimer?.invalidate()
        compactScreenFollowTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, let win = self.compactWin else { return }
            guard let screen = Self.screenAt(NSEvent.mouseLocation), screen != self.compactCurrentScreen else { return }
            self.compactCurrentScreen = screen
            let origin = Self.pinnedOrigin(on: screen.frame, size: win.frame.size)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                win.animator().setFrameOrigin(origin)
            }
        }
    }

    // Re-pin to bottom-center of whichever screen it is on now. Called on display
    // reconfiguration: WindowServer relocates borderless windows on its own when monitors
    // sleep/wake or resolutions change, and that drift is exactly what used to be mistaken
    // for the user having moved it (2026-07-27).
    private func recenterCompact() {
        guard let win = compactWin else { return }
        // Only screens that exist RIGHT NOW — a cached NSScreen from before the
        // reconfiguration can still report its old frame.
        let screen = Self.screenAt(NSPoint(x: win.frame.midX, y: win.frame.midY))
                     ?? Self.screenAt(NSEvent.mouseLocation) ?? NSScreen.main
        guard let sf = screen?.frame else { return }
        compactCurrentScreen = screen
        win.setFrameOrigin(Self.pinnedOrigin(on: sf, size: win.frame.size))
    }

    private func buildCompact() {
        let size = Self.compactSize
        let mouseScreen = Self.screenAt(NSEvent.mouseLocation)
        let screen = mouseScreen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        compactCurrentScreen = mouseScreen ?? NSScreen.main
        let origin = Self.pinnedOrigin(on: screen, size: size)
        let win = NSPanel(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = true
        // See the classic panel for why .screenSaver rather than .statusBar (2026-07-28).
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Never becomes key or activates the app (Photoshop-palette style) — .nonactivatingPanel.
        // The indicator is pinned (2026-07-27), so nothing may move it: isMovableByWindowBackground
        // stays false, and CompactInteractionView (below) only *detects* a drag to tell it apart
        // from a click.
        win.isMovableByWindowBackground = false
        win.ignoresMouseEvents = false

        let content = CompactInteractionView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        // A permanent dark pill "chip" behind everything else — without this, white-on-white
        // bars/line vanish on a light desktop background. Same trick Wispr Flow's own widget
        // uses (and Dynamic Island): the indicator carries its own contrast, independent of
        // whatever happens to be underneath it.
        let chip = NSView(frame: NSRect(origin: .zero, size: size))
        chip.wantsLayer = true
        // 0.62 -> 0.45: he wanted the whole thing more see-through (2026-07-29). Still opaque
        // enough to keep the white bar legible on a light desktop, which is the chip's only job.
        chip.layer?.backgroundColor = Self.compactChipColor
        chip.layer?.cornerRadius = size.height / 2
        content.addSubview(chip)
        // Hover: a faint pill fades in so it reads as "this is interactive/draggable."
        let hoverBacking = NSView(frame: NSRect(origin: .zero, size: size))
        hoverBacking.wantsLayer = true
        hoverBacking.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        hoverBacking.layer?.cornerRadius = size.height / 2
        hoverBacking.alphaValue = 0
        content.addSubview(hoverBacking)
        content.onHover = { [weak hoverBacking] hovering in
            guard let hoverBacking else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                hoverBacking.animator().alphaValue = hovering ? 1 : 0
            }
        }
        // Forward click/drag straight to whoever AppDelegate wired up — RecordingPanel itself
        // has no notion of "recording", it just relays.
        content.onPressDown = { [weak self] in self?.onCompactPressDown?() }
        content.onDragDetected = { [weak self] in self?.onCompactDragDetected?() }
        content.onPressUp = { [weak self] wasDrag in self?.onCompactPressUp?(wasDrag) }
        content.onRightClick = { [weak self] in self?.onCompactRightClick?() }
        // Idle: a very thin translucent line — visible enough to say "online", unobtrusive.
        let bar = NSView(frame: NSRect(x: 4, y: (size.height - 3) / 2, width: size.width - 8, height: 3))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.5).cgColor
        bar.layer?.cornerRadius = 1.5
        content.addSubview(bar)
        // Active: a monochrome equalizer that springs with live mic level — "recognizing audio".
        let levelBars = LevelBarsView(frame: NSRect(origin: .zero, size: size))
        levelBars.isHidden = true
        content.addSubview(levelBars)
        // Hands-free lock tell: a 3pt dot inside the right end of the active pill.
        let lockDot = NSView(frame: NSRect(x: size.width - 7, y: size.height / 2 - 1.5, width: 3, height: 3))
        lockDot.wantsLayer = true
        lockDot.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.9).cgColor
        lockDot.layer?.cornerRadius = 1.5
        lockDot.isHidden = true
        content.addSubview(lockDot)
        win.contentView = content

        // Re-pin on display reconfiguration (monitor sleep/wake, resolution change, dock/undock).
        // This replaces the didMoveNotification observer that used to persist a position: those
        // same system-initiated moves were being recorded as the user's chosen spot, which is why
        // the indicator drifted (2026-07-27). Twice — once now, once after things settle, because
        // WindowServer's own relocation can land after this notification is delivered.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.recenterCompact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.recenterCompact() }
        }

        compactWin = win; compactIdleBar = bar; compactLevelBars = levelBars; compactHoverBacking = hoverBacking
        compactChip = chip; compactLockDot = lockDot
        layoutCompactPill(Self.compactIdlePill, animated: false)   // it comes up neutral
        installSpaceObserver()
    }

    // Resize the visible pill (chip + hover backing + idle line) inside the fixed-size window,
    // centred. Active = fills the window; neutral = compactIdlePill.
    private func layoutCompactPill(_ pill: NSSize, animated: Bool) {
        guard let content = compactWin?.contentView else { return }
        let full = content.bounds
        let r = NSRect(x: full.midX - pill.width / 2, y: full.midY - pill.height / 2,
                       width: pill.width, height: pill.height)
        // The idle line keeps its 3pt thickness at both sizes — it is the "online" tell, and
        // scaling it down with the pill made it disappear.
        let barW = max(8, pill.width - 8)
        let barR = NSRect(x: full.midX - barW / 2, y: full.midY - 1.5, width: barW, height: 3)
        // cornerRadius is not animatable through the view animator; set it up front. Mid-transition
        // the pill is fully rounded either way, so there is nothing visible to lose.
        compactChip?.layer?.cornerRadius = pill.height / 2
        compactHoverBacking?.layer?.cornerRadius = pill.height / 2
        let apply = { (chip: NSView?, hover: NSView?, bar: NSView?) in
            chip?.frame = r; hover?.frame = r; bar?.frame = barR
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                apply(compactChip?.animator(), compactHoverBacking?.animator(), compactIdleBar?.animator())
            }, completionHandler: { [weak self] in self?.compactWin?.invalidateShadow() })
        } else {
            apply(compactChip, compactHoverBacking, compactIdleBar)
            compactWin?.invalidateShadow()
        }
    }

    // Entering native full screen (⌃⌘F) creates a NEW Space. .canJoinAllSpaces alone was not
    // enough: the persistent compact panel is only ordered front on build/show/unhide, so a Space
    // that comes into existence afterwards never gets it and the indicator silently vanishes
    // (his report, 2026-07-28). Re-assert on every Space switch — cheap, and it also covers
    // ordinary desktop swipes.
    private func installSpaceObserver() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reassertOnCurrentSpace()
            // The fullscreen transition animation is still running when the notification lands;
            // WindowServer can drop the panel again mid-animation, so re-assert once it settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.reassertOnCurrentSpace() }
        }
    }

    private func reassertOnCurrentSpace() {
        if style == "compact", !compactHidden, let win = compactWin {
            recenterCompact()
            win.orderFrontRegardless()
        }
        // The classic panel only exists while dictating; re-assert it too so a dictation started
        // before the Space change does not lose its panel.
        if style != "compact", let win = window, win.isVisible {
            repositionToActiveScreen(win)
            win.orderFrontRegardless()
        }
    }

    private func showCompactIdle() {
        DispatchQueue.main.async {
            guard !self.compactHidden, let win = self.compactWin else { return }
            self.compactLevelBars?.layer?.removeAnimation(forKey: "pulse"); self.compactLevelBars?.layer?.opacity = 1
            self.compactLockDot?.isHidden = true
            self.compactLevelBars?.isHidden = true; self.compactLevelBars?.reset()
            self.compactIdleBar?.isHidden = false
            self.layoutCompactPill(Self.compactIdlePill, animated: true)
            win.orderFrontRegardless()
        }
    }
    // Transcribing: the bars stop following the mic and breathe (opacity pulse) until hide().
    private func showCompactTranscribing() {
        DispatchQueue.main.async {
            guard !self.compactHidden, let bars = self.compactLevelBars, !bars.isHidden else { return }
            self.compactLockDot?.isHidden = true
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0; a.toValue = 0.35; a.duration = 0.55
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bars.layer?.add(a, forKey: "pulse")
        }
    }
    private func showCompactActive() {
        DispatchQueue.main.async {
            guard !self.compactHidden else { return }   // dictation still runs, it just draws nothing
            if self.compactWin == nil { self.buildCompact() }
            guard let win = self.compactWin else { return }
            self.compactLevelBars?.layer?.removeAnimation(forKey: "pulse"); self.compactLevelBars?.layer?.opacity = 1
            self.compactLockDot?.isHidden = !self.lockedNow
            self.compactIdleBar?.isHidden = true
            self.compactLevelBars?.isHidden = false; self.compactLevelBars?.reset()
            self.layoutCompactPill(Self.compactSize, animated: true)   // grows on dictation
            win.orderFrontRegardless()
        }
    }
}

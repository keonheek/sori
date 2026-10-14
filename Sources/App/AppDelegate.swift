import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// Tag stamped onto every synthetic event WE post (⌘V paste, Enter submit) so our own
// event tap can recognize and ignore them. Without this, an auto-submit Enter that lands
// while a NEW recording is live gets consumed as "Enter during recording" — killing the
// submit and truncating the new session.
let wpttSyntheticTag: Int64 = 0x57505454   // "WPTT"
func wpttEventSource() -> CGEventSource? {
    let src = CGEventSource(stateID: .hidSystemState)
    src?.userData = wpttSyntheticTag
    return src
}

// MARK: - App
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var recorder = AudioRecorder()
    var isRecording = false
    var eventTap: CFMachPort?
    let panel = RecordingPanel()
    var cfg = Config.load()
    var hub: HubController?
    private var termSource: DispatchSourceSignal?

    var rightCmdDown = false
    var otherKeyDuringCmd = false
    var cmdDownTimeNs: UInt64 = 0      // CGEvent.timestamp of the right ⌘ down (ns since boot)
    var startedThisPress = false        // did this ⌘-press start a recording?
    var submitAfterPaste = false        // set when Enter ended the recording — auto-press Enter after paste
    var commandModeArmed = false        // Right ⌥ pressed while Right ⌘ held → this recording is an instruction
    var streamClient: OpenAIRealtime?   // live while a streaming (P7) recording runs
    // Short press (< 400ms) = TAP: start now, keep recording, next tap stops.
    // Longer press (>= 400ms) = HOLD: recording stops the moment you let go.
    let holdThresholdNs: UInt64 = 400_000_000  // 400ms
    // Mirror of rightCmdDown/startedThisPress/cmdDownTimeNs, but for a click on the compact
    // panel — kept separate from the Right-⌘ state so the two input paths can't cross-talk;
    // both ultimately drive the SAME isRecording/startRecording()/stopAndTranscribe().
    var clickStartedThisPress = false
    var clickDownTimeNs: UInt64 = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        // Single-instance guard: launchd, Login Items, and session-restore can all launch
        // the app at login. The old NSRunningApplication pid check RACED on simultaneous
        // starts — both processes checked before either registered, both survived
        // (observed 2026-07-04: two instances born the same second, every dictation
        // double-pasted). An exclusive flock cannot race: the kernel grants it to exactly
        // one process, and it releases automatically on ANY exit, including SIGKILL.
        let lockFd = open((NSHomeDirectory() as NSString).appendingPathComponent(".sori.lock"),
                          O_CREAT | O_RDWR, 0o600)
        if lockFd == -1 {
            // Genuine I/O failure (permissions, disk) — NOT contention. Run unguarded
            // rather than refusing to launch; log the real cause.
            wlog("single-instance lock OPEN FAILED (errno \(errno)) — continuing without guard")
        } else if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            wlog("another instance holds the single-instance lock — exiting pid \(ProcessInfo.processInfo.processIdentifier)")
            exit(0)
        }
        // lockFd is intentionally never closed — the lock must live exactly as long as the process.
        DictionaryRepo.migrateFromConfigIfNeeded()
        cfg = Config.load()
        if let days = cfg.historyRetentionDays, days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            Database.shared.run("DELETE FROM dictations WHERE ts < ?", [.real(cutoff)])
        }
        NotificationCenter.default.addObserver(forName: HubModel.configChanged, object: nil, queue: .main) { [weak self] _ in self?.applyConfigChange() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon("mic")
        statusItem.menu = buildMainMenu()

        recorder.onLevel = { [weak self] lv in self?.panel.setLevel(lv) }
        // Hidden must be applied BEFORE style: switching to compact while hidden has to build
        // nothing at all (feedback 2026-07-27 — the indicator can be turned off entirely).
        panel.compactHidden = cfg.compactHidden ?? false
        // Compact style shows an always-visible idle indicator from launch ("online and
        // available"); classic stays hidden until a recording starts, so this is a no-op for it.
        panel.style = cfg.panelStyle ?? "classic"

        // Click-to-dictate on the compact indicator — an ALTERNATIVE to Right ⌘, not a
        // replacement ("either" should work, feedback 2026-07-09). Mirrors the exact
        // tap/hold decision Right ⌘ uses, just keyed off mouse-down/up timing instead.
        panel.onCompactPressDown = { [weak self] in
            guard let self else { return }
            self.clickDownTimeNs = DispatchTime.now().uptimeNanoseconds
            if !self.isRecording {
                self.clickStartedThisPress = true
                self.startRecording()
            } else {
                self.clickStartedThisPress = false
            }
        }
        panel.onCompactDragDetected = { [weak self] in
            guard let self, self.clickStartedThisPress else { return }
            // The press slid instead of clicking — not a deliberate start. Discard silently, no
            // paste. (The indicator no longer moves with the drag; this cancel is the whole
            // remaining reason to detect one.)
            self.clickStartedThisPress = false
            self.cancelRecording()
        }
        panel.onCompactPressUp = { [weak self] wasDrag in
            guard let self, !wasDrag else { return }
            let heldNs = DispatchTime.now().uptimeNanoseconds &- self.clickDownTimeNs
            let wasHold = heldNs >= self.holdThresholdNs
            if self.clickStartedThisPress {
                // isRecording guard: Right-⌘ (e.g. a quick tap while the mouse was still held)
                // may have already stopped this same recording — without it, this would stop a
                // second time.
                if wasHold && self.isRecording { self.stopAndTranscribe() }
                else if self.isRecording { self.panel.setLocked(true) }   // quick click that started it -> tap-on (mirrors TAP-on)
            } else if self.isRecording {
                self.stopAndTranscribe()                  // click while already recording -> tap-off
            }
        }
        // Right-click the indicator = the same menu the menu-bar icon shows (feedback
        // 2026-07-27). `in: nil` means the point is in SCREEN coordinates, which is what
        // NSEvent.mouseLocation already gives us — no view-space conversion, and no need for
        // the .nonactivatingPanel to become key.
        panel.onCompactRightClick = { [weak self] in
            guard let self else { return }
            self.buildMainMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }

        AVCaptureDevice.requestAccess(for: .audio) { g in wlog("mic granted=\(g)") }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        wlog("=== launch AXTrusted=\(trusted) ===")
        // 2026-07-08: after an ad-hoc -> stable-identity codesign switch, WindowServer
        // gates keyDown delivery to event taps on kTCCServiceListenEvent (Input Monitoring);
        // Accessibility alone stopped sufficing. Request it so we appear in the pane.
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        wlog("IOHID ListenEvent access=\(hidAccess.rawValue) (0=granted 1=denied 2=unknown)")
        if hidAccess != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        installTap()

        // launchctl kill / kickstart -k deliver SIGTERM, which never reaches applicationWillTerminate;
        // the qwen_server child was surviving every redeploy as an orphan on :8918 (2026-09-20).
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { wlog("SIGTERM — stopping qwen_server and exiting"); QwenServer.stop(); exit(0) }
        termSource?.resume()

        // First run (or a lost permission): the setup window. Never on a machine that has been
        // through it — `onboarded` is set when the window closes.
        let needsSetup = Database.shared.meta("onboarded") == nil || !trusted || hidAccess != kIOHIDAccessTypeGranted
        if CommandLine.arguments.contains("--onboard") || needsSetup { openOnboarding() }

        // Preload the warm engine so even the FIRST dictation skips the model load.
        // Off the main thread — server spawn + model load takes ~2s.
        if cfg.warmEngine ?? true {
            let repo = cfg.asrModel ?? QwenServer.defaultRepo
            DispatchQueue.global(qos: .utility).async { QwenServer.ensureRunning(modelPath: repo) }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        QwenServer.stop()
    }

    // Native template SF Symbol in the menu bar (adapts to light/dark, tinted states)
    // instead of the old emoji titles (🎙/🔴/⏳/⚠️).
    func setStatusIcon(_ symbol: String, tint: NSColor? = nil) {
        guard let b = statusItem.button else { return }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sori")
        img?.isTemplate = (tint == nil)
        b.image = img
        b.contentTintColor = tint
        b.title = ""
    }

    // One menu definition, two hosts: the status item and the compact indicator's right-click
    // (feedback 2026-07-27). Built fresh per call so the checkmarks read the CURRENT cfg —
    // with two hosts there is no single long-lived NSMenuItem left to keep in sync.
    func buildMainMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Tap Right ⌘ to start / stop", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Sori Hub", action: #selector(openHubAction), keyEquivalent: "h"))
        let lastItem = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLastTranscript), keyEquivalent: "")
        lastItem.isEnabled = DictationRepo.last() != nil
        menu.addItem(lastItem)
        menu.addItem(NSMenuItem.separator())
        let undoItem = NSMenuItem(title: "Undo AI Edit", action: #selector(undoAIEdit as () -> Void), keyEquivalent: "")
        undoItem.isEnabled = (lastPaste.map { $0.raw != $0.final } ?? false)
        menu.addItem(undoItem)
        menu.addItem(NSMenuItem(title: "Style…", action: #selector(openStyle), keyEquivalent: ""))
        // Reachable from the menu bar too — otherwise turning the indicator off would hide the
        // only way to turn it back on.
        let indicatorItem = NSMenuItem(title: "Floating Indicator", action: #selector(toggleCompactIndicator(_:)), keyEquivalent: "")
        indicatorItem.state = (cfg.compactHidden ?? false) ? .off : .on
        menu.addItem(indicatorItem)
        // Microphone: the Flow-Bar-style device picker. System default stays the default; a pick
        // pins that device through the HAL capture path (AirPods rule still applies on top).
        let micMenu = NSMenu()
        let current = cfg.inputDeviceUID ?? ""
        let sys = NSMenuItem(title: "System Default", action: #selector(pickMicrophone(_:)), keyEquivalent: "")
        sys.representedObject = ""; sys.state = current.isEmpty ? .on : .off; sys.target = self
        micMenu.addItem(sys)
        micMenu.addItem(NSMenuItem.separator())
        for dev in InputDevice.allInputs() {
            let it = NSMenuItem(title: dev.name, action: #selector(pickMicrophone(_:)), keyEquivalent: "")
            it.representedObject = dev.uid; it.state = dev.uid == current ? .on : .off; it.target = self
            micMenu.addItem(it)
        }
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Setup…", action: #selector(openOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sori \(soriVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Explicit target on every item: a menu popped up from the .nonactivatingPanel never
        // becomes key, so nothing may depend on the responder chain to find an action.
        menu.items.forEach { $0.target = self }
        return menu
    }



    @objc func toggleCompactIndicator(_ sender: NSMenuItem) {
        let hidden = !(cfg.compactHidden ?? false)
        cfg.compactHidden = hidden
        sender.state = hidden ? .off : .on
        cfg.save()
        panel.compactHidden = hidden
        statusItem.menu = buildMainMenu()
        wlog("compact indicator hidden -> \(hidden)")
    }

    // Menu-bar apps have no dock icon, so an alert can open behind whatever is frontmost —
    // activate first or the user sees nothing happen.
    private func showAlert(_ title: String, _ body: String, buttons: [String]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        buttons.forEach { a.addButton(withTitle: $0) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    @objc func checkForUpdates() {
        wlog("update check requested (current \(soriVersion))")
        Updater.fetchLatest { [weak self] rel, err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let r = rel else {
                    _ = self.showAlert("Could not check for updates",
                                       "\(err ?? "unknown error")\n\nYou can always look at:\n\(Updater.releasesPage)",
                                       buttons: ["OK"])
                    return
                }
                guard Updater.isNewer(r.tag, than: soriVersion) else {
                    _ = self.showAlert("Sori is up to date",
                                       "You have \(soriVersion), which is the latest release.",
                                       buttons: ["OK"])
                    return
                }
                let notes = r.notes.isEmpty ? "" : "\n\n\(r.notes.prefix(600))"
                if let src = Updater.sourceRepo() {
                    // Source install: the rebuild is re-signed with the same identity, so no
                    // permission is lost and this can be genuinely one click.
                    let pick = self.showAlert("Sori \(r.tag) is available",
                                              "You have \(soriVersion).\n\nUpdating rebuilds from your "
                                              + "source folder (\(src)) and restarts Sori. Your microphone "
                                              + "and keyboard permissions are kept.\(notes)",
                                              buttons: ["Update & Restart", "Release Notes", "Later"])
                    if pick == 0 {
                        if let e = Updater.runSourceUpdate(src, to: r.tag) {
                            _ = self.showAlert("Update could not start", e, buttons: ["OK"])
                        }
                    } else if pick == 1, let u = URL(string: r.page) {
                        NSWorkspace.shared.open(u)
                    }
                } else {
                    // Prebuilt/ad-hoc install: a new download always has a new code signature,
                    // so macOS drops the two keyboard permissions. Say it plainly up front.
                    let pick = self.showAlert("Sori \(r.tag) is available",
                                              "You have \(soriVersion).\n\nDownload the new zip and replace "
                                              + "Sori in your Applications folder. Because the prebuilt app "
                                              + "isn't signed with an Apple developer certificate, macOS will "
                                              + "ask you to turn Sori back on in System Settings → Privacy & "
                                              + "Security → Accessibility and Input Monitoring afterwards.\(notes)",
                                              buttons: ["Open Release Page", "Later"])
                    if pick == 0, let u = URL(string: r.page) { NSWorkspace.shared.open(u) }
                }
            }
        }
    }

    @objc func pickMicrophone(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        cfg.inputDeviceUID = uid.isEmpty ? nil : uid
        cfg.save()
        statusItem.menu = buildMainMenu()
        wlog("microphone pick -> \(uid.isEmpty ? "system default" : sender.title)")
    }

    @objc func openHubAction() { openHub(section: .home) }
    @objc func openStyle() { openHub(section: .style) }
    func openHub(section: HubModel.Section) {
        if hub == nil { hub = HubController() }
        hub?.model.section = section
        hub?.show()
        wlog("hub opened (\(section.rawValue))")
    }

    // Typed-over corrections: snapshot the focused field ~0.6 s after the paste, then poll its AX
    // value for 20 s. If the pasted span changed by a word or two, learn it like a clipboard fix.
    private var fieldWatchGen = 0
    func watchFieldForCorrection(of pasted: String) {
        fieldWatchGen += 1
        let gen = fieldWatchGen
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success, let f = focusedRef else { return }
        let el = f as! AXUIElement
        func value() -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
            return v as? String
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, gen == self.fieldWatchGen, let v0 = value(), let r0 = v0.range(of: pasted) else { return }
            let start = v0.distance(from: v0.startIndex, to: r0.lowerBound)
            var polls = 0
            func poll() {
                guard gen == self.fieldWatchGen, polls < 10 else { return }
                polls += 1
                if let v1 = value(), v1 != v0 {
                    // Same prefix before the paste, then the (possibly edited) span, then the same suffix.
                    let prefix = String(v0.prefix(start))
                    let suffixLen = v0.count - start - pasted.count
                    let suffix = String(v0.suffix(suffixLen))
                    if v1.hasPrefix(prefix), v1.hasSuffix(suffix), v1.count >= prefix.count + suffix.count {
                        let span = String(v1.dropFirst(prefix.count).dropLast(suffix.count))
                        if span != pasted, !span.isEmpty {
                            wlog("typed-over edit detected in field")
                            self.considerCorrection(from: pasted, to: span)
                            return
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { poll() }
            }
            poll()
        }
    }

    // MARK: Undo AI edit — swap the text just pasted for the raw transcript (and back)
    struct LastPaste { let pasted: String; let final: String; let raw: String; let at: Date; var showingRaw: Bool }
    var lastPaste: LastPaste?

    @objc func undoAIEdit() { undoAIEdit(maxAge: 600) }
    func undoAIEdit(maxAge: TimeInterval) {
        guard var lp = lastPaste, Date().timeIntervalSince(lp.at) < maxAge else { wlog("undo: nothing recent to undo"); return }
        guard lp.raw != lp.final else { wlog("undo: nothing changed by AI for this paste"); return }
        let replacement = lp.showingRaw ? lp.final : lp.raw
        guard selectBack(lp.pasted) else { wlog("undo: could not select the pasted text back"); panel.setError("Couldn't select the pasted text"); return }
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil); pb.setString(replacement, forType: .string)
        let src = wpttEventSource()
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap); up?.post(tap: .cgAnnotatedSessionEventTap)
        lp.showingRaw.toggle()
        lastPaste = LastPaste(pasted: replacement, final: lp.final, raw: lp.raw, at: Date(), showingRaw: lp.showingRaw)
        wlog("undo AI edit -> \(lp.showingRaw ? "raw" : "final") (\(replacement.count) chars)")
    }

    // Select the text that was just pasted, ending at the caret. AX selected-range first (exact,
    // works in Cocoa text views and most Electron/Chromium fields); fall back to ⇧← N times.
    private func selectBack(_ pasted: String, allowKeyFallback: Bool = true) -> Bool {
        let n = pasted.utf16.count
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success, let f = focusedRef {
            let el = f as! AXUIElement
            var rangeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success, let rv = rangeRef {
                var cur = CFRange()
                if AXValueGetValue(rv as! AXValue, .cfRange, &cur), cur.location >= n {
                    var want = CFRange(location: cur.location - n, length: n)
                    if let v = AXValueCreate(.cfRange, &want), AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success {
                        var selRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selRef) == .success,
                           let sel = selRef as? String, sel == pasted { return true }
                        wlog("undo: AX range set but selection mismatch — falling back to ⇧←")
                    }
                }
            }
        }
        let count = pasted.count
        guard allowKeyFallback, count <= 3000 else { return false }
        let src = wpttEventSource()
        for _ in 0..<count {
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: false)
            d?.flags = .maskShift; u?.flags = .maskShift
            d?.post(tap: .cgAnnotatedSessionEventTap); u?.post(tap: .cgAnnotatedSessionEventTap)
        }
        usleep(UInt32(min(400_000, 2_000 * count)))   // let the target catch up before ⌘V
        return true
    }

    // From the menu bar / indicator menu: the target app keeps focus (the status menu and the
    // .nonactivatingPanel never take it), so the paste lands where the caret is.
    @objc func pasteLastTranscript() {
        guard let d = DictationRepo.last() else { return }
        wlog("paste last transcript (#\(d.id))")
        paste(d.final, submit: false, dictationId: nil)
    }

    @objc func openSettings() { openHub(section: .settings) }

    var onboarding: OnboardingController?
    @objc func openOnboarding() {
        if onboarding == nil { onboarding = OnboardingController() }
        onboarding?.perms.refresh()
        onboarding?.show()
        wlog("onboarding opened")
    }

    // Settings changed from the Hub: re-read and apply what has a live effect.
    func applyConfigChange() {
        cfg = Config.load()
        panel.compactHidden = cfg.compactHidden ?? false
        panel.style = cfg.panelStyle ?? "classic"
        statusItem.menu = buildMainMenu()
        wlog("settings applied (hub)")
    }

    func installTap() {
        if eventTap != nil { return }
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue))
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let d = refcon { let dl = Unmanaged<AppDelegate>.fromOpaque(d).takeUnretainedValue()
                        if let t = dl.eventTap { CGEvent.tapEnable(tap: t, enable: true) } }
                    return Unmanaged.passRetained(event)
                }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                // Our own synthetic events (paste / auto-Enter) — never intercept.
                if event.getIntegerValueField(.eventSourceUserData) == wpttSyntheticTag {
                    return Unmanaged.passRetained(event)
                }
                let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                if type == .keyDown {
                    // Enter (36) or numpad Enter (76) WHILE recording AND Right ⌘ held = stop +
                    // transcribe + submit. Plain Enter alone no longer submits — it passes
                    // through untouched — so an Enter meant for the focused app doesn't get
                    // eaten mid-dictation (TAP mode: re-press-and-hold Right ⌘, then Enter, to send;
                    // HOLD mode is unaffected since Right ⌘ is already down throughout).
                    if delegate.isRecording && (keycode == 36 || keycode == 76) && delegate.rightCmdDown {
                        wlog("Right⌘+Enter during recording -> stop+transcribe+submit")
                        delegate.rightCmdDown = false
                        delegate.submitAfterPaste = true
                        delegate.stopAndTranscribe()
                        return nil   // consume this Enter; we re-issue it after pasting
                    }
                    // Right ⌘ + Z within 10 s of a paste = undo the AI edit (raw ⇄ final).
                    if delegate.rightCmdDown && keycode == 6 {
                        delegate.noteChord()   // cancels the recording this press started
                        DispatchQueue.main.async { delegate.undoAIEdit(maxAge: 10) }
                        return nil
                    }
                    // Escape (53) WHILE recording = cancel, discard audio, no paste.
                    if delegate.isRecording && keycode == 53 {
                        wlog("Escape during recording -> cancel")
                        delegate.rightCmdDown = false
                        delegate.cancelRecording()
                        return nil   // consume Escape
                    }
                    delegate.noteChord()
                    return Unmanaged.passRetained(event)
                }
                // Right ⌥ (61) while Right ⌘ is held = Command Mode for this recording (Experimental).
                if keycode == 61 && delegate.rightCmdDown && delegate.isRecording && (delegate.cfg.commandMode ?? false) {
                    if event.flags.contains(.maskAlternate) && !delegate.commandModeArmed {
                        delegate.commandModeArmed = true
                        delegate.panel.setCommandMode(true)
                        wlog("command mode ARMED")
                    }
                    return nil   // never let the ⌥ chord reach the app
                }
                guard keycode == 54 else {
                    delegate.noteChord()
                    return Unmanaged.passRetained(event)
                }
                let isDown = event.flags.contains(.maskCommand)
                if isDown {
                    // Right ⌘ pressed.
                    delegate.rightCmdDown = true
                    delegate.otherKeyDuringCmd = false
                    // Event timestamp, not wall clock: startRecording() below runs synchronously
                    // in this callback and the AirPods-pinned HAL path took 400ms+ on 2026-09-20
                    // (CoreAudio device query stalled), so the queued key-UP was processed ~460ms
                    // after the press and a quick tap read as a HOLD -> instant stop, empty paste.
                    delegate.cmdDownTimeNs = event.timestamp
                    delegate.startedThisPress = false
                    if !delegate.isRecording {
                        // Begin recording immediately — supports HOLD-to-talk.
                        delegate.startedThisPress = true
                        delegate.startRecording()
                    }
                } else {
                    // Right ⌘ released.
                    let wasDown = delegate.rightCmdDown
                    let clean = wasDown && !delegate.otherKeyDuringCmd
                    delegate.rightCmdDown = false
                    guard clean else { return Unmanaged.passRetained(event) }
                    let heldNs = event.timestamp &- delegate.cmdDownTimeNs
                    let wasHold = heldNs >= delegate.holdThresholdNs
                    if delegate.commandModeArmed && delegate.isRecording {
                        wlog("command mode release -> stop+run")
                        delegate.stopAndTranscribe()
                    } else if delegate.startedThisPress {
                        // This press started the recording.
                        if wasHold && delegate.isRecording {
                            wlog("HOLD release (\(heldNs/1_000_000)ms) -> stop")
                            delegate.stopAndTranscribe()
                        } else if !wasHold {
                            // Quick tap that started recording -> stay recording (toggle-on).
                            wlog("TAP-on (\(heldNs/1_000_000)ms) -> keep recording")
                            delegate.panel.setLocked(true)
                        }
                    } else if delegate.isRecording {
                        // Recording was already running from a previous tap; any release now = tap-off.
                        // (isRecording guard: a click on the compact panel may have already stopped
                        // this same recording — without it, this would stop+transcribe a SECOND time.)
                        wlog("TAP-off (\(heldNs/1_000_000)ms) -> stop")
                        delegate.stopAndTranscribe()
                    }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passRetained(self).toOpaque()
        )
        if let tap = eventTap {
            wlog("event tap CREATED ok")
            setStatusIcon("mic")
            let loop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            startTapWatchdog()
        } else {
            wlog("event tap FAILED — retrying in 2s")
            setStatusIcon("exclamationmark.triangle.fill", tint: .systemYellow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installTap() }
        }
    }

    // Right ⌘ used as a modifier (Right ⌘+C, Right ⌘+Shift, …) while the press that
    // started a recording is still down: that press was a shortcut, not a dictation.
    // Before 2026-09-03 the release was ignored and the recording ran on until the
    // next tap. Cancel it the moment the chord appears — nothing has been pasted yet.
    func noteChord() {
        guard rightCmdDown else { return }
        otherKeyDuringCmd = true
        if startedThisPress && isRecording {
            wlog("Right⌘ chord -> cancel the recording this press started")
            startedThisPress = false
            cancelRecording()
        }
    }

    // Watchdog: macOS silently disables an event tap that stalls (or after sleep/wake,
    // login-window transitions, etc.). A disabled tap receives NO further events, so it
    // can never re-enable itself from the callback — Right ⌘ just goes permanently dead.
    // Poll every 5s and revive it.
    private var tapWatchdog: Timer?
    private func startTapWatchdog() {
        tapWatchdog?.invalidate()
        tapWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                wlog("watchdog: event tap was DISABLED — re-enabled")
            }
        }
    }

    // Mic-conflict / bad-route detection: returns a warning string if the input device
    // looks unusable (no device, or a low-quality Bluetooth HFP call route), else nil.
    func micWarning() -> String? {
        // Capture is pinned to the built-in mic, so the Bluetooth default's route is irrelevant.
        // This check runs FIRST: AVCaptureDevice.default(for: .audio) touches the default
        // device, and on AirPods that alone was enough to trip the HFP switch on every press
        // (his report 2026-09-20: 0.5s of silence on press, none on release).
        if InputDevice.preferred(avoidBluetooth: cfg.avoidBluetoothMic ?? true) != nil { return nil }
        guard let dev = AVCaptureDevice.default(for: .audio) else {
            return "No microphone found"
        }
        // Bluetooth devices in call/HFP mode report a very low sample rate (8–16kHz) and
        // produce garbage transcription. Detect via the active format's sample rate.
        let sr = dev.activeFormat.formatDescription.audioStreamBasicDescription?.mSampleRate ?? 48000
        if sr > 0 && sr < 22050 {
            return "Mic on a call/Bluetooth route (\(Int(sr))Hz) — quality may be poor"
        }
        if !dev.isConnected { return "Microphone disconnected" }
        return nil
    }

    func startRecording() {
        isRecording = true; wlog(">>> startRecording")
        let t0 = DispatchTime.now().uptimeNanoseconds
        func ms() -> UInt64 { (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }
        cfg = Config.load()  // pick up latest settings each session
        panel.show()         // indicator first: it is the "I heard you" signal
        if cfg.sound { Sounds.play("start") }
        DispatchQueue.main.async { self.setStatusIcon("mic.fill", tint: .systemRed) }
        // Warn (non-blocking) if the mic looks unusable — surfaces the #1 silent-failure
        // cause. AFTER show(): show() resets the panel to the dots state, so setting the
        // warning first meant it was wiped instantly.
        if let warn = micWarning() {
            wlog("MIC WARNING: \(warn)")
            panel.setPartial("⚠︎ \(warn)")
        }
        // Stuck secure input (usually loginwindow after a lock screen) suppresses ALL
        // keyDown events from event taps — Enter/Escape silently stop working while
        // Right ⌘ (a modifier event) still does. Surface it instead of failing mute.
        if IsSecureEventInputEnabled() {
            wlog("SECURE INPUT ACTIVE — Enter/Escape are blocked from the tap")
            panel.setPartial("⚠︎ Secure input is on — Enter won't work. Lock the screen (⌃⌘Q) and log back in.")
        }
        recorder.avoidBluetoothMic = cfg.avoidBluetoothMic ?? true
        recorder.pinnedDeviceUID = cfg.inputDeviceUID
        panel.setLocked(false)
        commandModeArmed = false
        // Streaming (Experimental): open the realtime session now and feed audio as it is captured,
        // so release only waits for the tail. Batch upload stays the fallback on any failure.
        streamClient = nil; recorder.onPCM24k = nil
        if (cfg.streamingASR ?? false), (cfg.asrProvider ?? "local") == "openai" {
            let hint = [cfg.promptHint, DictionaryRepo.biasPrompt(cfg: cfg)].filter { !$0.isEmpty }.joined(separator: ", ")
            if let c = OpenAIRealtime(model: cfg.asrCloudModel ?? "gpt-transcribe", prompt: hint,
                                      segmentSec: cfg.streamSegmentSec ?? 0, pauseMs: cfg.streamPauseMs ?? 600,
                                      carryContext: cfg.streamCarryContext ?? true) {
                streamClient = c
                recorder.onPCM24k = { [weak c] data in c?.append(pcm16: data) }
                wlog("streaming session opened")
            }
        }
        let tPre = ms()
        recorder.start()
        wlog("start timing: pre-capture \(tPre)ms, capture \(ms() - tPre)ms")
        // Live preview is OFF by default — it runs a second whisper process during recording,
        // which competes for compute. Only start it when explicitly enabled, and use a FAST model.
        // Gate on the SAME condition setPartial renders under: the compact panel has no room for
        // live text and drops every partial on the floor (see RecordingPanel.setPartial). With
        // panelStyle=compact this loop was spawning ~23 whisper-cli passes per dictation — each
        // re-transcribing the whole recording from t=0, so cost grew quadratically with length —
        // purely to produce text nothing displayed. 1289 discarded passes over one 9-hour session,
        // and because they are children of Sori.app they roll up into the battery menu's "Apps
        // Using Significant Energy" entry for Sori (diagnosed 2026-08-10).
        if (cfg.livePreview ?? false) && panel.style != "compact" { startPartialTimer() }
    }

    func cancelRecording() {
        isRecording = false; wlog(">>> cancelRecording (ESC)")
        stopPartialTimer()
        recorder.onPCM24k = nil; streamClient?.cancel(); streamClient = nil
        recorder.cancel()
        DispatchQueue.main.async {
            self.setStatusIcon("mic")
            self.panel.hide()
        }
    }

    // Live partial transcription: every ~2s, run a FAST model (base) on the growing WAV and
    // show the result in the panel. Runs at low QoS so it never starves the recording.
    private var partialTimer: DispatchSourceTimer?
    private var partialRunning = false
    private let partialQueue = DispatchQueue(label: "whisper.partial", qos: .utility)
    private func startPartialTimer() {
        wlog("partial timer START (model=\(cfg.partialModel ?? "ggml-base.bin"))")
        let t = DispatchSource.makeTimerSource(queue: partialQueue)
        // First fire at 1.0s so even short recordings get a preview; repeat every 1.2s.
        t.schedule(deadline: .now() + 1.0, repeating: 1.2)
        t.setEventHandler { [weak self] in
            guard let self, self.isRecording, !self.partialRunning else { return }
            let wav = workPath("sori.wav")
            guard FileManager.default.fileExists(atPath: wav),
                  let sz = try? FileManager.default.attributesOfItem(atPath: wav)[.size] as? Int,
                  (sz ?? 0) > 16000 else { return }   // need ~0.5s of audio
            self.partialRunning = true
            let snap = workPath("sori_partial.wav")
            // The live WAV's header is not finalized while recording (AVAudioFile only writes
            // the real length on close), so a plain copy has a 0-length header that whisper
            // reads as empty. Rebuild a VALID header around the raw PCM bytes instead.
            if !Self.rebuildPartialWav(from: wav, to: snap) { self.partialRunning = false; return }
            // FAST model for previews (base ~0.5s vs turbo ~1.4s). Final still uses cfg.model.
            let pm = self.cfg.partialModel ?? "ggml-base.bin"
            let model = (NSHomeDirectory() as NSString).appendingPathComponent(".sori-models/\(pm)")
            guard FileManager.default.fileExists(atPath: model) else {
                wlog("partial model missing: \(pm)"); self.partialRunning = false; return
            }
            let task = Process()
            task.launchPath = whisperTool("whisper-cli")
            task.arguments = ["-m", model, "-l", self.cfg.lang, "-nt", "-otxt", "-of", workPath("sori_partial"), snap]
            task.standardError = Pipe(); task.standardOutput = Pipe()
            do { try task.run() } catch { wlog("partial whisper launch failed: \(error)"); self.partialRunning = false; return }
            task.waitUntilExit()
            let txt = (try? String(contentsOfFile: workPath("sori_partial.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            wlog("partial: \"\(txt.prefix(60))\"")
            if self.isRecording, !txt.isEmpty { self.panel.setPartial(txt) }
            self.partialRunning = false
        }
        t.resume()
        partialTimer = t
    }
    private func stopPartialTimer() { partialTimer?.cancel(); partialTimer = nil }

    // Read raw PCM from the live (still-being-written) 16kHz mono 16-bit WAV, skipping its
    // 44-byte header, and write a fresh WAV with a CORRECT header sized to the data we have.
    static func rebuildPartialWav(from src: String, to dst: String) -> Bool {
        guard let raw = FileManager.default.contents(atPath: src), raw.count > 44 else { return false }
        let pcm = raw.subdata(in: 44..<raw.count)   // skip the (stale) source header
        let sampleRate: UInt32 = 16000, channels: UInt16 = 1, bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataLen = UInt32(pcm.count)
        var h = Data()
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        h.append("RIFF".data(using: .ascii)!)
        h.append(le(UInt32(36 + dataLen)))
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!)
        h.append(le(UInt32(16)))           // fmt chunk size
        h.append(le(UInt16(1)))            // PCM
        h.append(le(channels))
        h.append(le(sampleRate))
        h.append(le(byteRate))
        h.append(le(blockAlign))
        h.append(le(bits))
        h.append("data".data(using: .ascii)!)
        h.append(le(dataLen))
        h.append(pcm)
        do { try h.write(to: URL(fileURLWithPath: dst)); return true }
        catch { wlog("rebuildPartialWav write failed: \(error)"); return false }
    }

    // Whisper runs here, NEVER on the main thread. The event-tap callback runs on the
    // main run loop; blocking it for a multi-second transcription made macOS disable the
    // tap by timeout — which is why Right-⌘ and Enter randomly went dead after use.
    private let transcribeQueue = DispatchQueue(label: "whisper.transcribe", qos: .userInitiated)

    // Consecutive-dictation spacing state (see paste block).
    private var lastPasteEnd: Character?
    private var lastPasteAt = Date.distantPast

    func stopAndTranscribe() {
        isRecording = false; wlog(">>> stopAndTranscribe")
        stopPartialTimer()
        if cfg.sound { Sounds.play("stop") }
        DispatchQueue.main.async { self.setStatusIcon("waveform", tint: .systemBlue) }
        panel.setTranscribing()
        let cfg = self.cfg
        // Capture the submit intent PER SESSION. Transcription is async now — a shared
        // flag read seconds later could belong to a different, overlapping recording.
        let submit = submitAfterPaste
        submitAfterPaste = false
        // Read the target app NOW (main thread, before any async hop): this is where he is typing.
        let context = AppContext.capture()
        let asCommand = commandModeArmed
        commandModeArmed = false
        recorder.onPCM24k = nil
        let stream = streamClient; streamClient = nil
        if asCommand { stream?.cancel() }
        let selection = asCommand ? CommandMode.selectedText() : nil
        if asCommand { wlog("command mode: selection \(selection.map { "\($0.count) chars" } ?? "none")") }
        recorder.stop { url in
            if !asCommand { stream?.commit() }
            // Move the WAV to a unique path BEFORE queueing: a new recording restarts
            // /tmp/sori.wav immediately, which would clobber the file while a
            // still-running whisper reads it (transcription is async now).
            let unique = workPath("sori_\(UInt64(Date().timeIntervalSince1970 * 1000)).wav")
            do { try FileManager.default.moveItem(atPath: url.path, toPath: unique) }
            catch { wlog("WAV move FAILED: \(error)") }
            if let dir = cfg.keepRecordingsDir, !dir.isEmpty {
                let dst = (dir as NSString).appendingPathComponent((unique as NSString).lastPathComponent)
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                do { try FileManager.default.copyItem(atPath: unique, toPath: dst); wlog("kept \(dst)") }
                catch { wlog("keep FAILED: \(error)") }
            }
            self.transcribeQueue.async {
                if asCommand { self.runCommand(url: URL(fileURLWithPath: unique), cfg: cfg, selection: selection) }
                else { self.transcribe(url: URL(fileURLWithPath: unique), cfg: cfg, submit: submit, context: context, stream: stream) }
                try? FileManager.default.removeItem(atPath: unique)
            }
        }
    }

    // Posts a Return keystroke to the frontmost app (tagged so our tap ignores it).
    private func postEnter(_ reason: String) {
        let rsrc = wpttEventSource()
        let rd = CGEvent(keyboardEventSource: rsrc, virtualKey: 0x24, keyDown: true)
        let ru = CGEvent(keyboardEventSource: rsrc, virtualKey: 0x24, keyDown: false)
        rd?.post(tap: .cgAnnotatedSessionEventTap); ru?.post(tap: .cgAnnotatedSessionEventTap)
        wlog("pressed Enter (\(reason))")
    }

    // The consumed Enter is re-issued only if he is still in the app he pressed it in. If he
    // moved on while ASR ran, a forwarded Enter would submit whatever is in the NEW app's field.
    private func forwardEnter(_ reason: String, target: AppContext) {
        guard target.pid == 0 || NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            wlog("Enter NOT forwarded (\(reason)) — he left \(target.appName)")
            return
        }
        postEnter(reason)
    }

    // Paste-at-origin: returns nil at once when he is still in the app + field he dictated into.
    // Otherwise brings the target app (and its focused field) back to the front, waits until it
    // actually IS frontmost, then calls `body` with a closure that returns him to where he had
    // moved. Main thread only. Chrome/Electron honour AX focus set on an editable element;
    // when that fails the paste still goes to that app's own focused field.
    private func focusTarget(_ target: AppContext?, then body: @escaping (_ goBack: (() -> Void)?) -> Void) {
        guard cfg.pasteAtOrigin ?? true, let t = target, t.pid > 0 else { body(nil); return }
        let front = NSWorkspace.shared.frontmostApplication
        let nowEl = AppContext.focusedElement()
        let sameApp = front?.processIdentifier == t.pid
        let sameField: Bool = {
            guard let a = t.focusedElement, let b = nowEl else { return true }   // unknown → assume same
            return CFEqual(a, b)
        }()
        if sameApp && sameField { body(nil); return }
        guard let app = NSRunningApplication(processIdentifier: t.pid), !app.isTerminated else {
            wlog("paste target \(t.appName) is gone — pasting where he is")
            body(nil); return
        }
        wlog("he moved to \(front?.localizedName ?? "?")\(sameApp ? " (other field)" : "") — refocusing \(t.appName) for the paste")
        func refocus(_ el: AXUIElement?) {
            guard let el else { return }
            let r = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if r != .success { wlog("AX refocus failed (\(r.rawValue))") }
        }
        if !sameApp {
            app.activate(options: [])
            // Belt and braces for apps that ignore activate() from a background process.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(t.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        var tries = 0
        func settle() {
            tries += 1
            let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid
            if isFront || tries >= 12 {
                if !isFront { wlog("\(t.appName) did not come to front after \(tries) tries — pasting anyway") }
                refocus(t.focusedElement)
                let goBack: () -> Void = {
                    guard !sameApp, let f = front, !f.isTerminated else { refocus(nowEl); return }
                    f.activate(options: [])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { refocus(nowEl) }
                    wlog("returned him to \(f.localizedName ?? "?")")
                }
                body(goBack)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settle)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settle)
    }

    // detectLanguage() removed 2026-08-12. It ran a second ggml-base pass because
    // whisper's in-decode auto-detection was biased by the English style-anchor
    // prompt (Korean detected as English and TRANSLATED, 2026-07-22). Qwen3-ASR
    // takes no style prompt and does its own language ID over 52 languages, so
    // the pre-pass, the ggml-base model, and that failure mode are all gone.

    // Command Mode: transcribe the instruction, apply it to the selection (or hand off to the web).
    private func runCommand(url: URL, cfg: Config, selection: String?) {
        defer { DispatchQueue.main.async { self.panel.setCommandMode(false) } }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        QwenServer.ensureRunning(modelPath: cfg.asrModel ?? QwenServer.defaultRepo)
        var instruction: String? = nil
        if (cfg.asrProvider ?? "local") == "openai", QwenServer.hasSpeech(wav: url.path) != false {
            instruction = OpenAITranscribe.transcribe(wav: url.path, model: cfg.asrCloudModel ?? "gpt-transcribe", prompt: "")
        }
        if instruction == nil { instruction = QwenServer.transcribe(wav: url.path, lang: cfg.lang == "auto" ? "" : cfg.lang) }
        let inst = (instruction ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        wlog("command instruction=\"\(inst)\"")
        let outcome = CommandMode.run(instruction: inst, selection: selection)
        DispatchQueue.main.async {
            if !self.isRecording { self.setStatusIcon("mic"); self.panel.hide() }
            switch outcome {
            case .replace(let text):
                // The selection is still highlighted in the target app; ⌘V replaces it.
                let pb = NSPasteboard.general
                pb.declareTypes([.string], owner: nil); pb.setString(text, forType: .string)
                let src = wpttEventSource()
                let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                down?.flags = .maskCommand; up?.flags = .maskCommand
                down?.post(tap: .cgAnnotatedSessionEventTap); up?.post(tap: .cgAnnotatedSessionEventTap)
                self.lastPaste = LastPaste(pasted: text, final: text, raw: selection ?? "", at: Date(), showingRaw: false)
                wlog("command: replaced selection (\(text.count) chars)")
            case .openURL(let u):
                wlog("command: open \(u.absoluteString.prefix(80))")
                NSWorkspace.shared.open(u)
            case .refused(let why):
                wlog("command REFUSED: \(why)")
                self.panel.setError(why)
            }
        }
    }

    private func transcribe(url: URL, cfg: Config, submit: Bool, context: AppContext, stream: OpenAIRealtime? = nil) {
            let tStart = Date()
            var asrMs = 0, rewriteMs = 0
            let wavBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let audioMs = wavBytes > 44 ? (wavBytes - 44) / 32 : 0   // 16 kHz mono int16
            let keptPath: String = {
                guard let dir = cfg.keepRecordingsDir, !dir.isEmpty else { return "" }
                return (dir as NSString).appendingPathComponent(url.lastPathComponent)
            }()
            let repo = cfg.asrModel ?? QwenServer.defaultRepo
            // Clear the previous output FIRST: a stale out.txt would paste the
            // PREVIOUS session's transcript again.
            try? FileManager.default.removeItem(atPath: workPath("sori_out.txt"))
            guard FileManager.default.fileExists(atPath: url.path) else {
                wlog("transcribe ABORT — WAV missing at \(url.path)")
                DispatchQueue.main.async {
                    if !self.isRecording { self.setStatusIcon("mic"); self.panel.hide() }
                    if submit { self.forwardEnter("forwarded — no audio", target: context) }
                }
                return
            }
            // "auto" is passed straight through: Qwen3-ASR does its own language ID
            // across 52 languages, so the old ggml-base pre-detection pass is gone.
            let lang = cfg.lang == "auto" ? "" : cfg.lang
            // Vocabulary bias, capped at Config.maxBiasTerms. The Settings "Names &
            // custom words" field and the AI-terminology checkbox both feed this — they
            // were dead between the engine swap and 2026-08-12 (he spotted it in the UI).
            let vocabulary = DictionaryRepo.biasPrompt(cfg: cfg)

            QwenServer.ensureRunning(modelPath: repo)
            var text = ""
            var cloudText: String? = nil
            let tAsr = Date()
            var provider = "qwen"
            if (cfg.asrProvider ?? "local") == "openai" {
                // Local VAD gate first (silence / short tap → no upload, no cost, no hallucination).
                let gate = QwenServer.hasSpeech(wav: url.path)
                if gate == false {
                    cloudText = ""
                    stream?.cancel()
                    wlog("vad gate: no speech — cloud transcribe skipped")
                } else {
                    // Streaming session first (only the tail is pending), batch upload if it failed.
                    if let s = stream { cloudText = s.finish(timeout: 4) }
                    if let t = cloudText, let bad = TextCleanup.foreignScript(t) {
                        wlog("realtime transcript has a foreign script (\(bad)) — redoing with batch: \"\(t.prefix(80))\"")
                        cloudText = nil
                    }
                    if cloudText == nil {
                        let hint = [cfg.promptHint, vocabulary].filter { !$0.isEmpty }.joined(separator: ", ")
                        // The live model has no file endpoint; the batch fallback always uses gpt-transcribe there.
                        let model = cfg.asrCloudModel ?? "gpt-transcribe"
                        cloudText = OpenAITranscribe.transcribe(wav: url.path, model: model.hasPrefix("gpt-live") ? "gpt-transcribe" : model, prompt: hint)
                        if cloudText == nil { wlog("openai transcribe FAILED — falling back to local qwen") }
                    }
                }
            }
            if let c = cloudText {
                text = c
                provider = "openai"
                wlog("transcribed via openai")
            } else if let t = QwenServer.transcribe(wav: url.path, lang: lang, vocabulary: vocabulary) {
                text = t
                wlog("transcribed via qwen (lang=\(lang.isEmpty ? "auto" : lang))")
            } else {
                // No silent degradation: there is no second engine by design, so a
                // dead engine has to be visible rather than paste nothing and look
                // like the hotkey missed.
                wlog("qwen engine UNAVAILABLE — no transcript produced")
                DispatchQueue.main.async {
                    if !self.isRecording { self.setStatusIcon("exclamationmark.triangle", tint: .systemRed) }
                    self.panel.setError("Speech engine unavailable")
                    if submit { self.forwardEnter("forwarded — ASR engine down", target: context) }
                }
                return
            }
            asrMs = Int(Date().timeIntervalSince(tAsr) * 1000)
            let raw = text
            // Whisper-era list, trimmed 2026-09-03: Qwen3-ASR returns "" on silence (every
            // blank recording in the log since the engine swap came back 0 chars), so the
            // single common words whisper used to hallucinate — "okay", "ok", "so", "you",
            // "bye" — are no longer artifacts, they are dictations ("Okay." into a chat box
            // was being dropped as "no speech"). Bracket tokens and YouTube sign-offs stay.
            let silenceArtifacts: Set<String> = [
                "[blank_audio]", "(silence)", "[silence]", "[ silence ]", "[music]", "(music)",
                "thank you so much", "thanks for watching", "thanks for watching!",
                "please subscribe", "uh", "um", "mm",
                "subtitles by", "transcription by", "amara.org", "♪",
            ]

            // Trailing hallucination: whisper sometimes rides the silence AFTER you stop
            // talking and appends one of the stock artifacts above as its own segment, tacked
            // onto otherwise-real speech ("...let's grab lunch.\nThank you."). Strip only an
            // ISOLATED trailing segment that exactly matches — a genuine "thank you" you
            // actually say (e.g. an email sign-off) is always part of a longer segment with
            // other words, so it never normalizes down to a bare match on its own line.
            let rawSegments = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if rawSegments.count >= 2 {
                let lastNorm = rawSegments.last!.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-—\n\t\""))
                if silenceArtifacts.contains(lastNorm) {
                    wlog("trailing hallucination segment dropped (\"\(rawSegments.last!)\")")
                    text = rawSegments.dropLast().joined(separator: "\n")
                }
            }

            // No-speech detection: whisper hallucinates stock phrases on silence.
            // Normalize (lowercase, strip trailing/leading punctuation+space) before matching,
            // so "Thank you", "Thank you.", "Thank you!" all collapse to one key.
            let norm = text.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-—\n\t\""))
            // Prompt echo: on silence/very short audio whisper sometimes continues the
            // PROMPT instead of transcribing — empirically it pastes the style anchor's
            // tail ("Let's begin.") on ~half of accidental blank recordings. Suppress
            // any output that is a fragment of the anchor or a leaked section label.
            let promptEcho = (norm.count >= 6 && Config.styleAnchor.lowercased().contains(norm))
                || norm.hasPrefix("names:") || norm.hasPrefix("glossary:")
            if text.isEmpty || norm.isEmpty || silenceArtifacts.contains(norm) || promptEcho {
                if promptEcho { wlog("prompt echo suppressed (\"\(norm)\")") }
                wlog("no speech detected (raw=\"\(raw)\") — not pasting")
                DispatchQueue.main.async {
                    // A NEW recording may already be running (transcription is async) —
                    // don't stomp its panel or status icon.
                    if !self.isRecording {
                        self.setStatusIcon("mic")
                        self.panel.setPartial("No speech detected")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if !self.isRecording { self.panel.hide() }
                        }
                    }
                    // The user's Enter ended this recording and we CONSUMED it. If there is
                    // no dictation to paste, forward the Enter anyway — swallowing it made
                    // "press Enter" feel dead whenever whisper heard nothing.
                    if submit { self.forwardEnter("forwarded — no speech", target: context) }
                }
                return
            }

            // Whisper splits long audio into segments separated by newlines; pasting a
            // literal "\n" into a chat input submits early or breaks the message. For
            // dictation, transcript-internal newlines are always spaces.
            text = text.replacingOccurrences(of: "\n", with: " ")
                       .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            text = TextCleanup.collapseRepetitionLoop(text)
            text = DictionaryRepo.apply(text)
            // Style: the destination category (per-app override, else app kind) picks the tone
            // and the cleanup level. None = raw; Light = rules; Medium = deletion-only LLM;
            // High = Smart Rewrite with the category's tone.
            let category = StyleResolver.category(for: context)
            let style = StyleResolver.setting(cfg: cfg, category: category)
            let level = style.levelValue
            wlog("style: \(category.rawValue) \(style.tone)/\(style.level) — \(context.summary)")
            // Spoken formatting ("new paragraph", "scratch that"): split into pieces first so the
            // command words never reach the LLM; each piece is cleaned/rewritten on its own.
            let pieces: [Formatting.Piece] = Formatting.hasCommands(text) ? Formatting.parse(text) : [.text(text)]
            if pieces.count > 1 { wlog("formatting commands: \(pieces.count) pieces") }
            let tRewrite = Date()
            func process(_ piece: String) -> String {
                var t = piece
                if level != .none { t = TextCleanup.clean(t) }
                // LLM passes skip short dictations: quick commands ("open Notion", "yes let's do it")
                // have nothing to fix, and the ~1s Groq round-trip is pure latency there.
                let wordCount = t.split(whereSeparator: { $0.isWhitespace }).count
                if level == .high && wordCount >= 3 {
                    if let r = LLMCleanup.smartRewrite(t, context: context, tone: style.toneValue, deadline: wordCount > 100 ? 1.8 : 1.2) { t = r }
                } else if level == .medium && wordCount >= 5, let rewritten = LLMCleanup.rewrite(t) {
                    t = TextCleanup.clean(rewritten)   // a deleted leading filler leaves a lowercase start
                }
                return t
            }
            if level == .high { wlog("smart rewrite ctx: \(context.kind.rawValue) — \(context.summary)\(context.fieldText.isEmpty ? "" : " — before: \(context.fieldText.count) chars")") }
            // Instant paste (Experimental): put the rule-cleaned text in the field now and swap in the
            // rewrite when it arrives — only if the field still holds exactly what we pasted (AX check,
            // no ⇧← fallback), and never when this dictation was submitted with Enter.
            let instant = (cfg.instantPaste ?? false) && level == .high && !submit && pieces.count == 1
            var instantId: Int64? = nil
            if instant, case .text(let t0) = pieces[0] {
                let quick = TextCleanup.clean(t0)
                let id = DictationRepo.insert(.init(ts: tStart, context: context, raw: raw, final: quick, provider: provider,
                                                    audioMs: audioMs, asrMs: asrMs, rewriteMs: 0,
                                                    totalMs: Int(Date().timeIntervalSince(tStart) * 1000), audioPath: keptPath))
                instantId = id
                DispatchQueue.main.sync {
                    if !self.isRecording { self.setStatusIcon("mic"); self.panel.hide() }
                    self.paste(quick, submit: false, dictationId: id, startedAt: tStart, target: context)
                }
                wlog("instant paste (\(quick.count) chars), refining")
            }
            var processed = [String](repeating: "", count: pieces.count)
            let group = DispatchGroup()
            for (i, piece) in pieces.enumerated() {
                guard case .text(let t) = piece else { continue }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { processed[i] = process(t); group.leave() }
            }
            group.wait()
            text = Formatting.join(pieces.enumerated().map { i, p in
                if case .br = p { return p }
                return .text(processed[i])
            })
            rewriteMs = Int(Date().timeIntervalSince(tRewrite) * 1000)
            // Snippets: a dictation that opens with a trigger phrase becomes its expansion.
            if let (expanded, trig) = SnippetRepo.expand(text) {
                wlog("snippet \"\(trig)\" expanded (\(expanded.count) chars)")
                text = expanded
            }
            wlog("raw=\"\(raw)\" -> final=\"\(text)\"")
            if let id = instantId {
                // Refine in place: replace the quick paste with the rewrite if it differs and the
                // field still shows exactly the quick text at the caret.
                let finalText = text
                Database.shared.run("UPDATE dictations SET final=?, rewrite_ms=? WHERE id=?", [.text(finalText), .int(Int64(rewriteMs)), .int(id)])
                DispatchQueue.main.async {
                    guard let lp = self.lastPaste, lp.showingRaw == false, finalText != lp.pasted else { return }
                    if self.selectBack(lp.pasted, allowKeyFallback: false) {
                        let pb = NSPasteboard.general
                        pb.declareTypes([.string], owner: nil); pb.setString(finalText, forType: .string)
                        let src = wpttEventSource()
                        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
                        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                        down?.flags = .maskCommand; up?.flags = .maskCommand
                        down?.post(tap: .cgAnnotatedSessionEventTap); up?.post(tap: .cgAnnotatedSessionEventTap)
                        self.lastPaste = LastPaste(pasted: finalText, final: finalText, raw: raw, at: Date(), showingRaw: false)
                        wlog("instant paste refined in place")
                    } else {
                        wlog("instant paste: field changed, refinement skipped (raw kept)")
                    }
                }
                return
            }
            // Every dictation that produced text is a row, pasted or not — Home, stats, undo and
            // the eval set all read this one table.
            let dictationId = DictationRepo.insert(.init(
                ts: tStart, context: context, raw: raw, final: text, provider: provider,
                audioMs: audioMs, asrMs: asrMs, rewriteMs: rewriteMs,
                totalMs: Int(Date().timeIntervalSince(tStart) * 1000), audioPath: keptPath))

            DispatchQueue.main.async {
                // Don't reset the icon / hide the panel if a NEW recording already started.
                if !self.isRecording { self.setStatusIcon("mic"); self.panel.hide() }
                if !text.isEmpty {
                    let submitNow = (cfg.pressEnter ?? false) || submit
                    self.paste(text, submit: submitNow, dictationId: dictationId, startedAt: tStart, target: context)
                }
            }
    }

    // Puts `text` on the clipboard and posts ⌘V to the frontmost app. Shared by the dictation
    // pipeline and "Paste Last Transcript". Main thread only.
    func paste(_ input: String, submit: Bool, dictationId: Int64?, startedAt: Date? = nil, target: AppContext? = nil) {
        focusTarget(target) { goBack in
            self.pasteNow(input, submit: submit, dictationId: dictationId, startedAt: startedAt, goBack: goBack)
        }
    }

    private func pasteNow(_ input: String, submit: Bool, dictationId: Int64?, startedAt: Date?, goBack: (() -> Void)?) {
        var text = input
        // Consecutive-dictation spacing: back-to-back dictations pasted with no
        // separator ("sentence.Sentence"). If the previous paste ended in a
        // non-whitespace char recently, and this one starts with a word char,
        // prepend one space. (We can't read the focused field; recency is the
        // best available proxy for "appending to the same text".)
        if let lastEnd = self.lastPasteEnd,
           Date().timeIntervalSince(self.lastPasteAt) < 600,
           !lastEnd.isWhitespace,
           let first = text.first,
           first.isLetter || first.isNumber {
            text = " " + text
        }
        self.lastPasteEnd = text.last
        self.lastPasteAt = Date()
        // Text always stays on the clipboard afterwards, so ⌘V recovers it
        // if the auto-paste lands in the wrong place or gets cancelled.
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil); pb.setString(text, forType: .string)
        let src = wpttEventSource()
        // ⌘V paste
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap); up?.post(tap: .cgAnnotatedSessionEventTap)
        wlog("pasted (clipboard retained for ⌘V recovery)")
        if let id = dictationId {
            DictationRepo.markPasted(id, totalMs: startedAt.map { Int(Date().timeIntervalSince($0) * 1000) })
            if let d = DictationRepo.get(id) { lastPaste = LastPaste(pasted: text, final: text, raw: d.raw, at: Date(), showingRaw: false) }
        } else {
            lastPaste = nil
        }
        // Learn-from-edits: remember what we pasted; if the user soon copies a close
        // variant (an in-place correction), infer a replacement rule — and also watch the
        // field itself (AX value) for a typed-over correction, which is how people actually fix it.
        if cfg.learnEdits ?? true {
            self.watchForCorrection(of: text)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if !Learn.fieldWatchSkip.contains(front) { self.watchFieldForCorrection(of: text) }
        }
        // Press Enter to submit when: the global setting is on, OR the user
        // ended this recording by pressing Enter (which we consumed).
        if submit {
            // 0.3s: slow targets (browsers, Electron apps) need time to process
            // the ⌘V before the Return arrives, or the submit fires empty.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.postEnter("submit")
                if let goBack { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: goBack) }
            }
        } else if let goBack {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: goBack)
        }
    }

    // Learn-from-edits: poll the pasteboard for ~20s after a paste. If the user selects
    // a corrected version of the dictation and copies it (⌘C), and the change is small
    // (a word or two), infer a from→to replacement and persist it immediately.
    private var correctionGen = 0
    func watchForCorrection(of pasted: String) {
        // Each new paste supersedes any watcher from a previous dictation. Without this,
        // the NEXT dictation's own clipboard write looks like a "user correction" of the
        // last one and gets learned as a rule (observed: "Hello." -> "*sad music*", a
        // whisper hallucination promoted to a permanent auto-correction).
        correctionGen += 1
        let gen = correctionGen
        let pb = NSPasteboard.general
        let startChange = pb.changeCount
        let original = pasted
        var ticks = 0
        func tick() {
            guard gen == self.correctionGen else { return }   // superseded by a newer paste
            ticks += 1
            if pb.changeCount != startChange,
               let now = pb.string(forType: .string),
               now != original, !now.isEmpty {
                self.considerCorrection(from: original, to: now)
                return
            }
            if ticks < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: tick) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: tick)
    }

    private func considerCorrection(from: String, to: String) {
        guard let (f, t) = Learn.correction(pasted: from, edited: to) else { return }
        // Learn on the FIRST confident correction. Requiring the same edit twice within
        // a 6s clipboard window meant it effectively never learned anything.
        DictionaryRepo.upsertLearned(from: f, to: t)
        wlog("LEARNED correction \"\(f)\" -> \"\(t)\" (auto-applied going forward)")
    }
}

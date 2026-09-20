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
    var settings: SettingsController?
    var hub: HubController?

    var rightCmdDown = false
    var otherKeyDuringCmd = false
    var cmdDownTimeNs: UInt64 = 0      // CGEvent.timestamp of the right ⌘ down (ns since boot)
    var startedThisPress = false        // did this ⌘-press start a recording?
    var submitAfterPaste = false        // set when Enter ended the recording — auto-press Enter after paste
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
                // else: quick click that started it -> tap-on, keep recording (mirrors TAP-on)
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
        menu.addItem(NSMenuItem(title: "Open Sori Hub", action: #selector(openHub), keyEquivalent: "h"))
        let lastItem = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLastTranscript), keyEquivalent: "")
        lastItem.isEnabled = DictationRepo.last() != nil
        menu.addItem(lastItem)
        menu.addItem(NSMenuItem.separator())
        let cleanupItem = NSMenuItem(title: "Filler Cleanup (Groq)", action: #selector(toggleLLMCleanup(_:)), keyEquivalent: "")
        cleanupItem.state = (cfg.llmCleanup ?? false) ? .on : .off
        menu.addItem(cleanupItem)
        let rewriteItem = NSMenuItem(title: "Smart Rewrite (app-aware, Groq)", action: #selector(toggleSmartRewrite(_:)), keyEquivalent: "")
        rewriteItem.state = (cfg.smartRewrite ?? false) ? .on : .off
        menu.addItem(rewriteItem)
        // Reachable from the menu bar too — otherwise turning the indicator off would hide the
        // only way to turn it back on.
        let indicatorItem = NSMenuItem(title: "Floating Indicator", action: #selector(toggleCompactIndicator(_:)), keyEquivalent: "")
        indicatorItem.state = (cfg.compactHidden ?? false) ? .off : .on
        menu.addItem(indicatorItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sori \(soriVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Explicit target on every item: a menu popped up from the .nonactivatingPanel never
        // becomes key, so nothing may depend on the responder chain to find an action.
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc func toggleLLMCleanup(_ sender: NSMenuItem) {
        cfg.llmCleanup = !(cfg.llmCleanup ?? false)
        sender.state = (cfg.llmCleanup ?? false) ? .on : .off
        cfg.save()
        // The sender may be a throwaway right-click menu; rebuild the bar's so both agree.
        statusItem.menu = buildMainMenu()
        wlog("llmCleanup toggled -> \(cfg.llmCleanup ?? false)")
    }

    @objc func toggleSmartRewrite(_ sender: NSMenuItem) {
        cfg.smartRewrite = !(cfg.smartRewrite ?? false)
        cfg.save()
        statusItem.menu = buildMainMenu()
        wlog("smartRewrite toggled -> \(cfg.smartRewrite ?? false)")
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

    @objc func openHub() {
        if hub == nil { hub = HubController() }
        hub?.show()
        wlog("hub opened")
    }

    // From the menu bar / indicator menu: the target app keeps focus (the status menu and the
    // .nonactivatingPanel never take it), so the paste lands where the caret is.
    @objc func pasteLastTranscript() {
        guard let d = DictationRepo.last() else { return }
        wlog("paste last transcript (#\(d.id))")
        paste(d.final, submit: false, dictationId: nil)
    }

    @objc func openSettings() {
        if settings == nil {
            settings = SettingsController()
            settings?.onSave = { [weak self] c in
                self?.cfg = c
                self?.panel.style = c.panelStyle ?? "classic"
                // Settings writes the whole config back, so re-apply the indicator's visibility
                // and rebuild the menu from it — otherwise the checkmark and the screen disagree.
                self?.panel.compactHidden = c.compactHidden ?? false
                self?.statusItem.menu = self?.buildMainMenu()
                wlog("settings applied")
            }
        } else { settings?.reloadFromDisk() }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
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
                    if delegate.startedThisPress {
                        // This press started the recording.
                        if wasHold && delegate.isRecording {
                            wlog("HOLD release (\(heldNs/1_000_000)ms) -> stop")
                            delegate.stopAndTranscribe()
                        } else if !wasHold {
                            // Quick tap that started recording -> stay recording (toggle-on).
                            wlog("TAP-on (\(heldNs/1_000_000)ms) -> keep recording")
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
        cfg = Config.load()  // pick up latest settings each session
        if cfg.sound { Sounds.play("start") }
        DispatchQueue.main.async { self.setStatusIcon("mic.fill", tint: .systemRed) }
        panel.show()
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
        recorder.start()
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
        recorder.stop { url in
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
                self.transcribe(url: URL(fileURLWithPath: unique), cfg: cfg, submit: submit, context: context)
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

    // detectLanguage() removed 2026-08-12. It ran a second ggml-base pass because
    // whisper's in-decode auto-detection was biased by the English style-anchor
    // prompt (Korean detected as English and TRANSLATED, 2026-07-22). Qwen3-ASR
    // takes no style prompt and does its own language ID over 52 languages, so
    // the pre-pass, the ggml-base model, and that failure mode are all gone.

    private func transcribe(url: URL, cfg: Config, submit: Bool, context: AppContext) {
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
                    if submit { self.postEnter("forwarded — no audio") }
                }
                return
            }
            // "auto" is passed straight through: Qwen3-ASR does its own language ID
            // across 52 languages, so the old ggml-base pre-detection pass is gone.
            let lang = cfg.lang == "auto" ? "" : cfg.lang
            // Vocabulary bias, capped at Config.maxBiasTerms. The Settings "Names &
            // custom words" field and the AI-terminology checkbox both feed this — they
            // were dead between the engine swap and 2026-08-12 (he spotted it in the UI).
            let vocabulary = cfg.biasPrompt

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
                    wlog("vad gate: no speech — cloud transcribe skipped")
                } else {
                    let hint = [cfg.promptHint, vocabulary].filter { !$0.isEmpty }.joined(separator: ", ")
                    cloudText = OpenAITranscribe.transcribe(wav: url.path, model: cfg.asrCloudModel ?? "gpt-transcribe", prompt: hint)
                    if cloudText == nil { wlog("openai transcribe FAILED — falling back to local qwen") }
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
                    self.panel.hide()
                    if submit { self.postEnter("forwarded — ASR engine down") }
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
                    if submit { self.postEnter("forwarded — no speech") }
                }
                return
            }

            // Whisper splits long audio into segments separated by newlines; pasting a
            // literal "\n" into a chat input submits early or breaks the message. For
            // dictation, transcript-internal newlines are always spaces.
            text = text.replacingOccurrences(of: "\n", with: " ")
                       .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            text = TextCleanup.collapseRepetitionLoop(text)
            text = cfg.applyReplacements(text)
            // Wispr-Flow-style cleanup (rule-based): strip fillers, fix disfluencies, tidy.
            if cfg.cleanupEnabled ?? true { text = TextCleanup.clean(text) }
            // Optional Tier 2 LLM rewrite for grammar/redundancy. Skipped for short
            // dictations: quick commands ("open Notion", "yes let's do it") have no
            // fillers to strip, and the ~1s Groq round-trip is pure latency there.
            let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
            var rewrote = false
            let tRewrite = Date()
            if (cfg.smartRewrite ?? false) && wordCount >= 3 {
                wlog("smart rewrite ctx: \(context.kind.rawValue) — \(context.summary)")
                if let r = LLMCleanup.smartRewrite(text, context: context) { text = r; rewrote = true }
            }
            if !rewrote && (cfg.llmCleanup ?? false) && wordCount >= 5, let rewritten = LLMCleanup.rewrite(text) {
                text = rewritten
                // A deleted leading filler ("Um, so ...") leaves a lowercase start; re-tidy.
                if cfg.cleanupEnabled ?? true { text = TextCleanup.clean(text) }
            }
            rewriteMs = Int(Date().timeIntervalSince(tRewrite) * 1000)
            wlog("raw=\"\(raw)\" -> final=\"\(text)\"")
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
                    self.paste(text, submit: submitNow, dictationId: dictationId, startedAt: tStart)
                }
            }
    }

    // Puts `text` on the clipboard and posts ⌘V to the frontmost app. Shared by the dictation
    // pipeline and "Paste Last Transcript". Main thread only.
    func paste(_ input: String, submit: Bool, dictationId: Int64?, startedAt: Date? = nil) {
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
        }
        // Learn-from-edits: remember what we pasted; if the user soon copies a close
        // variant (an in-place correction), infer a replacement rule.
        if cfg.learnEdits ?? true { self.watchForCorrection(of: text) }
        // Press Enter to submit when: the global setting is on, OR the user
        // ended this recording by pressing Enter (which we consumed).
        if submit {
            // 0.3s: slow targets (browsers, Electron apps) need time to process
            // the ⌘V before the Return arrives, or the submit fires empty.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.postEnter("submit")
            }
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
        // Only learn small, word-level diffs (not a whole-sentence rewrite).
        // Align from BOTH ends so an inserted/removed word doesn't shift every
        // later token into a "diff" (the old same-index compare bailed on those).
        let fa = from.split(separator: " ").map(String.init)
        let ta = to.split(separator: " ").map(String.init)
        guard !fa.isEmpty, !ta.isEmpty, abs(fa.count - ta.count) <= 2 else { return }
        var i = 0
        while i < min(fa.count, ta.count), fa[i] == ta[i] { i += 1 }
        var j = 0
        while j < min(fa.count, ta.count) - i, fa[fa.count - 1 - j] == ta[ta.count - 1 - j] { j += 1 }
        let f = fa[i..<(fa.count - j)].joined(separator: " ")
        let t = ta[i..<(ta.count - j)].joined(separator: " ")
        // The differing span must be short (a word or two) — otherwise it's a rewrite.
        guard f.count >= 2, f.count <= 40, !t.isEmpty, t.count <= 40,
              f.lowercased() != t.lowercased() else { return }
        guard f.split(separator: " ").count <= 3, t.split(separator: " ").count <= 3 else { return }
        // Learn on the FIRST confident correction. Requiring the same edit twice within
        // a 6s clipboard window meant it effectively never learned anything.
        var c = Config.load()
        var learned = c.learnedReplacements ?? []
        let manual = c.replacements
        if manual.contains(where: { $0.from.lowercased() == f.lowercased() }) { return }
        if let idx = learned.firstIndex(where: { $0.from.lowercased() == f.lowercased() }) {
            learned[idx].to = t   // user corrected the correction — update it
        } else {
            learned.append(Replacement(from: f, to: t))
        }
        c.learnedReplacements = learned
        c.save()
        self.cfg = c
        wlog("LEARNED correction \"\(f)\" -> \"\(t)\" (auto-applied going forward)")
    }
}

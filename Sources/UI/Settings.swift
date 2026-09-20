import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Settings window (Spokenly-style: sidebar + section panes)
final class SettingsController: NSWindowController, NSWindowDelegate {
    var onSave: ((Config) -> Void)?
    private var cfg = Config.load()

    // controls
    private var modelPopup: NSPopUpButton!
    private var langPopup: NSPopUpButton!
    private var hintField: NSTextField!
    private var soundCheck: NSButton!
    private var loginCheck: NSButton!
    private var aiTermsCheck: NSButton!
    private var pressEnterCheck: NSButton!
    private var panelStyleSegment: NSSegmentedControl!
    private var replTable: NSTableView!

    // layout
    private let sidebarW: CGFloat = 168
    private var sidebar: NSStackView!
    private var content: NSView!
    private var panes: [String: NSView] = [:]
    private var navButtons: [NSButton] = []
    private let sections = ["General", "Vocabulary", "Sounds", "About"]

    private let brand = NSColor(calibratedRed: 0.80, green: 0.18, blue: 0.23, alpha: 1)

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Sori"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.center()
        self.init(window: win)
        win.delegate = self
        buildShell()
        select("General")
    }

    // MARK: shell (sidebar + content area)
    private func buildShell() {
        cfg = Config.load()
        // Show auto-learned corrections in the same table so they can be reviewed,
        // edited, or deleted. saveTapped() writes the merged list back to `replacements`.
        cfg.replacements += cfg.learnedReplacements ?? []
        cfg.learnedReplacements = []
        guard let cv = window?.contentView else { return }
        cv.subviews.forEach { $0.removeFromSuperview() }
        cv.wantsLayer = true

        // Sidebar background (translucent)
        let side = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: cv.bounds.height))
        side.autoresizingMask = [.height]
        side.material = .sidebar; side.blendingMode = .behindWindow; side.state = .active
        cv.addSubview(side)

        // App title in sidebar
        let title = NSTextField(labelWithString: "Sori")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.frame = NSRect(x: 18, y: cv.bounds.height - 56, width: 140, height: 22)
        title.autoresizingMask = [.minYMargin]
        side.addSubview(title)
        let sub = NSTextField(labelWithString: "Voice → Text")
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 18, y: cv.bounds.height - 74, width: 140, height: 16)
        sub.autoresizingMask = [.minYMargin]
        side.addSubview(sub)

        // Nav buttons
        navButtons.removeAll()
        var y = cv.bounds.height - 120
        for s in sections {
            let b = NSButton(title: "  " + s, target: self, action: #selector(navTapped(_:)))
            b.bezelStyle = .inline; b.isBordered = false
            b.frame = NSRect(x: 12, y: y, width: sidebarW - 24, height: 30)
            b.autoresizingMask = [.minYMargin]
            b.alignment = .left
            b.font = .systemFont(ofSize: 13, weight: .medium)
            b.contentTintColor = .labelColor
            b.wantsLayer = true; b.layer?.cornerRadius = 7
            b.identifier = NSUserInterfaceItemIdentifier(s)
            side.addSubview(b); navButtons.append(b)
            y -= 36
        }

        // Content area
        content = NSView(frame: NSRect(x: sidebarW, y: 0, width: cv.bounds.width - sidebarW, height: cv.bounds.height))
        content.autoresizingMask = [.width, .height]
        cv.addSubview(content)

        panes = [
            "General": buildGeneralPane(),
            "Vocabulary": buildVocabPane(),
            "Sounds": buildSoundsPane(),
            "About": buildAboutPane(),
        ]
        for (_, p) in panes { p.isHidden = true; content.addSubview(p) }

        // Save bar (bottom of content)
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveBtn.frame = NSRect(x: content.bounds.width - 100, y: 16, width: 84, height: 30)
        saveBtn.autoresizingMask = [.minXMargin]
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        saveBtn.contentTintColor = brand
        content.addSubview(saveBtn)
    }

    // MARK: helpers
    private func sectionHeader(_ s: String, _ pane: NSView, _ y: CGFloat) {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 20, weight: .bold)
        l.frame = NSRect(x: 28, y: y, width: 400, height: 28); pane.addSubview(l)
    }
    private func fieldLabel(_ s: String, _ pane: NSView, _ y: CGFloat) {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .medium); l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 28, y: y, width: 420, height: 16); pane.addSubview(l)
    }
    private func card(_ pane: NSView, _ rect: NSRect) -> NSView {
        let c = NSView(frame: rect); c.wantsLayer = true
        c.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        c.layer?.cornerRadius = 10
        c.layer?.borderWidth = 0.5
        c.layer?.borderColor = NSColor.separatorColor.cgColor
        pane.addSubview(c); return c
    }

    // MARK: General pane
    private func buildGeneralPane() -> NSView {
        let p = NSView(frame: content.bounds); p.autoresizingMask = [.width, .height]
        let H = p.bounds.height
        sectionHeader("General", p, H - 56)

        // Lists Qwen3-ASR MLX quants, not ggml files. Before 2026-08-12 this listed
        // ~/.sori-models/*.bin and wrote cfg.model — which nothing had read since the
        // engine swap, so the pane confidently displayed a model that was not running.
        fieldLabel("Model", p, H - 100)
        modelPopup = NSPopUpButton(frame: NSRect(x: 28, y: H - 128, width: 300, height: 26))
        let repos = [
            "mlx-community/Qwen3-ASR-1.7B-8bit",   // default: best accuracy/size on this Mac
            "mlx-community/Qwen3-ASR-1.7B-4bit",   // smaller/faster, untested here
            "mlx-community/Qwen3-ASR-0.6B-8bit",   // fallback for low memory, untested here
        ]
        let current = cfg.asrModel ?? QwenServer.defaultRepo
        modelPopup.addItems(withTitles: repos.contains(current) ? repos : repos + [current])
        modelPopup.selectItem(withTitle: current)
        p.addSubview(modelPopup)

        fieldLabel("Language", p, H - 168)
        langPopup = NSPopUpButton(frame: NSRect(x: 28, y: H - 196, width: 160, height: 26))
        let langs = ["en","ko","ja","zh","es","fr","de","auto"]
        langPopup.addItems(withTitles: langs)
        langPopup.selectItem(withTitle: langs.contains(cfg.lang) ? cfg.lang : "en")
        p.addSubview(langPopup)

        let c = card(p, NSRect(x: 28, y: H - 406, width: p.bounds.width - 56, height: 190))
        let styleLabel = NSTextField(labelWithString: "Floating panel")
        styleLabel.font = .systemFont(ofSize: 12, weight: .medium); styleLabel.textColor = .secondaryLabelColor
        styleLabel.frame = NSRect(x: 16, y: 154, width: 320, height: 16); c.addSubview(styleLabel)
        panelStyleSegment = NSSegmentedControl(labels: ["Classic", "Compact"], trackingMode: .selectOne,
                                                target: nil, action: nil)
        panelStyleSegment.frame = NSRect(x: 16, y: 126, width: 220, height: 24)
        panelStyleSegment.selectedSegment = (cfg.panelStyle == "compact") ? 1 : 0
        c.addSubview(panelStyleSegment)
        let styleHint = NSTextField(labelWithString: "Compact: a small draggable indicator, no live-text preview.")
        styleHint.font = .systemFont(ofSize: 11); styleHint.textColor = .secondaryLabelColor
        styleHint.frame = NSRect(x: 16, y: 106, width: c.bounds.width - 32, height: 16); c.addSubview(styleHint)
        loginCheck = NSButton(checkboxWithTitle: "  Launch at login", target: nil, action: nil)
        loginCheck.frame = NSRect(x: 16, y: 74, width: 320, height: 22)
        loginCheck.state = LoginItem.isEnabled() ? .on : .off; c.addSubview(loginCheck)
        pressEnterCheck = NSButton(checkboxWithTitle: "  Press Enter after pasting (submit automatically)",
                                   target: nil, action: nil)
        pressEnterCheck.frame = NSRect(x: 16, y: 46, width: 360, height: 22)
        pressEnterCheck.state = (cfg.pressEnter ?? false) ? .on : .off; c.addSubview(pressEnterCheck)
        let hint = NSTextField(labelWithString: "Hold Right ⌘ to talk, or tap to start and tap again to stop. Right ⌘ + Enter sends. Text stays on the clipboard — press ⌘V to recover it.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 10, width: c.bounds.width - 32, height: 30)
        (hint.cell as? NSTextFieldCell)?.wraps = true; hint.lineBreakMode = .byWordWrapping
        c.addSubview(hint)
        return p
    }

    // MARK: Vocabulary pane (names + AI terms + corrections)
    private func buildVocabPane() -> NSView {
        let p = NSView(frame: content.bounds); p.autoresizingMask = [.width, .height]
        let H = p.bounds.height
        sectionHeader("Vocabulary", p, H - 56)

        fieldLabel("Names & custom words (helps spell them right)", p, H - 96)
        hintField = NSTextField(frame: NSRect(x: 28, y: H - 124, width: p.bounds.width - 56, height: 26))
        hintField.stringValue = cfg.promptHint
        hintField.placeholderString = "your name, teammates, product names"
        p.addSubview(hintField)

        aiTermsCheck = NSButton(checkboxWithTitle: "  Recognize modern AI / dev terminology (ChatGPT, RAG, LangGraph…)",
                                target: nil, action: nil)
        aiTermsCheck.frame = NSRect(x: 28, y: H - 158, width: p.bounds.width - 56, height: 22)
        aiTermsCheck.state = (cfg.aiTermsEnabled ?? true) ? .on : .off
        p.addSubview(aiTermsCheck)

        fieldLabel("Auto-corrections  (heard → replace with)", p, H - 196)
        let scroll = NSScrollView(frame: NSRect(x: 28, y: 64, width: p.bounds.width - 56, height: H - 270))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 8
        replTable = NSTableView(frame: scroll.bounds)
        let c1 = NSTableColumn(identifier: .init("from")); c1.title = "Heard"; c1.width = 230
        let c2 = NSTableColumn(identifier: .init("to")); c2.title = "Replace with"; c2.width = 230
        replTable.addTableColumn(c1); replTable.addTableColumn(c2)
        replTable.dataSource = self; replTable.delegate = self
        replTable.usesAlternatingRowBackgroundColors = true
        replTable.rowHeight = 24
        scroll.documentView = replTable; p.addSubview(scroll)

        let addBtn = NSButton(title: "+", target: self, action: #selector(addRow))
        addBtn.frame = NSRect(x: 28, y: 22, width: 36, height: 30); addBtn.bezelStyle = .rounded
        p.addSubview(addBtn)
        let delBtn = NSButton(title: "–", target: self, action: #selector(delRow))
        delBtn.frame = NSRect(x: 70, y: 22, width: 36, height: 30); delBtn.bezelStyle = .rounded
        p.addSubview(delBtn)
        return p
    }

    // MARK: Sounds pane
    private func buildSoundsPane() -> NSView {
        let p = NSView(frame: content.bounds); p.autoresizingMask = [.width, .height]
        let H = p.bounds.height
        sectionHeader("Sounds", p, H - 56)

        let c = card(p, NSRect(x: 28, y: H - 200, width: p.bounds.width - 56, height: 120))
        soundCheck = NSButton(checkboxWithTitle: "  Play sound on start / stop", target: nil, action: nil)
        soundCheck.frame = NSRect(x: 16, y: 82, width: 320, height: 22)
        soundCheck.state = cfg.sound ? .on : .off; c.addSubview(soundCheck)

        let playStart = NSButton(title: "▶ Preview start", target: self, action: #selector(previewStart))
        playStart.frame = NSRect(x: 16, y: 40, width: 150, height: 30); playStart.bezelStyle = .rounded
        c.addSubview(playStart)
        let playStop = NSButton(title: "▶ Preview stop", target: self, action: #selector(previewStop))
        playStop.frame = NSRect(x: 176, y: 40, width: 150, height: 30); playStop.bezelStyle = .rounded
        c.addSubview(playStop)

        let note = NSTextField(labelWithString: "Two quick soft blips — up on start, down on stop.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 16, y: 12, width: c.bounds.width - 32, height: 16); c.addSubview(note)
        return p
    }

    // MARK: About pane
    private func buildAboutPane() -> NSView {
        let p = NSView(frame: content.bounds); p.autoresizingMask = [.width, .height]
        let H = p.bounds.height
        sectionHeader("About", p, H - 56)
        let txt = NSTextField(wrappingLabelWithString:
            "Sori — local, private speech-to-text.\n\n" +
            "Powered by whisper.cpp running entirely on your Mac. Audio never leaves this machine. "
            + "If the optional Filler Cleanup is enabled, transcript TEXT is sent to Groq to strip stutters and filler words (deletion only, never rewrites).\n\n" +
            "Hold Right ⌘ to talk, or tap to toggle. Text is pasted at your cursor.")
        txt.font = .systemFont(ofSize: 13); txt.frame = NSRect(x: 28, y: H - 200, width: p.bounds.width - 80, height: 120)
        p.addSubview(txt)
        return p
    }

    // MARK: navigation
    @objc private func navTapped(_ sender: NSButton) { select(sender.identifier?.rawValue ?? "General") }
    private func select(_ name: String) {
        for (k, v) in panes { v.isHidden = (k != name) }
        for b in navButtons {
            let on = b.identifier?.rawValue == name
            b.layer?.backgroundColor = on ? brand.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
            b.contentTintColor = on ? brand : .labelColor
        }
    }

    // MARK: sound previews
    @objc private func previewStart() { Sounds.play("start") }
    @objc private func previewStop() { Sounds.play("stop") }

    // MARK: table edit
    @objc private func addRow() { cfg.replacements.append(Replacement(from: "", to: "")); replTable.reloadData() }
    @objc private func delRow() {
        let r = replTable.selectedRow
        if r >= 0 && r < cfg.replacements.count { cfg.replacements.remove(at: r); replTable.reloadData() }
    }

    @objc private func saveTapped() {
        // COMMIT any in-progress table-cell edit first. Without this, the value still
        // sitting in the field editor is lost — clicking Save (or pressing Enter, which
        // hits this button's \r key-equivalent BEFORE the cell commits) saved stale rows.
        window?.makeFirstResponder(nil)
        cfg.asrModel = modelPopup.titleOfSelectedItem ?? cfg.asrModel
        cfg.lang = langPopup.titleOfSelectedItem ?? cfg.lang
        cfg.promptHint = hintField.stringValue
        cfg.sound = soundCheck.state == .on
        cfg.aiTermsEnabled = aiTermsCheck.state == .on
        cfg.pressEnter = pressEnterCheck.state == .on
        cfg.panelStyle = panelStyleSegment.selectedSegment == 1 ? "compact" : "classic"
        // Drop rows with an empty "heard" side (they can never match anything).
        cfg.replacements = cfg.replacements.filter {
            !$0.from.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // The table shows manual + learned rules merged (see buildShell); everything the
        // user saw and edited is now canonical in `replacements`.
        cfg.learnedReplacements = []
        cfg.save()
        wlog("settings saved: \(cfg.replacements.count) corrections, model=\(cfg.asrModel ?? QwenServer.defaultRepo), pressEnter=\(cfg.pressEnter ?? false), panelStyle=\(cfg.panelStyle ?? "classic")")
        LoginItem.set(enabled: loginCheck.state == .on)
        onSave?(cfg)
        window?.close()
    }

    func reloadFromDisk() { buildShell(); select("General") }
}

extension SettingsController: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in t: NSTableView) -> Int { cfg.replacements.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let tf = (t.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(); f.identifier = id; f.isBordered = false; f.drawsBackground = false
            f.isEditable = true; f.target = self; f.action = #selector(cellEdited(_:))
            f.delegate = self   // commit on END of editing too (click away / Save / close)
            return f
        }()
        let isFrom = col?.identifier.rawValue == "from"
        tf.stringValue = isFrom ? cfg.replacements[row].from : cfg.replacements[row].to
        tf.tag = row * 2 + (isFrom ? 0 : 1)
        return tf
    }
    @objc private func cellEdited(_ sender: NSTextField) {
        let row = sender.tag / 2, isFrom = sender.tag % 2 == 0
        guard row < cfg.replacements.count else { return }
        if isFrom { cfg.replacements[row].from = sender.stringValue }
        else { cfg.replacements[row].to = sender.stringValue }
    }
    // Fires when a cell loses focus for ANY reason (tab, click elsewhere, Save's
    // makeFirstResponder(nil), window close) — the action alone only fired on Enter.
    func controlTextDidEndEditing(_ obj: Notification) {
        if let tf = obj.object as? NSTextField, tf.identifier?.rawValue == "cell" {
            cellEdited(tf)
        }
    }
}

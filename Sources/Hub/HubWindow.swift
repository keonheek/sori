import SwiftUI

// MARK: - Hub window: SwiftUI hosted from AppKit (the indicator + event tap stay AppKit)
struct HubRootView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        NavigationSplitView {
            List(HubModel.Section.allCases, selection: $model.section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text("Sori \(soriVersion)").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } detail: {
            switch model.section {
            case .home: HomeView(model: model)
            case .dictionary: DictionaryView(model: model)
            case .snippets: SnippetsView(model: model)
            case .style: StyleView(model: model)
            case .settings: SettingsView(model: model)
            }
        }
        .frame(minWidth: HubController.minSize.width, minHeight: HubController.minSize.height)
    }
}

final class HubController: NSWindowController, NSWindowDelegate {
    let model = HubModel()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Sori"
        win.titlebarAppearsTransparent = true
        win.toolbarStyle = .unified
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.contentViewController = NSHostingController(rootView: HubRootView(model: model))
        win.delegate = self
        win.setFrameAutosaveName("SoriHub")
    }
    required init?(coder: NSCoder) { fatalError() }

    // Below this the sidebar labels and the Style cards clip (seen 2026-10-14 at a saved 760×532).
    static let minSize = NSSize(width: 980, height: 620)

    func show() {
        model.reload()
        if let w = window, w.frame.width < Self.minSize.width || w.frame.height < Self.minSize.height {
            w.setContentSize(NSSize(width: max(w.frame.width, Self.minSize.width), height: max(w.frame.height, Self.minSize.height)))
            w.center()
        }
        // An accessory app is not always granted activation (macOS 14+), and its window stays on the
        // Space it was made on: pull it to the current Space and order it front regardless.
        window?.collectionBehavior.insert(.moveToActiveSpace)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    // Real-window render of every section for self-review: the actual HubRootView (NavigationSplitView
    // sidebar included) in a borderless window parked far off-screen, never key, never activated.
    // Writes <dir>/<section>-<w>x<h>.png. Used by `--hub-shots <dir> [w h]`.
    @MainActor static func shots(dir: String, size: NSSize) -> Int {
        let model = HubModel()
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                           styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.contentView = NSHostingView(rootView: HubRootView(model: model))
        win.setContentSize(size)
        win.orderFrontRegardless()
        var n = 0
        for s in HubModel.Section.allCases {
            model.section = s
            model.reload()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            // The window server keeps an off-screen window's backing store; screencapture -l reads it.
            let out = "\(dir)/\(s.rawValue.lowercased())-\(Int(size.width))x\(Int(size.height)).png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(win.windowNumber)", out]
            try? p.run(); p.waitUntilExit()
            if p.terminationStatus == 0, FileManager.default.fileExists(atPath: out) { n += 1 }
        }
        win.orderOut(nil)
        return n
    }

    // Headless render for review: SwiftUI's ImageRenderer draws the pure-SwiftUI Home body with
    // a mock sidebar — no window is ever created, nothing touches the screen.
    @MainActor static func snapshot(to path: String, width: CGFloat = 1100) -> Bool {
        let model = HubModel()
        let view = HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(HubModel.Section.allCases) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.symbol).frame(width: 16)
                        Text(s.rawValue)
                    }
                    .font(.system(size: 13, weight: s == model.section ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(s == model.section ? Theme.card : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Spacer(minLength: 0)
                Text("Sori \(soriVersion)").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .padding(12).padding(.top, 28)
            .frame(width: 190)
            .frame(maxHeight: .infinity)
            .background(Theme.sidebar)
            HomeContent(model: model, maxRows: 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bg)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: png)
    }
}

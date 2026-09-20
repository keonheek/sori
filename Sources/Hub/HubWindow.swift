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
            }
        }
        .frame(minWidth: 760, minHeight: 480)
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

    func show() {
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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

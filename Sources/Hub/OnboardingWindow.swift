import SwiftUI
import AVFoundation
import IOKit.hid

// MARK: - Onboarding: three permission cards with live status, a mic meter, the shortcut, a try-it field
final class PermissionsModel: ObservableObject {
    @Published var mic = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var level: Float = 0
    @Published var testing = false
    private var timer: Timer?
    private var engine: AVAudioEngine?

    init() { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() } }
    deinit { timer?.invalidate(); stopTest() }

    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    var allGranted: Bool { mic && accessibility && inputMonitoring }

    func requestMic() { AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } } }
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    func requestInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }
    private func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }

    // A throwaway engine on the default input, only while the meter is on.
    func startTest() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let fmt = e.inputNode.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength); var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(1, n)))
            let db = 20 * log10(max(rms, 1e-6))
            let lv = max(0, min(1, (db + 50) / 45))
            DispatchQueue.main.async { self?.level = lv }
        }
        do { try e.start(); engine = e; testing = true } catch { wlog("onboarding mic test failed: \(error)") }
    }
    func stopTest() {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        testing = false; level = 0
    }
}

struct OnboardingView: View {
    @ObservedObject var perms: PermissionsModel
    @State private var tryText = ""
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Sori").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Three permissions, one microphone check, then talk.").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            HStack(spacing: 12) {
                PermissionCard(title: "Microphone", detail: "Hear you.", granted: perms.mic, action: perms.requestMic)
                PermissionCard(title: "Accessibility", detail: "Paste into the app you are using.", granted: perms.accessibility, action: perms.requestAccessibility)
                PermissionCard(title: "Input Monitoring", detail: "See the Right ⌘ key anywhere.", granted: perms.inputMonitoring, action: perms.requestInputMonitoring)
            }
            micCard
            shortcutCard
            HStack {
                Spacer()
                Button(perms.allGranted ? "Done" : "Finish later") { perms.stopTest(); onDone() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 720)
        .background(Theme.bg)
    }

    private var micCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test your microphone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Say something. The bar should move.").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button(perms.testing ? "Stop" : "Test mic") { perms.testing ? perms.stopTest() : perms.startTest() }
                    .disabled(!perms.mic)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.bg).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: g.size.width * CGFloat(perms.level), height: 8)
                        .animation(.linear(duration: 0.08), value: perms.level)
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 14) {
                KeyCap("Right ⌘"); Text("hold to talk, release to paste").font(.system(size: 12)).foregroundStyle(Theme.text2)
                KeyCap("tap"); Text("hands-free, tap again to stop").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            HubTextField(text: $tryText, placeholder: "Click here, hold Right ⌘, say hello")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

struct PermissionCard: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? Theme.accent : Theme.text3)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if granted {
                Text("Granted").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
            } else {
                Button("Grant…", action: action)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .card(padding: 14)
    }
}

final class OnboardingController: NSWindowController, NSWindowDelegate {
    let perms = PermissionsModel()
    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "Set up Sori"; win.titlebarAppearsTransparent = true; win.isReleasedWhenClosed = false; win.center()
        super.init(window: win)
        win.contentViewController = NSHostingController(rootView: OnboardingView(perms: perms) { [weak self] in self?.window?.close() })
        win.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { perms.stopTest(); Database.shared.setMeta("onboarded", "1") }

    @MainActor static func snapshot(to path: String) -> Bool {
        let perms = PermissionsModel()
        let r = ImageRenderer(content: OnboardingView(perms: perms, onDone: {}).fixedSize(horizontal: false, vertical: true))
        r.scale = 2
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: png)
    }
}

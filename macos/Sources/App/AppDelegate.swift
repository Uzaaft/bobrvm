import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BobrvmAppDelegate {
    private static let logger = BobrvmLogging.logger(for: AppDelegate.self)

    let vmManager = VMManager()
    private var app: App?
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var pasteboardTimer: Timer?
    private var bobrvmInitialized = false

    func applicationDidFinishLaunching(_: Notification) {
        bobrvm_init()
        bobrvmInitialized = true

        do {
            let app = try App()
            app.delegate = self
            self.app = app
            vmManager.app = app
            vmManager.loadExistingVMs()
            startPasteboardMonitoring()
        } catch {
            Self.logger.error("Failed to initialize Bobrvm runtime: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        pasteboardTimer?.invalidate()
        vmManager.stopAllVMs()
        if bobrvmInitialized {
            bobrvm_deinit()
            bobrvmInitialized = false
        }
    }

    func appGPUFrameReady(_ app: App) {
        _ = app
        vmManager.notifyFrameReady()
    }

    func appReadClipboard(_: App) -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func app(_: App, didRequestWriteClipboard text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChangeCount = pasteboard.changeCount
    }

    private func startPasteboardMonitoring() {
        pasteboardTimer?.invalidate()
        pasteboardChangeCount = NSPasteboard.general.changeCount
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let app = self.app else { return }
                app.refreshGuestToolsStatus()
                let changeCount = NSPasteboard.general.changeCount
                guard changeCount != self.pasteboardChangeCount else { return }
                self.pasteboardChangeCount = changeCount
                app.notifyHostClipboardChanged()
            }
        }
    }
}

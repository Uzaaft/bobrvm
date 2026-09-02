import AppKit
import LocalAuthentication

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BobrvmAppDelegate {
    private static let logger = BobrvmLogging.logger(for: AppDelegate.self)

    let vmManager = VMManager()
    private var app: App?
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var pasteboardTimer: Timer?
    private var bobrvmInitialized = false
    private var touchIDRequests: [TouchIDRequestKey: LAContext] = [:]

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
        for context in touchIDRequests.values {
            context.invalidate()
        }
        touchIDRequests.removeAll()
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

    func app(
        _: App,
        vm: VM,
        didRequestTouchID operation: TouchIDOperation,
        username _: String,
        requestID: UInt64
    ) {
        let key = TouchIDRequestKey(vm: ObjectIdentifier(vm), requestID: requestID)
        guard touchIDRequests.isEmpty else {
            vm.completeTouchID(requestID: requestID, result: .failed)
            return
        }

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        var availabilityError: NSError?
        guard
            context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &availabilityError
            )
        else {
            vm.completeTouchID(
                requestID: requestID,
                result: Self.touchIDResult(for: availabilityError)
            )
            return
        }
        guard context.biometryType == .touchID else {
            vm.completeTouchID(requestID: requestID, result: .unavailable)
            return
        }

        touchIDRequests[key] = context
        let vmName =
            vmManager.vms.first(where: { $0.runtimeVM === vm })?.name
            ?? "Linux virtual machine"
        let action = operation == .enroll ? "enroll" : "authenticate"
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Use Touch ID to \(action) in ‘\(vmName)’"
        ) { [weak self, weak vm] success, error in
            DispatchQueue.main.async {
                guard let self, let vm,
                    self.touchIDRequests.removeValue(forKey: key) != nil
                else { return }
                vm.completeTouchID(
                    requestID: requestID,
                    result: success ? .success : Self.touchIDResult(for: error)
                )
            }
        }
    }

    func app(_: App, vm: VM, didCancelTouchIDRequest requestID: UInt64) {
        let key = TouchIDRequestKey(vm: ObjectIdentifier(vm), requestID: requestID)
        touchIDRequests.removeValue(forKey: key)?.invalidate()
    }

    func app(_: App, didInvalidateTouchIDRequestsFor vm: VM) {
        let vmIdentifier = ObjectIdentifier(vm)
        let keys = touchIDRequests.keys.filter { $0.vm == vmIdentifier }
        for key in keys {
            touchIDRequests.removeValue(forKey: key)?.invalidate()
        }
    }

    private static func touchIDResult(for error: Error?) -> TouchIDResult {
        guard let error else { return .failed }
        let value = error as NSError
        guard value.domain == LAError.errorDomain,
            let code = LAError.Code(rawValue: value.code)
        else { return .failed }
        switch code {
        case .authenticationFailed:
            return .noMatch
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .biometryLockout:
            return .locked
        case .biometryNotAvailable, .biometryNotEnrolled, .notInteractive:
            return .unavailable
        default:
            return .failed
        }
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

private struct TouchIDRequestKey: Hashable {
    let vm: ObjectIdentifier
    let requestID: UInt64
}

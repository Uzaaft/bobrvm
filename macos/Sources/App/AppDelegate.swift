//
//  AppDelegate.swift
//  Bobrvm
//
//  Minimal NSApplicationDelegate for SwiftUI app wiring.
//

import AppKit
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BobrvmAppDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.bobrvm.app",
        category: "AppDelegate"
    )

    let vmManager = VMManager()
    let ghosttyRuntime = GhosttyRuntime()
    private var app: App?
    private var libraryWindowController: NSWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        do {
            let app = try App()
            app.delegate = self
            self.app = app
            vmManager.app = app
            vmManager.loadExistingVMs()
            bringWindowsOnScreen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.bringWindowsOnScreen()
            }
        } catch {
            Self.logger.error("Failed to initialize Bobrvm runtime: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        vmManager.stopAllVMs()
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            bringWindowsOnScreen()
        }
        return true
    }

    func appGPUFrameReady(_ app: App) {
        _ = app
        vmManager.notifyFrameReady()
    }

    private func bringWindowsOnScreen() {
        NSApp.setActivationPolicy(.regular)
        var visibleWindows = NSApp.windows.filter { window in
            window.isVisible && !window.isMiniaturized && window.canBecomeKey
        }
        if visibleWindows.isEmpty {
            visibleWindows = [createLibraryWindow()]
        }

        for window in visibleWindows {
            positionOnPrimaryScreen(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        Self.logger.info("Presented \(visibleWindows.count) application windows")
    }

    private func createLibraryWindow() -> NSWindow {
        let content = ContentView()
            .environmentObject(vmManager)
            .environmentObject(ghosttyRuntime)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Library"
        window.setContentSize(NSSize(width: 1_100, height: 720))
        let controller = NSWindowController(window: window)
        libraryWindowController = controller
        controller.showWindow(nil)
        Self.logger.info("Created fallback library window")
        return window
    }

    private func positionOnPrimaryScreen(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
        else { return }

        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.midY - window.frame.height / 2
        ))
    }
}

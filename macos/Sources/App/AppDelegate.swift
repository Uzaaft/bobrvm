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

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

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

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        vmManager.stopAllVMs()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        _ = sender
        if !flag {
            bringWindowsOnScreen()
        }
        return true
    }

    func appGPUFrameReady(_ app: App) {
        _ = app
        vmManager.notifyFrameReady()
    }

    func app(_ app: App, didReceiveConsoleOutput text: String) {
        _ = app
        vmManager.appendConsoleOutput(text)
    }

    private func bringWindowsOnScreen() {
        NSApp.setActivationPolicy(.regular)
        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible && !window.isMiniaturized && window.canBecomeKey
        }
        if visibleWindows.isEmpty {
            let content = ContentView()
                .environmentObject(vmManager)
                .environmentObject(ghosttyRuntime)
            let hostingController = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Library"
            window.setContentSize(NSSize(width: 1_100, height: 720))
            window.center()
            let controller = NSWindowController(window: window)
            libraryWindowController = controller
            controller.showWindow(nil)
            Self.logger.info("Created fallback library window")
        }

        for window in NSApp.windows {
            window.collectionBehavior.insert(.moveToActiveSpace)
            let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
            if let screen {
                let frame = screen.visibleFrame
                let origin = NSPoint(
                    x: frame.midX - window.frame.width / 2,
                    y: frame.midY - window.frame.height / 2
                )
                window.setFrameOrigin(origin)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        Self.logger.info("Presented \(NSApp.windows.count) application windows")
    }
}

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
    private var app: App?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        do {
            let app = try App()
            app.delegate = self
            self.app = app
            vmManager.app = app
            vmManager.loadExistingVMs()
        } catch {
            Self.logger.error("Failed to initialize Bobrvm runtime: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        vmManager.stopAllVMs()
    }
}

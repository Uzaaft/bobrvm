//
//  BobrvmApp.swift
//  Bobrvm
//
//  Main SwiftUI application entry point.
//

import SwiftUI

@main
struct BobrvmApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.vmManager)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") {
                    appDelegate.vmManager.showingCreateVM = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

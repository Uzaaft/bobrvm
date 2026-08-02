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
                .environmentObject(appDelegate.ghosttyRuntime)
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

        WindowGroup("Virtual Machine", for: UUID.self) { $vmID in
            if let vmID {
                VMWindowView(vmID: vmID)
                    .environmentObject(appDelegate.vmManager)
                    .environmentObject(appDelegate.ghosttyRuntime)
            }
        }
        .defaultSize(width: 1_280, height: 800)

        Settings {
            SettingsView()
        }
    }
}

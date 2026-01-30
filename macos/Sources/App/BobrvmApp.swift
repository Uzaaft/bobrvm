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
        .commands {
            CommandGroup(after: .newItem) {
                Button("New VM...") {
                    appDelegate.vmManager.showingCreateVM = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        
        Settings {
            SettingsView()
        }
    }
}

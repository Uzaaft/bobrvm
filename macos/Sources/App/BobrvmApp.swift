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
            MachineCommands()
        }

        WindowGroup("Virtual Machine", id: "vm-display", for: UUID.self) { $vmID in
            if let vmID {
                VMWindowView(vmID: vmID)
                    .environmentObject(appDelegate.vmManager)
                    .environmentObject(appDelegate.ghosttyRuntime)
            }
        }
        .defaultSize(width: 1_280, height: 800)

        WindowGroup("Console", id: "vm-console", for: UUID.self) { $vmID in
            if let vmID {
                VMConsoleWindowView(vmID: vmID)
                    .environmentObject(appDelegate.vmManager)
                    .environmentObject(appDelegate.ghosttyRuntime)
            }
        }
        .defaultSize(width: 1_000, height: 600)

        Settings {
            SettingsView()
        }
    }
}

private struct MachineCommands: Commands {
    @FocusedValue(\.vmID) private var vmID
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Machine") {
            Button("Show Display") {
                guard let vmID else { return }
                openWindow(id: "vm-display", value: vmID)
            }
            .disabled(vmID == nil)

            Button("Show Console") {
                guard let vmID else { return }
                openWindow(id: "vm-console", value: vmID)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(vmID == nil)
        }
    }
}

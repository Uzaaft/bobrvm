import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BobrvmApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Bobrvm", id: "library") {
            ContentView()
                .environmentObject(appDelegate.vmManager)
                .environmentObject(appDelegate.ghosttyRuntime)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            BobrvmCommands(vmManager: appDelegate.vmManager)
            SidebarCommands()
        }

        WindowGroup("Virtual Machine", id: "vm-display", for: UUID.self) { $vmID in
            if let vmID {
                VMWindowView(vmID: vmID)
                    .environmentObject(appDelegate.vmManager)
                    .environmentObject(appDelegate.ghosttyRuntime)
            }
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1_280, height: 800)
        .commands {
            BobrvmCommands(vmManager: appDelegate.vmManager)
        }

        WindowGroup("Console", id: "vm-console", for: UUID.self) { $vmID in
            if let vmID {
                VMConsoleWindowView(vmID: vmID)
                    .environmentObject(appDelegate.vmManager)
                    .environmentObject(appDelegate.ghosttyRuntime)
            }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_000, height: 600)
        .commands {
            BobrvmCommands(vmManager: appDelegate.vmManager)
        }

        Settings {
            SettingsView()
        }
        .commands {
            BobrvmCommands(vmManager: appDelegate.vmManager)
        }
    }
}

private struct BobrvmCommands: Commands {
    @ObservedObject var vmManager: VMManager

    var body: some Commands {
        NewVirtualMachineCommands(vmManager: vmManager)
        MachineCommands(vmManager: vmManager)
    }
}

private struct NewVirtualMachineCommands: Commands {
    @ObservedObject var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                openWindow(id: "library")
                vmManager.showingCreateVM = true
            } label: {
                Label("New Virtual Machine…", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

private struct MachineCommands: Commands {
    @ObservedObject var vmManager: VMManager
    @FocusedObject private var focusedVM: VMInstance?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Machine") {
            Button {
                guard let vm = focusedVM else { return }
                openWindow(id: "vm-display", value: vm.id)
            } label: {
                Label("Show Display", systemImage: "macwindow")
            }
            .disabled(focusedVM == nil)

            Button {
                guard let vm = focusedVM else { return }
                openWindow(id: "vm-console", value: vm.id)
            } label: {
                Label("Show Console", systemImage: "terminal")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(focusedVM == nil || focusedVM?.guestSystem == .macOS)

            Divider()
            configurationCommands
            Divider()
            lifecycleCommands
            Divider()
            integrationCommands
        }
    }

    @ViewBuilder
    private var configurationCommands: some View {
        Button {
            guard let vm = focusedVM else { return }
            openWindow(id: "library")
            vmManager.vmPendingEdit = vm
        } label: {
            Label("Virtual Machine Settings…", systemImage: "gearshape")
        }
        .disabled(focusedVM == nil)

        Button {
            guard let vm = focusedVM else { return }
            attachISO(to: vm)
        } label: {
            Label("Attach ISO…", systemImage: "opticaldisc.badge.plus")
        }
        .disabled(!canChangeISO)

        Button {
            guard let vm = focusedVM else { return }
            updateISO(vm, path: nil, action: "detach")
        } label: {
            Label("Detach ISO", systemImage: "eject.fill")
        }
        .disabled(!canChangeISO || focusedVM?.isoPath == nil)
    }

    private var canChangeISO: Bool {
        guard let vm = focusedVM else { return false }
        return vm.guestSystem != .macOS && vm.state == .stopped
    }

    @ViewBuilder
    private var integrationCommands: some View {
        Menu {
            if let vm = focusedVM {
                guestToolsCommands(for: vm)
            }
        } label: {
            Label("Guest Tools", systemImage: "wrench.and.screwdriver")
        }
        .disabled(!guestToolsAvailable)

        Button {
            focusedVM?.runtimeVM?.clearConsoleOutput()
        } label: {
            Label("Clear Console", systemImage: "trash")
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(focusedVM?.runtimeVM == nil)
    }

    private var guestToolsAvailable: Bool {
        guard let vm = focusedVM else { return false }
        return vm.state == .running && vm.guestSystem != .macOS
    }

    @ViewBuilder
    private func guestToolsCommands(for vm: VMInstance) -> some View {
        Text(guestToolsDescription(for: vm))
        Divider()
        Button("Shut Down Guest", systemImage: "power") {
            vm.shutdownGracefully()
        }
        .disabled(!vm.isGuestManagementReady)
        Button("Reboot Guest", systemImage: "arrow.clockwise") {
            vm.rebootGuest()
        }
        .disabled(!vm.isGuestManagementReady)
        Divider()
        Button("Synchronize Time", systemImage: "clock.arrow.circlepath") {
            vm.synchronizeGuestTime()
        }
        .disabled(!vm.isGuestManagementReady)
        Button("Trim Filesystems", systemImage: "scissors") {
            vm.trimGuestFilesystems()
        }
        .disabled(!vm.isGuestManagementReady)
        Button("Create Quiesced Snapshot…", systemImage: "camera") {
            createQuiescedSnapshot(of: vm)
        }
        .disabled(!vm.isGuestManagementReady)
        Divider()
        Button("Send File to Guest…", systemImage: "paperplane") {
            sendFile(to: vm)
        }
        .disabled(!vm.guestToolsStatus.supportsFileTransfer)
    }

    @ViewBuilder
    private var lifecycleCommands: some View {
        Button {
            guard let vm = focusedVM else { return }
            start(vm)
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(focusedVM?.state != .stopped)

        Button {
            guard let vm = focusedVM else { return }
            vm.resume()
            openWindow(id: "vm-display", value: vm.id)
        } label: {
            Label("Resume", systemImage: "play.fill")
        }
        .disabled(focusedVM?.state != .paused)

        Button {
            focusedVM?.pause()
        } label: {
            Label("Pause", systemImage: "pause.fill")
        }
        .disabled(focusedVM?.state != .running)

        Button {
            focusedVM?.stop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(focusedVM == nil || focusedVM?.state == .stopped)
    }

    private func start(_ vm: VMInstance) {
        do {
            try vm.start()
            openWindow(id: "vm-display", value: vm.id)
        } catch {
            presentNativeError(error, title: "Could Not Start Virtual Machine")
        }
    }

    private func attachISO(to vm: VMInstance) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.iso]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateISO(vm, path: url.path, action: "attach")
    }

    private func updateISO(_ vm: VMInstance, path: String?, action: String) {
        do {
            try vmManager.updateISO(vm, path: path)
        } catch {
            presentNativeError(error, title: "Could Not \(action.capitalized) ISO")
        }
    }

    private func sendFile(to vm: VMInstance) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try vm.sendFileToGuest(file)
        } catch {
            presentNativeError(error, title: "Could Not Send File")
        }
    }

    private func createQuiescedSnapshot(of vm: VMInstance) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            do {
                try await vm.snapshotQuiesced(to: directory)
            } catch {
                presentNativeError(error, title: "Could Not Create Snapshot")
            }
        }
    }

    private func guestToolsDescription(for vm: VMInstance) -> String {
        switch vm.guestToolsStatus.connection {
        case .disconnected: return "Guest Tools: Disconnected"
        case .connecting: return "Guest Tools: Connecting"
        case .ready: return "Guest Tools: Ready"
        case .protocolError: return "Guest Tools: Protocol Error"
        }
    }
}

import AppKit
import Combine
import SwiftUI

enum LibrarySelection: Hashable {
    case library
    case virtualMachine(UUID)
}

@MainActor
func presentNativeError(_ error: Error, title: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    if let window = NSApp.keyWindow {
        alert.beginSheetModal(for: window)
        return
    }

    let presentedError = NSError(
        domain: Bundle.main.bundleIdentifier ?? "com.bobrvm.app",
        code: 1,
        userInfo: [
            NSLocalizedDescriptionKey: title,
            NSLocalizedRecoverySuggestionErrorKey: error.localizedDescription,
            NSUnderlyingErrorKey: error,
        ]
    )
    _ = NSApp.presentError(presentedError)
}

struct DebugBuildWarningView: View {
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            Label("Debug Build", systemImage: "exclamationmark.triangle.fill")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .tint(.yellow)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Debug Build", systemImage: "hammer.fill")
                    .font(.headline)
                Text("Safety checks and logging can reduce virtual machine performance.")
                    .foregroundStyle(.secondary)
                Text("zig build -Doptimize=ReleaseFast")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }
            .padding(16)
            .frame(width: 340)
        }
        .accessibilityHint("Shows information about debug-build performance")
    }
}

struct ContentView: View {
    @EnvironmentObject private var vmManager: VMManager
    @State private var selection: LibrarySelection? = .library
    @State private var searchText = ""
    @State private var libraryVMSelection: UUID?

    var body: some View {
        NavigationSplitView {
            VMListView(
                selection: $selection,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vmManager.showingCreateVM = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                }
                .help("Create a virtual machine (Command-N)")
            }
        }
        .sheet(isPresented: $vmManager.showingCreateVM) {
            CreateVMView()
        }
        .sheet(item: $vmManager.vmPendingEdit) { vm in
            EditVMView(vmInstance: vm)
        }
        .frame(minWidth: 780, minHeight: 520)
        .focusedSceneObject(selectedVM)
        .onChange(of: visibleVMIDs) { _, ids in
            if let id = libraryVMSelection, !ids.contains(id) {
                libraryVMSelection = nil
            }
            guard case .virtualMachine(let id) = selection, !ids.contains(id) else {
                return
            }
            selection = .library
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .virtualMachine(let id):
            if let vm = vmManager.vms.first(where: { $0.id == id }) {
                VMOverviewView(vmInstance: vm)
            } else {
                library
            }
        case .library, nil:
            library
        }
    }

    private var library: some View {
        VMLibraryHomeView(
            searchText: searchText,
            selectedVMID: $libraryVMSelection,
            showDetails: { selection = .virtualMachine($0.id) }
        )
    }

    private var selectedVM: VMInstance? {
        switch selection {
        case .virtualMachine(let id):
            return vmManager.vms.first { $0.id == id }
        case .library, nil:
            guard let id = libraryVMSelection else { return nil }
            return vmManager.vms.first { $0.id == id }
        }
    }

    private var visibleVMIDs: [UUID] {
        guard !searchText.isEmpty else { return vmManager.vms.map(\.id) }
        return vmManager.vms.compactMap { vm in
            let matchesSearch = vm.name.localizedStandardContains(searchText)
                || vm.guestSystem.displayName.localizedStandardContains(searchText)
            return matchesSearch ? vm.id : nil
        }
    }
}

struct VMListView: View {
    @EnvironmentObject private var vmManager: VMManager
    @Binding var selection: LibrarySelection?
    @Binding var searchText: String
    @State private var vmToDelete: VMInstance?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Library", systemImage: "square.grid.2x2")
                    .tag(LibrarySelection.library)
            }

            Section("Virtual Machines") {
                ForEach(filteredVMs) { vm in
                    VMListRow(vmInstance: vm)
                        .tag(LibrarySelection.virtualMachine(vm.id))
                        .contextMenu {
                            VMContextMenu(
                                vmInstance: vm,
                                onEdit: { vmManager.vmPendingEdit = vm },
                                onDelete: { vmToDelete = vm }
                            )
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Bobrvm")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .safeAreaInset(edge: .bottom) {
            if bobrvm_is_debug() {
                DebugBuildWarningView()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "Delete Virtual Machine?",
            isPresented: deleteConfirmation,
            titleVisibility: .visible,
            presenting: vmToDelete
        ) { vm in
            Button("Delete \"\(vm.name)\"", role: .destructive) {
                vmManager.deleteVM(vm)
                vmToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                vmToDelete = nil
            }
        } message: { _ in
            Text("The saved configuration will be removed. Disk images remain on this Mac.")
        }
    }

    private var filteredVMs: [VMInstance] {
        guard !searchText.isEmpty else { return vmManager.vms }
        return vmManager.vms.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.guestSystem.displayName.localizedStandardContains(searchText)
        }
    }

    private var deleteConfirmation: Binding<Bool> {
        Binding(
            get: { vmToDelete != nil },
            set: { if !$0 { vmToDelete = nil } }
        )
    }
}

struct VMContextMenu: View {
    @ObservedObject var vmInstance: VMInstance
    @EnvironmentObject var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            Section {
                switch vmInstance.state {
                case .stopped:
                    Button {
                        start()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .keyboardShortcut("r", modifiers: .command)

                case .running:
                    Button {
                        vmInstance.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }

                    Button {
                        vmInstance.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)

                    Divider()

                    Button {
                        vmInstance.stop()
                        start()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }

                case .paused:
                    Button {
                        vmInstance.resume()
                        openWindow(id: "vm-display", value: vmInstance.id)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }

                    Button {
                        vmInstance.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }

            Section {
                Button {
                    onEdit()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }

                Button {
                    duplicateVM()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(vmInstance.state == .running || vmInstance.guestSystem == .macOS)
            }

            Section {
                if vmInstance.guestSystem != .macOS {
                    ISOMediaActions(vmInstance: vmInstance)
                }

                if let diskPath = vmInstance.config.diskPath {
                    Button {
                        showInFinder(path: diskPath)
                    } label: {
                        Label("Show Disk in Finder", systemImage: "folder")
                    }
                }

                Button {
                    showConfigInFinder()
                } label: {
                    Label("Show Config in Finder", systemImage: "doc.text")
                }
            }

            Section {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .disabled(vmInstance.state == .running)
            }
        }
    }

    private func duplicateVM() {
        guard vmInstance.guestSystem != .macOS else { return }
        let newName = "\(vmInstance.name) (Copy)"
        do {
            try vmManager.createVM(
                name: newName,
                config: vmInstance.config,
                isoPath: vmInstance.isoPath,
                retinaEnabled: vmInstance.retinaEnabled,
                guestSystem: vmInstance.guestSystem
            )
        } catch {
            presentNativeError(error, title: "Could Not Duplicate Virtual Machine")
        }
    }

    private func start() {
        do {
            try vmInstance.start()
            openWindow(id: "vm-display", value: vmInstance.id)
        } catch {
            presentNativeError(error, title: "Could Not Start Virtual Machine")
        }
    }

    private func showInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showConfigInFinder() {
        let configDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?
        .appendingPathComponent("Bobrvm")
        .appendingPathComponent("configs")

        if let configDir = configDir {
            let configFile = configDir.appendingPathComponent("\(vmInstance.id.uuidString).json")
            if FileManager.default.fileExists(atPath: configFile.path) {
                NSWorkspace.shared.activateFileViewerSelecting([configFile])
            } else {
                NSWorkspace.shared.open(configDir)
            }
        }
    }
}

struct VMListRow: View {
    @ObservedObject var vmInstance: VMInstance

    var body: some View {
        HStack(spacing: 8) {
            vmInstance.guestSystem.presentationImage
                .foregroundStyle(vmInstance.guestSystem.symbolColor)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(vmInstance.name)
                .lineLimit(1)

            Spacer(minLength: 8)

            if vmInstance.state != .stopped {
                Circle()
                    .fill(vmInstance.state.presentationColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vmInstance.name)
        .accessibilityValue(
            "\(vmInstance.guestSystem.displayName), \(vmInstance.state.presentationName)"
        )
    }
}

struct VMDetailView: View {
    @ObservedObject var vmInstance: VMInstance
    @State private var showingSettings = false
    @State private var errorTitle = ""
    @State private var errorMessage: String?

    var body: some View {
        display
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Virtual machine settings")

                if vmInstance.guestSystem != .macOS {
                    Menu {
                        ISOMediaActions(vmInstance: vmInstance)
                    } label: {
                        Label("CD/DVD", systemImage: "opticaldisc")
                    }
                    .help(isoHelp)
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup(placement: .primaryAction) {
                lifecycleControls
            }
        }
        .sheet(isPresented: $showingSettings) {
            EditVMView(vmInstance: vmInstance)
        }
        .alert(errorTitle, isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    @ViewBuilder
    private var display: some View {
        if vmInstance.state == .running || vmInstance.state == .paused {
            if vmInstance.guestSystem == .macOS,
                let machine = vmInstance.runtimeMacVM
            {
                MacVirtualMachineView(machine: machine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VMSurfaceRepresentable(vmInstance: vmInstance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text(vmInstance.name)
                } icon: {
                    vmInstance.guestSystem.presentationImage
                }
            } description: {
                Text("Start this virtual machine to open its display.")
            } actions: {
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var lifecycleControls: some View {
        switch vmInstance.state {
        case .stopped:
            Button(action: start) {
                Label("Start", systemImage: "play.fill")
            }
            .help("Start virtual machine")
        case .running:
            Button {
                vmInstance.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .help("Pause virtual machine")
            Button(role: .destructive) {
                vmInstance.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop virtual machine")
            guestToolsMenu
        case .paused:
            Button {
                vmInstance.resume()
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .help("Resume virtual machine")
            Button(role: .destructive) {
                vmInstance.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop virtual machine")
        }
    }

    private var guestToolsMenu: some View {
        Menu {
            Text(guestToolsDescription)
            Divider()
            Button("Shut Down Guest", systemImage: "power") {
                vmInstance.shutdownGracefully()
            }
            .disabled(!vmInstance.isGuestManagementReady)
            Button("Reboot Guest", systemImage: "arrow.clockwise") {
                vmInstance.rebootGuest()
            }
            .disabled(!vmInstance.isGuestManagementReady)
            Divider()
            Button(
                "Synchronize Time",
                systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
            ) {
                vmInstance.synchronizeGuestTime()
            }
            .disabled(!vmInstance.isGuestManagementReady)
            Button("Trim Filesystems", systemImage: "scissors") {
                vmInstance.trimGuestFilesystems()
            }
            .disabled(!vmInstance.isGuestManagementReady)
            Button("Create Quiesced Snapshot…", systemImage: "camera") {
                createQuiescedSnapshot()
            }
            .disabled(!vmInstance.isGuestManagementReady)
            Divider()
            Button("Send File to Guest…", systemImage: "paperplane") {
                sendFileToGuest()
            }
            .disabled(!vmInstance.guestToolsStatus.supportsFileTransfer)
        } label: {
            Label("Guest Tools", systemImage: "wrench.and.screwdriver")
        }
        .help("Guest integration tools")
    }

    private func sendFileToGuest() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try vmInstance.sendFileToGuest(file)
        } catch {
            showError(title: "Could Not Send File", error: error)
        }
    }

    private func createQuiescedSnapshot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            do {
                try await vmInstance.snapshotQuiesced(to: directory)
            } catch {
                showError(title: "Could Not Create Snapshot", error: error)
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func start() {
        do {
            try vmInstance.start()
        } catch {
            showError(title: "Could Not Start Virtual Machine", error: error)
        }
    }

    private func showError(title: String, error: Error) {
        errorTitle = title
        errorMessage = error.localizedDescription
    }

    private var guestToolsDescription: String {
        switch vmInstance.guestToolsStatus.connection {
        case .disconnected: return "Guest Tools: Disconnected"
        case .connecting: return "Guest Tools: Connecting"
        case .ready: return "Guest Tools: Ready"
        case .protocolError: return "Guest Tools: Protocol Error"
        }
    }

    private var isoHelp: String {
        guard let path = vmInstance.isoPath else { return "Attach an ISO image" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct ISOMediaActions: View {
    @ObservedObject var vmInstance: VMInstance
    @EnvironmentObject private var vmManager: VMManager
    @State private var errorTitle = "Could Not Update ISO"
    @State private var errorMessage: String?

    var body: some View {
        Group {
            Button {
                attachISO()
            } label: {
                Label("Attach ISO…", systemImage: "opticaldisc.badge.plus")
            }
            .disabled(vmInstance.state != .stopped)

            if vmInstance.isoPath != nil {
                Button {
                    updateISO(path: nil, action: "detach")
                } label: {
                    Label("Detach ISO", systemImage: "eject.fill")
                }
                .disabled(vmInstance.state != .stopped)
            }
        }
        .alert(errorTitle, isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func attachISO() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.iso]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateISO(path: url.path, action: "attach")
    }

    private func updateISO(path: String?, action: String) {
        do {
            try vmManager.updateISO(vmInstance, path: path)
        } catch {
            errorTitle = "Could Not \(action.capitalized) ISO"
            errorMessage = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

struct VMWindowView: View {
    @EnvironmentObject private var vmManager: VMManager
    let vmID: UUID

    var body: some View {
        Group {
            if let vm = vmInstance {
                VMDetailView(vmInstance: vm)
                    .navigationTitle(vm.name)
            } else {
                ContentUnavailableView {
                    Label(
                        "Virtual Machine Not Found",
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                    )
                } description: {
                    Text("This virtual machine may have been removed from the library.")
                }
            }
        }
        .focusedSceneValue(\.vmID, vmID)
        .focusedSceneObject(vmInstance)
    }

    private var vmInstance: VMInstance? {
        vmManager.vms.first { $0.id == vmID }
    }
}

struct VMConsoleWindowView: View {
    @EnvironmentObject private var vmManager: VMManager
    let vmID: UUID

    var body: some View {
        Group {
            if let vmInstance {
                if let vm = vmInstance.runtimeVM {
                    ConsoleView(vm: vm)
                        .navigationTitle("\(vmInstance.name) Console")
                } else {
                    ContentUnavailableView {
                        Label("Console Unavailable", systemImage: "terminal")
                    } description: {
                        Text(consoleUnavailableDescription(for: vmInstance))
                    }
                }
            } else {
                ContentUnavailableView(
                    "Virtual Machine Not Found",
                    systemImage: "terminal.fill",
                    description: Text("This virtual machine is no longer in the library.")
                )
            }
        }
        .focusedSceneValue(\.vmID, vmID)
        .focusedSceneObject(vmInstance)
    }

    private var vmInstance: VMInstance? {
        vmManager.vms.first { $0.id == vmID }
    }

    private func consoleUnavailableDescription(for vm: VMInstance) -> String {
        if vm.guestSystem == .macOS {
            return "Console access is not available for macOS virtual machines."
        }
        return "Start the virtual machine to open its console."
    }
}

struct ConsoleView: View {
    @ObservedObject var vm: VM
    @EnvironmentObject private var ghosttyRuntime: GhosttyRuntime

    var body: some View {
        Group {
            if let app = ghosttyRuntime.app {
                GhosttyConsoleViewRepresentable(
                    app: app,
                    initialOutput: vm.consoleOutputData,
                    events: vm.consoleEventPublisher
                )
            } else {
                ContentUnavailableView(
                    "Terminal Renderer Unavailable",
                    systemImage: "terminal",
                    description: Text("The console renderer could not be initialized.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    vm.clearConsoleOutput()
                } label: {
                    Label("Clear Console", systemImage: "trash")
                }
                .help("Clear console")
            }
        }
    }
}

private struct VMIDFocusedValueKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var vmID: UUID? {
        get { self[VMIDFocusedValueKey.self] }
        set { self[VMIDFocusedValueKey.self] = newValue }
    }
}

extension VMState {
    var presentationName: String {
        switch self {
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }

    var presentationIcon: String {
        switch self {
        case .running: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .stopped: return "stop.circle"
        }
    }

    var presentationColor: Color {
        switch self {
        case .running: return .green
        case .paused: return .orange
        case .stopped: return .secondary
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(VMManager())
}

//
//  ContentView.swift
//  Bobrvm
//
//  Main content view with VM list and display area.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Debug Build Warning

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        Button {
            isPopover = true
        } label: {
            HStack {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Debug build – performance may be degraded")
                    .font(.callout)
                    .padding(.vertical, 8)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .background(Color(.windowBackgroundColor).opacity(0.95))
        .frame(maxWidth: .infinity)
        .popover(isPresented: $isPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Debug Build")
                    .font(.headline)
                Text(
                    """
                    Debug builds of Bobrvm include additional safety checks and logging that may \
                    impact performance.

                    For production use, build with:
                    """)
                Text("zig build -Doptimize=ReleaseFast")
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding()
            .frame(width: 320)
        }
        .accessibilityLabel("Debug build warning")
        .accessibilityHint("Shows build performance details")
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var vmManager: VMManager

    var body: some View {
        VStack(spacing: 0) {
            if bobrvm_is_debug() {
                DebugBuildWarningView()
            }

            NavigationSplitView {
                VMListView()
                    .frame(minWidth: 200)
            } detail: {
                VMLibraryHomeView()
            }
            .sheet(isPresented: $vmManager.showingCreateVM) {
                CreateVMView()
            }
        }
    }
}

// MARK: - VM List

struct VMListView: View {
    @EnvironmentObject var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow
    @State private var vmToDelete: VMInstance?
    @State private var vmToEdit: VMInstance?
    @State private var showDeleteConfirmation = false
    @State private var showEditSheet = false

    var body: some View {
        List(vmManager.vms) { vm in
            VMListRow(vmInstance: vm)
                .tag(vm)
                .onTapGesture {
                    openWindow(value: vm.id)
                }
                .contextMenu {
                    VMContextMenu(
                        vmInstance: vm,
                        onEdit: {
                            vmToEdit = vm
                            showEditSheet = true
                        },
                        onDelete: {
                            vmToDelete = vm
                            showDeleteConfirmation = true
                        }
                    )
                }
        }
        .listStyle(.sidebar)
        .navigationTitle("Virtual Machines")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { vmManager.showingCreateVM = true }) {
                    Image(systemName: "plus")
                }
                .help("Create new VM")
            }
        }
        .confirmationDialog(
            "Delete Virtual Machine",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let vm = vmToDelete {
                    vmManager.deleteVM(vm)
                }
                vmToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                vmToDelete = nil
            }
        } message: {
            if let vm = vmToDelete {
                Text(
                    "Are you sure you want to delete \"\(vm.name)\"? This action cannot be undone.")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let vm = vmToEdit {
                EditVMView(vmInstance: vm)
            }
        }
    }
}

// MARK: - Context Menu

struct VMContextMenu: View {
    @ObservedObject var vmInstance: VMInstance
    @EnvironmentObject var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            // Power controls
            Section {
                switch vmInstance.state {
                case .stopped:
                    Button {
                        try? vmInstance.start()
                        openWindow(value: vmInstance.id)
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
                        try? vmInstance.start()
                        openWindow(value: vmInstance.id)
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }

                case .paused:
                    Button {
                        vmInstance.resume()
                        openWindow(value: vmInstance.id)
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

            Divider()

            // VM management
            Section {
                Button {
                    onEdit()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)

                Button {
                    duplicateVM()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(vmInstance.state == .running)
            }

            Divider()

            // File operations
            Section {
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

            Divider()

            // Danger zone
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
        let newName = "\(vmInstance.name) (Copy)"
        try? vmManager.createVM(
            name: newName,
            config: vmInstance.config,
            isoPath: vmInstance.isoPath,
            retinaEnabled: vmInstance.retinaEnabled
        )
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
        HStack {
            Image(systemName: "desktopcomputer")
                .foregroundColor(vmInstance.state.presentationColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(vmInstance.name)
                    .font(.headline)

                Text(vmInstance.state.presentationName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - VM Detail

struct VMDetailView: View {
    @ObservedObject var vmInstance: VMInstance
    @State private var showingConsole = true

    var body: some View {
        VStack(spacing: 0) {
            if vmInstance.state == .running || vmInstance.state == .paused {
                RunningVMDetail(vmInstance: vmInstance, showingConsole: showingConsole)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)

                    Text(vmInstance.name)
                        .font(.title)

                    Text("Click Start to boot the VM")
                        .foregroundColor(.secondary)

                    Button("Start") {
                        try? vmInstance.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                switch vmInstance.state {
                case .stopped:
                    Button(action: { try? vmInstance.start() }) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .help("Start VM")

                case .running:
                    Button(action: { vmInstance.pause() }) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause VM")

                    Button(action: { vmInstance.stop() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop VM")

                case .paused:
                    Button(action: { vmInstance.resume() }) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Resume VM")

                    Button(action: { vmInstance.stop() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop VM")
                }

                Button {
                    showingConsole.toggle()
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(showingConsole ? Color.accentColor : Color.primary)
                }
                .help("Toggle Console")
                .accessibilityValue(showingConsole ? "Shown" : "Hidden")
            }
        }
    }
}

struct VMWindowView: View {
    @EnvironmentObject private var vmManager: VMManager
    let vmID: UUID

    var body: some View {
        Group {
            if let vm = vmManager.vms.first(where: { $0.id == vmID }) {
                VMDetailView(vmInstance: vm)
                    .navigationTitle(vm.name)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Virtual Machine Not Found")
                        .font(.title2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct RunningVMDetail: View {
    @ObservedObject var vmInstance: VMInstance
    let showingConsole: Bool

    var body: some View {
        VSplitView {
            VMSurfaceRepresentable(vmInstance: vmInstance)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingConsole {
                ConsoleView()
                    .frame(minHeight: 100, idealHeight: 200, maxHeight: 400)
            }
        }
    }
}

// MARK: - Console View

struct ConsoleView: View {
    @EnvironmentObject var vmManager: VMManager
    @EnvironmentObject private var ghosttyRuntime: GhosttyRuntime

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console")
                    .font(.headline)

                Spacer()

                Button(action: { vmManager.clearConsoleOutput() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear console")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.windowBackgroundColor))

            if let app = ghosttyRuntime.app {
                GhosttyConsoleViewRepresentable(
                    app: app,
                    initialOutput: vmManager.consoleOutput,
                    events: vmManager.consoleEventPublisher
                )
            } else {
                Text("Terminal renderer unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

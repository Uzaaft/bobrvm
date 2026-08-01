//
//  ContentView.swift
//  Bobrvm
//
//  Main content view with VM list and display area.
//

import AppKit
import SwiftUI

// MARK: - Debug Build Warning

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("Debug build – performance may be degraded")
                .font(.callout)
                .padding(.vertical, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Debug Build")
                            .font(.headline)

                        Text(
                            """
                            Debug builds of Bobrvm include additional safety \
                            checks and logging that may impact performance.

                            For production use, build with:
                            """)

                        Text("zig build -Doptimize=ReleaseFast")
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(4)
                    }
                    .padding()
                    .frame(width: 320)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor).opacity(0.95))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds may have degraded performance")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var vmManager: VMManager
    @StateObject private var ghosttyRuntime = GhosttyRuntime()

    var body: some View {
        VStack(spacing: 0) {
            // Debug build warning banner
            if bobrvm_is_debug() {
                DebugBuildWarningView()
            }

            NavigationSplitView {
                VMListView()
                    .frame(minWidth: 200)
            } detail: {
                if let vm = vmManager.selectedVM {
                    VMDetailView(vmInstance: vm, ghosttyRuntime: ghosttyRuntime)
                } else {
                    VMLibraryHomeView()
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    if let vm = vmManager.selectedVM {
                        VMToolbar(vmInstance: vm)
                    }
                }
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
    @State private var vmToDelete: VMInstance?
    @State private var vmToEdit: VMInstance?
    @State private var showDeleteConfirmation = false
    @State private var showEditSheet = false

    var body: some View {
        List(vmManager.vms, selection: $vmManager.selectedVM) { vm in
            VMListRow(vmInstance: vm)
                .tag(vm)
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
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }

                case .paused:
                    Button {
                        vmInstance.resume()
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
                .foregroundColor(stateColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(vmInstance.name)
                    .font(.headline)

                Text(stateText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch vmInstance.state {
        case .running: return .green
        case .paused: return .orange
        case .stopped: return .gray
        }
    }

    private var stateText: String {
        switch vmInstance.state {
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }
}

// MARK: - VM Detail

struct VMDetailView: View {
    @ObservedObject var vmInstance: VMInstance
    @ObservedObject var ghosttyRuntime: GhosttyRuntime
    @EnvironmentObject var vmManager: VMManager
    @State private var showingConsole = true

    var body: some View {
        VStack(spacing: 0) {
            if vmInstance.state == .running || vmInstance.state == .paused {
                VSplitView {
                    VMSurfaceRepresentable(vmInstance: vmInstance)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showingConsole {
                        if let app = ghosttyRuntime.app {
                            GhosttySurfaceViewRepresentable(
                                app: app,
                                command: "/usr/bin/true",
                                workingDirectory: nil
                            )
                            .frame(minHeight: 100, idealHeight: 200, maxHeight: 400)
                        } else {
                            Text("Terminal unavailable")
                                .foregroundColor(.secondary)
                                .frame(minHeight: 100, idealHeight: 200, maxHeight: 400)
                        }
                    }
                }
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
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showingConsole) {
                    Image(systemName: "terminal")
                }
                .help("Toggle Console")
            }
        }
    }
}

// MARK: - Console View

struct ConsoleView: View {
    @EnvironmentObject var vmManager: VMManager
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console")
                    .font(.headline)

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Button(action: { vmManager.clearConsoleOutput() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear console")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.windowBackgroundColor))

            ScrollViewReader { proxy in
                ScrollView {
                    Text(vmManager.consoleOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("console-bottom")
                }
                .background(Color(.textBackgroundColor))
                .onChange(of: vmManager.consoleOutput) { _ in
                    if autoScroll {
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Toolbar

struct VMToolbar: View {
    @ObservedObject var vmInstance: VMInstance

    var body: some View {
        HStack {
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
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var vmManager: VMManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No VM Selected")
                .font(.title2)

            Text("Create a new virtual machine or select one from the sidebar")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Create VM") {
                vmManager.showingCreateVM = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(VMManager())
}

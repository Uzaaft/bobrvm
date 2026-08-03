//
//  VMLibraryView.swift
//  Bobrvm
//
//  Virtual machine chooser shown when no VM is selected.
//

import SwiftUI

struct VMLibraryHomeView: View {
    @EnvironmentObject private var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow
    @State private var startError: String?

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if vmManager.vms.isEmpty {
                emptyLibrary
            } else {
                vmGrid
            }
        }
        .navigationTitle("Library")
        .alert(
            "Unable to Start Virtual Machine",
            isPresented: Binding(
                get: { startError != nil },
                set: { if !$0 { startError = nil } }
            )
        ) {
            Button("OK") { startError = nil }
        } message: {
            Text(startError ?? "An unknown error occurred.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Virtual Machine Library")
                    .font(.title2.bold())
                Text("Choose a virtual machine or create a new one.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                vmManager.showingCreateVM = true
            } label: {
                Label("New Virtual Machine…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private var vmGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vmManager.vms) { vm in
                    VMLibraryCard(
                        vmInstance: vm,
                        start: { start(vm) },
                        pause: { vm.pause() },
                        resume: { vm.resume() },
                        stop: { vm.stop() }
                    )
                }
            }
            .padding(24)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No Virtual Machines")
                .font(.title2.bold())
            Text("Create a virtual machine from an ISO image or attach an existing disk.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Virtual Machine…") {
                vmManager.showingCreateVM = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func start(_ vm: VMInstance) {
        do {
            try vm.start()
            openWindow(id: "vm-display", value: vm.id)
        } catch {
            startError = error.localizedDescription
        }
    }
}

private struct VMLibraryCard: View {
    @ObservedObject var vmInstance: VMInstance
    let start: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(vmInstance.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Virtual machine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StateBadge(state: vmInstance.state)
            }
            Divider()
            HStack(spacing: 18) {
                MetricLabel(
                    icon: "cpu",
                    value: "\(vmInstance.config.vcpuCount) cores"
                )
                MetricLabel(
                    icon: "memorychip",
                    value: memoryText
                )
            }
            HStack(spacing: 18) {
                MetricLabel(
                    icon: "internaldrive",
                    value: diskText
                )
                MetricLabel(
                    icon: "display",
                    value: displayText
                )
            }
            MetricLabel(
                icon: "opticaldisc",
                value: opticalDriveText
            )
            HStack {
                Spacer()
                controls
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            contextMenuItems
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch vmInstance.state {
        case .stopped:
            ControlButton(title: "Start", icon: "play.fill", action: start)
        case .paused:
            ControlButton(title: "Resume", icon: "play.fill", action: resume)
        case .running:
            ControlButton(title: "Pause", icon: "pause.fill", action: pause)
            ControlButton(title: "Stop", icon: "stop.fill", role: .destructive, action: stop)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        switch vmInstance.state {
        case .stopped:
            Button("Start", systemImage: "play.fill", action: start)
        case .paused:
            Button("Resume", systemImage: "play.fill", action: resume)
        case .running:
            Button("Pause", systemImage: "pause.fill", action: pause)
            Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
        }
    }

    private var memoryText: String {
        let bytesPerGB = UInt64(1024 * 1024 * 1024)
        return "\(vmInstance.config.memoryBytes / bytesPerGB) GB"
    }

    private var diskText: String {
        guard let path = vmInstance.config.diskPath,
            let size = DiskManager.sizeGB(path: path)
        else {
            return "No disk"
        }
        return "\(size) GB"
    }

    private var displayText: String {
        "Up to \(vmInstance.config.displayWidth) × \(vmInstance.config.displayHeight)"
    }

    private var opticalDriveText: String {
        guard let path = vmInstance.isoPath else { return "CD/DVD: Empty" }
        return "CD/DVD: \(URL(fileURLWithPath: path).lastPathComponent)"
    }
}

private struct ControlButton: View {
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct MetricLabel: View {
    let icon: String
    let value: String

    var body: some View {
        Label(value, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct StateBadge: View {
    let state: VMState

    var body: some View {
        Text(state.presentationName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(state.presentationColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.presentationColor.opacity(0.12))
            .clipShape(Capsule())
    }
}

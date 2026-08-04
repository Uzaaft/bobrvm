import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultMemoryGB") private var defaultMemoryGB = 4
    @AppStorage("defaultVCPUs") private var defaultVCPUs = 2

    private let systemInfo = SystemInfo()

    var body: some View {
        TabView {
            GeneralSettingsView(
                defaultMemoryGB: $defaultMemoryGB,
                defaultVCPUs: $defaultVCPUs,
                systemInfo: systemInfo
            )
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
        }
        .frame(width: 450, height: 250)
    }
}

struct GeneralSettingsView: View {
    @Binding var defaultMemoryGB: Int
    @Binding var defaultVCPUs: Int
    let systemInfo: SystemInfo

    var body: some View {
        Form {
            Section("Default VM Settings") {
                Picker("Memory", selection: $defaultMemoryGB) {
                    ForEach(memoryOptions, id: \.self) { gb in
                        Text("\(gb) GB").tag(gb)
                    }
                }

                Picker("CPUs", selection: $defaultVCPUs) {
                    ForEach(cpuOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
            }

            Section("System Information") {
                LabeledContent("Total Memory", value: "\(systemInfo.totalMemoryGB) GB")
                LabeledContent("CPU Cores", value: "\(systemInfo.cpuCount)")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var memoryOptions: [Int] {
        let options = [1, 2, 4, 8, 16, 32, 64, 128]
        return options.filter { $0 <= systemInfo.maxMemoryGB }
    }

    private var cpuOptions: [Int] {
        Array(1...systemInfo.cpuCount)
    }
}

#Preview {
    SettingsView()
}

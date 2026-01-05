import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var settings = UserSettings.shared
    @ObservedObject var printerManager: PrinterManager
    @ObservedObject var bluetoothManager: BluetoothManager

    @State private var showingPrinterSearch = false
    @State private var showingDeviceSearch = false
    @State private var showingClearHistoryConfirmation = false
    @State private var historyCount: Int = 0

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Gas Analyzer Section
                Section("Gas Analyzer") {
                    if let deviceName = bluetoothManager.connectedDeviceName {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(deviceName)
                                    .font(.body)
                                Text(bluetoothManager.connectionState.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if bluetoothManager.connectionState == .connected {
                                Text("\(bluetoothManager.signalStrength) dBm")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Circle()
                                .fill(deviceStatusColor)
                                .frame(width: 10, height: 10)
                        }

                        Button("Change Device") {
                            showingDeviceSearch = true
                        }

                        Button("Disconnect", role: .destructive) {
                            bluetoothManager.disconnect()
                        }
                    } else {
                        Text(bluetoothManager.connectionState.rawValue)
                            .foregroundColor(.secondary)

                        Button("Connect Device") {
                            showingDeviceSearch = true
                        }
                        .disabled(bluetoothManager.connectionState == .bluetoothOff)
                    }

                    if bluetoothManager.connectionState == .bluetoothOff {
                        Text("Please enable Bluetooth in Settings")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // MARK: - Printer Section
                Section("Printer") {
                    if let printerName = printerManager.connectedPrinterName {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(printerName)
                                    .font(.body)
                                Text(printerManager.connectionState.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(printerStatusColor)
                                .frame(width: 10, height: 10)
                        }

                        Button("Change Printer") {
                            showingPrinterSearch = true
                        }

                        Button("Forget Printer", role: .destructive) {
                            printerManager.disconnect()
                        }
                    } else {
                        Button("Connect Printer") {
                            showingPrinterSearch = true
                        }
                    }

                    if let error = printerManager.errorMessage {
                        HStack {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                            Spacer()
                            Button {
                                printerManager.clearError()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: - Units Section
                Section("Units") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Temperature")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Temperature", selection: $settings.temperatureUnitRaw) {
                            Text("°F").tag("F")
                            Text("°C").tag("C")
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Depth")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Depth", selection: $settings.depthUnitRaw) {
                            Text("ft").tag("ft")
                            Text("m").tag("m")
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // MARK: - MOD Settings Section
                Section {
                    HStack {
                        Text("PPO\u{2082} for MOD")
                        Spacer()
                        Text(String(format: "%.1f", settings.ppo2ForMOD))
                            .foregroundColor(settings.ppo2ForMOD > 1.6 ? .red : .primary)
                            .fontWeight(.medium)
                        Stepper("", value: $settings.ppo2ForMOD, in: 1.0...2.0, step: 0.1)
                            .labelsHidden()
                    }

                    if settings.ppo2ForMOD > 1.6 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("PPO\u{2082} above 1.6 increases oxygen toxicity risk")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("MOD Calculation")
                } footer: {
                    Text("Standard recreational limit is 1.4. Technical diving commonly uses 1.6. Values above 1.6 are for advanced applications only.")
                }

                // MARK: - Appearance Section
                Section("Appearance") {
                    Picker("Mode", selection: $settings.appearanceModeRaw) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                }

                // MARK: - Data Management Section
                Section("Data Management") {
                    Button(role: .destructive) {
                        showingClearHistoryConfirmation = true
                    } label: {
                        HStack {
                            Text("Clear Print History")
                            Spacer()
                            Text("\(historyCount) labels")
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(historyCount == 0)
                }

                // MARK: - About Section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingPrinterSearch) {
                PrinterSearchView(printerManager: printerManager)
            }
            .sheet(isPresented: $showingDeviceSearch) {
                DeviceSearchView(bluetoothManager: bluetoothManager)
            }
            .alert("Clear All History?", isPresented: $showingClearHistoryConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    HistoryManager.shared.deleteAllLabels(context: modelContext)
                    updateHistoryCount()
                }
            } message: {
                Text("This will permanently delete all \(historyCount) printed labels. This action cannot be undone.")
            }
            .onAppear {
                updateHistoryCount()
            }
        }
    }

    private var deviceStatusColor: Color {
        if bluetoothManager.isSimulating {
            return .purple
        }
        switch bluetoothManager.connectionState {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .bluetoothOff, .unauthorized: return .red
        default: return .gray
        }
    }

    private var printerStatusColor: Color {
        switch printerManager.connectionState {
        case .connected: return .green
        case .printing: return .blue
        case .error: return .red
        default: return .orange
        }
    }

    private func updateHistoryCount() {
        let descriptor = FetchDescriptor<PrintedLabel>()
        historyCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

// MARK: - Printer Search View

struct PrinterSearchView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var printerManager: PrinterManager

    var body: some View {
        NavigationView {
            List {
                if printerManager.connectionState == .searching {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Searching for printers...")
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(printerManager.discoveredPrinters) { printer in
                    Button {
                        printerManager.connect(to: printer)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "printer.fill")
                                .foregroundColor(.blue)
                            Text(printer.name)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if printerManager.discoveredPrinters.isEmpty && printerManager.connectionState != .searching {
                    VStack(spacing: 12) {
                        Image(systemName: "printer.dotmatrix")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No printers found")
                            .foregroundColor(.secondary)
                        Text("Make sure your Brother QL-820NWB is powered on and Bluetooth is enabled.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }

                if let error = printerManager.errorMessage {
                    HStack {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                        Spacer()
                        Button {
                            printerManager.clearError()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Select Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        printerManager.stopSearching()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if printerManager.connectionState == .searching {
                        Button("Stop") {
                            printerManager.stopSearching()
                        }
                    } else {
                        Button("Search") {
                            printerManager.startSearching()
                        }
                    }
                }
            }
            .onAppear {
                printerManager.startSearching()
            }
            .onDisappear {
                printerManager.stopSearching()
            }
        }
    }
}

// MARK: - Device Search View

struct DeviceSearchView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        NavigationView {
            List {
                // MARK: - Demo Section
                Section("Demo") {
                    Button {
                        bluetoothManager.startSimulation()
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "waveform.path")
                                .foregroundColor(.purple)
                            VStack(alignment: .leading) {
                                Text("GasTag Simulator")
                                    .foregroundColor(.primary)
                                Text("Demo Mode")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Available Devices Section
                Section("Available Devices") {
                    if bluetoothManager.connectionState == .scanning {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Searching for GasTag Bridge...")
                                .foregroundColor(.secondary)
                        }
                    }

                    ForEach(bluetoothManager.discoveredDevices) { device in
                        Button {
                            bluetoothManager.connect(to: device)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "wave.3.right")
                                    .foregroundColor(.blue)
                                Text(device.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if bluetoothManager.discoveredDevices.isEmpty && bluetoothManager.connectionState != .scanning {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No devices found")
                                .foregroundColor(.secondary)
                            Text("Make sure your GasTag Bridge is powered on and nearby.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        bluetoothManager.stopScanning()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if bluetoothManager.connectionState == .scanning {
                        Button("Stop") {
                            bluetoothManager.stopScanning()
                        }
                    } else {
                        Button("Search") {
                            bluetoothManager.startScanning()
                        }
                    }
                }
            }
            .onAppear {
                bluetoothManager.startScanning()
            }
            .onDisappear {
                bluetoothManager.stopScanning()
            }
        }
    }
}

// MARK: - Previews

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(printerManager: PrinterManager.shared, bluetoothManager: BluetoothManager())
    }
}

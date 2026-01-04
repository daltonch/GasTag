import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MainView()
                .tabItem {
                    Label("GasTag", systemImage: "gauge.with.dots.needle.bottom.50percent")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
        }
    }
}

struct MainView: View {
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var printerManager = PrinterManager.shared
    @StateObject private var settings = UserSettings.shared
    @Environment(\.modelContext) private var modelContext

    @State private var showingSettings = false
    @State private var isPrinting = false
    @State private var showPrintError = false
    @State private var printErrorMessage = ""
    @State private var showingDeviceSearch = false
    @State private var showingPrinterSearch = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Status Card
                    HStack(spacing: 16) {
                        // Gas Analyzer status (tappable)
                        Button {
                            showingDeviceSearch = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: bluetoothIcon)
                                    .foregroundColor(bluetoothColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bluetoothManager.connectedDeviceName ?? "No Device")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    Text(bluetoothStatusText)
                                        .font(.caption)
                                        .foregroundColor(bluetoothStatusColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // Printer status (tappable)
                        Button {
                            showingPrinterSearch = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: printerManager.connectionState == .connected ? "printer.fill" : "printer")
                                    .foregroundColor(printerManager.connectionState == .connected ? .green : .gray)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(printerManager.connectedPrinterName ?? "No Printer")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    Text(printerManager.connectionState.rawValue)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Label Preview
                    LabelPreviewCard(
                        reading: bluetoothManager.currentReading,
                        isActivelyReceiving: bluetoothManager.connectionState == .connected && bluetoothManager.isReceivingData,
                        settings: settings
                    )
                    .padding(.horizontal, 4)

                    // Mix Label Preview (conditional)
                    if settings.printMixLabel {
                        MixLabelPreviewCard(reading: bluetoothManager.currentReading)
                            .padding(.horizontal, 4)
                    }

                    // Mix Label Toggle
                    Toggle("Print Mix Label", isOn: $settings.printMixLabel)
                        .padding(.horizontal)

                    // Print Button
                    Button(action: printLabel) {
                        HStack {
                            if isPrinting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding(.trailing, 4)
                            } else {
                                Image(systemName: "printer.fill")
                            }
                            Text(isPrinting ? "Printing..." : "Print Label")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canPrint ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!canPrint || isPrinting)

                    if !canPrint && bluetoothManager.currentReading != nil {
                        Text("Connect a printer in Settings to print labels")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Raw Data Log
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Raw Data Log")
                            .font(.headline)

                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(bluetoothManager.rawLines.enumerated()), id: \.offset) { index, line in
                                        Text(line)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(lineColor(for: line))
                                            .id(index)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 150)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .onChange(of: bluetoothManager.rawLines.count) {
                                if let lastIndex = bluetoothManager.rawLines.indices.last {
                                    withAnimation {
                                        proxy.scrollTo(lastIndex, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("GasTag")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(printerManager: printerManager, bluetoothManager: bluetoothManager)
            }
            .sheet(isPresented: $showingDeviceSearch) {
                DeviceSearchView(bluetoothManager: bluetoothManager)
            }
            .sheet(isPresented: $showingPrinterSearch) {
                PrinterSearchView(printerManager: printerManager)
            }
            .alert("Print Error", isPresented: $showPrintError) {
                Button("OK", role: .cancel) {
                    printerManager.clearError()
                }
            } message: {
                Text(printErrorMessage)
            }
        }
    }

    // MARK: - Computed Properties

    private var canPrint: Bool {
        bluetoothManager.currentReading != nil && printerManager.connectionState == .connected
    }

    private var bluetoothStatusText: String {
        if bluetoothManager.connectionState == .connected && bluetoothManager.isReceivingData {
            return "Receiving"
        }
        return bluetoothManager.connectionState.rawValue
    }

    private var bluetoothStatusColor: Color {
        if bluetoothManager.connectionState == .connected && bluetoothManager.isReceivingData {
            return .cyan
        }
        return .secondary
    }

    private var bluetoothIcon: String {
        switch bluetoothManager.connectionState {
        case .disconnected:
            return "antenna.radiowaves.left.and.right"
        case .scanning:
            return "antenna.radiowaves.left.and.right"
        case .connecting:
            return "antenna.radiowaves.left.and.right"
        case .connected:
            return "checkmark.circle.fill"
        case .disconnecting:
            return "antenna.radiowaves.left.and.right"
        case .bluetoothOff:
            return "antenna.radiowaves.left.and.right.slash"
        case .unauthorized:
            return "exclamationmark.triangle.fill"
        }
    }

    private var bluetoothColor: Color {
        switch bluetoothManager.connectionState {
        case .disconnected:
            return .secondary
        case .scanning:
            return .blue
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .disconnecting:
            return .orange
        case .bluetoothOff:
            return .red
        case .unauthorized:
            return .red
        }
    }

    private func lineColor(for line: String) -> Color {
        if line.hasPrefix("[Error]") {
            return .red
        } else if line.hasPrefix("[Info]") || line.hasPrefix("[Connected]") {
            return .blue
        } else if line.contains("He") && line.contains("O2") {
            return .primary
        }
        return .secondary
    }

    // MARK: - Actions

    private func printLabel() {
        guard let reading = bluetoothManager.currentReading else { return }

        isPrinting = true

        let isActivelyReceiving = bluetoothManager.connectionState == .connected && bluetoothManager.isReceivingData

        let labelView = LabelView(
            helium: reading.helium,
            heliumIsStale: reading.heliumIsStale || !isActivelyReceiving,
            oxygen: reading.oxygen,
            oxygenIsStale: reading.oxygenIsStale || !isActivelyReceiving,
            temperature: reading.temperature,
            timestamp: reading.timestamp,
            customText: settings.customLabelText,
            depthUnit: settings.depthUnit
        )

        Task { @MainActor in
            guard let image = labelView.renderToImage() else {
                isPrinting = false
                printErrorMessage = "Failed to render label image"
                showPrintError = true
                return
            }

            let success = await printerManager.printLabel(image: image)

            if success {
                // Print mix label if enabled
                if settings.printMixLabel {
                    let mixLabelView = MixLabelView(
                        helium: reading.helium,
                        oxygen: reading.oxygen
                    )

                    if let mixImage = mixLabelView.renderToImage() {
                        let mixSuccess = await printerManager.printLabel(image: mixImage)
                        if !mixSuccess {
                            // Show warning but don't fail overall - main label printed successfully
                            isPrinting = false
                            printErrorMessage = "Main label printed. Mix label failed: \(printerManager.errorMessage ?? "Unknown error")"
                            showPrintError = true
                            // Still save to history since main label succeeded
                            HistoryManager.shared.saveLabel(
                                helium: reading.helium,
                                oxygen: reading.oxygen,
                                temperature: reading.temperature,
                                analyzerTimestamp: reading.timestamp,
                                labelText: settings.customLabelText,
                                context: modelContext
                            )
                            return
                        }
                    }
                }

                // Save to history on successful print
                isPrinting = false
                HistoryManager.shared.saveLabel(
                    helium: reading.helium,
                    oxygen: reading.oxygen,
                    temperature: reading.temperature,
                    analyzerTimestamp: reading.timestamp,
                    labelText: settings.customLabelText,
                    context: modelContext
                )
            } else {
                isPrinting = false
                printErrorMessage = printerManager.errorMessage ?? "Unknown print error"
                showPrintError = true
            }
        }
    }
}

#Preview {
    ContentView()
}

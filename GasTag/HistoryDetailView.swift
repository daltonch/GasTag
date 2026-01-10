import SwiftUI
import SwiftData

struct HistoryDetailView: View {
    let label: PrintedLabel
    @ObservedObject private var settings = UserSettings.shared
    @StateObject private var printerManager = PrinterManager.shared
    @State private var showingShareSheet = false
    @State private var isPrinting = false
    @State private var showPrintError = false
    @State private var printErrorMessage = ""

    private var formattedTemp: String {
        settings.formattedTemperature(label.temperature)
    }

    private var formattedPrintTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: label.timestamp)
    }

    private var canReprint: Bool {
        !label.isSimulated && printerManager.connectionState == .connected
    }

    var body: some View {
        List {
            Section("Gas Mix") {
                HStack {
                    Text("Helium")
                    Spacer()
                    Text("\(String(format: "%.1f", label.helium))%")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Oxygen")
                    Spacer()
                    Text("\(String(format: "%.1f", label.oxygen))%")
                        .foregroundColor(.secondary)
                }
            }

            Section("Conditions") {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(formattedTemp)
                        .foregroundColor(.secondary)
                }
            }

            Section("Timestamps") {
                HStack {
                    Text("Analyzed")
                    Spacer()
                    Text(label.analyzerTimestamp)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Printed")
                    Spacer()
                    Text(formattedPrintTime)
                        .foregroundColor(.secondary)
                }
            }

            if !label.labelText.isEmpty {
                Section("Label") {
                    Text(label.labelText)
                }
            }

            if label.isSimulated {
                Section {
                    HStack {
                        Image(systemName: "waveform.path")
                            .foregroundColor(.purple)
                        Text("This label was created in simulation mode")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Label Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    // Re-print button
                    if canReprint {
                        Button {
                            reprintLabel()
                        } label: {
                            if isPrinting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                            } else {
                                Image(systemName: "printer.fill")
                            }
                        }
                        .disabled(isPrinting)
                    }

                    // Share button
                    Button {
                        showingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            let text = HistoryManager.shared.formatSingleLabel(label, temperatureUnit: settings.temperatureUnit)
            ShareSheet(items: [text])
        }
        .alert("Print Error", isPresented: $showPrintError) {
            Button("OK", role: .cancel) {
                printerManager.clearError()
            }
        } message: {
            Text(printErrorMessage)
        }
    }

    // MARK: - Actions

    private func reprintLabel() {
        isPrinting = true

        let labelView = LabelView(
            helium: label.helium,
            heliumIsStale: false,  // Historical data - not showing stale indicators since data was valid when originally printed
            oxygen: label.oxygen,
            oxygenIsStale: false,  // Historical data - not showing stale indicators since data was valid when originally printed
            temperature: label.temperature,
            timestamp: label.analyzerTimestamp,
            customText: label.labelText,
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
                        helium: label.helium,
                        oxygen: label.oxygen
                    )

                    if let mixImage = mixLabelView.renderToImage() {
                        let mixSuccess = await printerManager.printLabel(image: mixImage)
                        if !mixSuccess {
                            // Show warning but don't fail overall
                            isPrinting = false
                            printErrorMessage = "Main label printed. Mix label failed: \(printerManager.errorMessage ?? "Unknown error")"
                            showPrintError = true
                            return
                        }
                    }
                }
                isPrinting = false
            } else {
                isPrinting = false
                printErrorMessage = printerManager.errorMessage ?? "Unknown print error"
                showPrintError = true
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

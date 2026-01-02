import SwiftUI
import SwiftData

struct HistoryDetailView: View {
    let label: PrintedLabel
    @ObservedObject private var settings = UserSettings.shared
    @State private var showingShareSheet = false

    private var formattedTemp: String {
        settings.formattedTemperature(label.temperature)
    }

    private var formattedPrintTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: label.timestamp)
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
        }
        .navigationTitle("Label Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            let text = HistoryManager.shared.formatSingleLabel(label, temperatureUnit: settings.temperatureUnit)
            ShareSheet(items: [text])
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

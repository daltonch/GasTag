import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PrintedLabel.timestamp, order: .reverse) private var labels: [PrintedLabel]
    @ObservedObject private var settings = UserSettings.shared
    @StateObject private var printerManager = PrinterManager.shared

    @State private var isSelecting = false
    @State private var selectedLabels: Set<UUID> = []
    @State private var showingDeleteConfirmation = false
    @State private var labelToDelete: PrintedLabel?
    @State private var showingExportSheet = false
    @State private var exportURL: URL?
    @State private var showPrintError = false
    @State private var printErrorMessage = ""

    private func canReprint(_ label: PrintedLabel) -> Bool {
        !label.isSimulated && printerManager.connectionState == .connected
    }

    var body: some View {
        NavigationView {
            Group {
                if labels.isEmpty {
                    emptyState
                } else {
                    labelList
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !labels.isEmpty {
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            if !isSelecting {
                                selectedLabels.removeAll()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !labels.isEmpty {
                        Menu {
                            Button {
                                exportAll()
                            } label: {
                                Label("Export All", systemImage: "square.and.arrow.up")
                            }
                            if isSelecting && !selectedLabels.isEmpty {
                                Button {
                                    exportSelected()
                                } label: {
                                    Label("Export Selected (\(selectedLabels.count))", systemImage: "square.and.arrow.up")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert("Delete Label?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    labelToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let label = labelToDelete {
                        HistoryManager.shared.deleteLabel(label, context: modelContext)
                        labelToDelete = nil
                    }
                }
            } message: {
                Text("This action cannot be undone.")
            }
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Printed Labels")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Labels you print will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var labelList: some View {
        List {
            ForEach(labels) { label in
                if isSelecting {
                    selectableRow(for: label)
                } else {
                    NavigationLink(destination: HistoryDetailView(label: label)) {
                        labelRow(for: label)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if canReprint(label) {
                            Button {
                                reprintLabel(label)
                            } label: {
                                Label("Re-print", systemImage: "printer.fill")
                            }
                            .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            labelToDelete = label
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func selectableRow(for label: PrintedLabel) -> some View {
        Button {
            if selectedLabels.contains(label.id) {
                selectedLabels.remove(label.id)
            } else {
                selectedLabels.insert(label.id)
            }
        } label: {
            HStack {
                Image(systemName: selectedLabels.contains(label.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedLabels.contains(label.id) ? .blue : .secondary)
                labelRow(for: label)
            }
        }
        .buttonStyle(.plain)
    }

    private func labelRow(for label: PrintedLabel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("He: \(String(format: "%.1f", label.helium))%")
                Text("O₂: \(String(format: "%.1f", label.oxygen))%")
                if label.isSimulated {
                    Text("SIM")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple)
                        .cornerRadius(4)
                }
                Spacer()
                Text(formatDate(label.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text(label.labelText.isEmpty ? "No label" : label.labelText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTime(label.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy"
        return formatter.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func exportAll() {
        if let url = HistoryManager.shared.createCSVFile(labels) {
            exportURL = url
            showingExportSheet = true
        }
    }

    private func exportSelected() {
        let selectedItems = labels.filter { selectedLabels.contains($0.id) }
        if let url = HistoryManager.shared.createCSVFile(selectedItems) {
            exportURL = url
            showingExportSheet = true
        }
    }

    private func reprintLabel(_ label: PrintedLabel) {
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
                            printErrorMessage = "Main label printed. Mix label failed: \(printerManager.errorMessage ?? "Unknown error")"
                            showPrintError = true
                            return
                        }
                    }
                }
            } else {
                printErrorMessage = printerManager.errorMessage ?? "Unknown print error"
                showPrintError = true
            }
        }
    }
}

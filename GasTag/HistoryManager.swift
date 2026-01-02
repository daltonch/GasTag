import Foundation
import SwiftData

@MainActor
class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    private init() {}

    // MARK: - Save

    func saveLabel(
        helium: Double,
        oxygen: Double,
        temperature: Double,
        analyzerTimestamp: String,
        labelText: String,
        context: ModelContext
    ) {
        let label = PrintedLabel(
            helium: helium,
            oxygen: oxygen,
            temperature: temperature,
            analyzerTimestamp: analyzerTimestamp,
            labelText: labelText
        )
        context.insert(label)
        try? context.save()
    }

    // MARK: - Delete

    func deleteLabel(_ label: PrintedLabel, context: ModelContext) {
        context.delete(label)
        try? context.save()
    }

    func deleteAllLabels(context: ModelContext) {
        do {
            try context.delete(model: PrintedLabel.self)
            try context.save()
        } catch {
            print("Failed to delete all labels: \(error)")
        }
    }

    // MARK: - Export

    func formatSingleLabel(_ label: PrintedLabel, temperatureUnit: TemperatureUnit) -> String {
        let tempValue: Double
        let tempSymbol: String
        if temperatureUnit == .celsius {
            tempValue = (label.temperature - 32) * 5/9
            tempSymbol = "°C"
        } else {
            tempValue = label.temperature
            tempSymbol = "°F"
        }

        let printFormatter = DateFormatter()
        printFormatter.dateFormat = "MM/dd/yyyy HH:mm"

        return """
        Gas Label - \(label.labelText.isEmpty ? "Unlabeled" : label.labelText)
        He: \(String(format: "%.1f", label.helium))%  O₂: \(String(format: "%.1f", label.oxygen))%
        Temp: \(String(format: "%.1f", tempValue))\(tempSymbol)
        Analyzed: \(label.analyzerTimestamp)
        Printed: \(printFormatter.string(from: label.timestamp))
        """
    }

    func exportToCSV(_ labels: [PrintedLabel]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var csv = "Label Text,Helium %,Oxygen %,Temperature (F),Analyzer Time,Print Time\n"

        for label in labels {
            let labelText = escapeCSV(label.labelText)
            let line = "\(labelText),\(String(format: "%.1f", label.helium)),\(String(format: "%.1f", label.oxygen)),\(String(format: "%.1f", label.temperature)),\(escapeCSV(label.analyzerTimestamp)),\(dateFormatter.string(from: label.timestamp))"
            csv += line + "\n"
        }

        return csv
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    func createCSVFile(_ labels: [PrintedLabel]) -> URL? {
        let csv = exportToCSV(labels)
        let fileName = "GasTag_Labels_\(Date().timeIntervalSince1970).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try csv.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            print("Failed to create CSV file: \(error)")
            return nil
        }
    }
}

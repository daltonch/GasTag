import Foundation
import SwiftData

@Model
class PrintedLabel {
    var id: UUID
    var helium: Double
    var oxygen: Double
    var temperature: Double
    var timestamp: Date
    var analyzerTimestamp: String
    var labelText: String

    init(helium: Double, oxygen: Double, temperature: Double, analyzerTimestamp: String, labelText: String) {
        self.id = UUID()
        self.helium = helium
        self.oxygen = oxygen
        self.temperature = temperature
        self.timestamp = Date()
        self.analyzerTimestamp = analyzerTimestamp
        self.labelText = labelText
    }
}

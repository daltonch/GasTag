import Foundation
import SwiftUI

enum TemperatureUnit: String, CaseIterable {
    case fahrenheit = "F"
    case celsius = "C"

    var symbol: String {
        switch self {
        case .fahrenheit: return "°F"
        case .celsius: return "°C"
        }
    }
}

enum DepthUnit: String, CaseIterable {
    case feet = "ft"
    case meters = "m"
}

enum AppearanceMode: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

class UserSettings: ObservableObject {
    static let shared = UserSettings()

    private let defaults = UserDefaults.standard

    @Published var printerIdentifier: String? {
        didSet { defaults.set(printerIdentifier, forKey: "printerIdentifier") }
    }
    @Published var printerName: String? {
        didSet { defaults.set(printerName, forKey: "printerName") }
    }
    @Published var temperatureUnitRaw: String = "F" {
        didSet { defaults.set(temperatureUnitRaw, forKey: "temperatureUnit") }
    }
    @Published var depthUnitRaw: String = "ft" {
        didSet { defaults.set(depthUnitRaw, forKey: "depthUnit") }
    }
    @Published var customLabelText: String = "Stage 1" {
        didSet { defaults.set(customLabelText, forKey: "customLabelText") }
    }
    @Published var ppo2ForMOD: Double = 1.6 {
        didSet { defaults.set(ppo2ForMOD, forKey: "ppo2ForMOD") }
    }
    @Published var appearanceModeRaw: String = "System" {
        didSet { defaults.set(appearanceModeRaw, forKey: "appearanceMode") }
    }
    @Published var printMixLabel: Bool = false {
        didSet { defaults.set(printMixLabel, forKey: "printMixLabel") }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    // Cached tank names - loaded once at init
    @Published var savedTankNames: [String] = ["Stage 1"]

    init() {
        // Load saved values from UserDefaults
        printerIdentifier = defaults.string(forKey: "printerIdentifier")
        printerName = defaults.string(forKey: "printerName")
        temperatureUnitRaw = defaults.string(forKey: "temperatureUnit") ?? "F"
        depthUnitRaw = defaults.string(forKey: "depthUnit") ?? "ft"
        customLabelText = defaults.string(forKey: "customLabelText") ?? "Stage 1"
        ppo2ForMOD = defaults.double(forKey: "ppo2ForMOD")
        if ppo2ForMOD == 0 { ppo2ForMOD = 1.6 }
        appearanceModeRaw = defaults.string(forKey: "appearanceMode") ?? "System"
        printMixLabel = defaults.bool(forKey: "printMixLabel")

        // Load tank names from JSON
        if let data = defaults.data(forKey: "savedTankNames"),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            savedTankNames = names
        }
    }

    private func persistTankNames() {
        if let data = try? JSONEncoder().encode(savedTankNames) {
            defaults.set(data, forKey: "savedTankNames")
        }
    }

    func saveTankName(_ name: String) {
        guard !name.isEmpty else { return }
        // Remove if exists to avoid duplicates, then add to front
        savedTankNames.removeAll { $0 == name }
        savedTankNames.insert(name, at: 0)
        // Keep only last 10 names
        if savedTankNames.count > 10 {
            savedTankNames = Array(savedTankNames.prefix(10))
        }
        persistTankNames()
    }

    func removeTankName(_ name: String) {
        savedTankNames.removeAll { $0 == name }
        persistTankNames()
    }

    var temperatureUnit: TemperatureUnit {
        get { TemperatureUnit(rawValue: temperatureUnitRaw) ?? .fahrenheit }
        set { temperatureUnitRaw = newValue.rawValue }
    }

    var depthUnit: DepthUnit {
        get { DepthUnit(rawValue: depthUnitRaw) ?? .feet }
        set { depthUnitRaw = newValue.rawValue }
    }

    // MARK: - Unit Conversions

    func convertTemperature(_ fahrenheit: Double) -> Double {
        switch temperatureUnit {
        case .fahrenheit: return fahrenheit
        case .celsius: return (fahrenheit - 32) * 5/9
        }
    }

    func calculateMOD(oxygenPercent: Double, ppo2: Double? = nil) -> Double {
        guard oxygenPercent > 0 else { return 0 }
        let effectivePPO2 = ppo2 ?? ppo2ForMOD
        let fo2 = oxygenPercent / 100.0
        let modFeet = ((effectivePPO2 / fo2) - 1) * 33
        switch depthUnit {
        case .feet: return modFeet
        case .meters: return modFeet * 0.3048
        }
    }

    func formattedMOD(oxygenPercent: Double) -> String {
        let mod = calculateMOD(oxygenPercent: oxygenPercent)
        return String(format: "%.0f %@", mod, depthUnit.rawValue)
    }

    var isPPO2Warning: Bool {
        ppo2ForMOD > 1.6
    }

    func formattedTemperature(_ fahrenheit: Double) -> String {
        let converted = convertTemperature(fahrenheit)
        return String(format: "%.1f%@", converted, temperatureUnit.symbol)
    }

    // MARK: - Printer Management

    func savePrinter(identifier: String, name: String) {
        printerIdentifier = identifier
        printerName = name
    }

    func forgetPrinter() {
        printerIdentifier = nil
        printerName = nil
    }

    var hasSavedPrinter: Bool {
        printerIdentifier != nil
    }
}

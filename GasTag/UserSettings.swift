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

    private let defaults: UserDefaults

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
    @Published var waterTypeRaw: String = WaterType.fresh.rawValue {
        didSet { defaults.set(waterTypeRaw, forKey: "waterType") }
    }
    @Published var preferredDensity: Double = 5.2 {
        didSet { defaults.set(preferredDensity, forKey: "preferredDensity") }
    }
    @Published var showDensityDepthOnLabel: Bool = false {
        didSet { defaults.set(showDensityDepthOnLabel, forKey: "showDensityDepthOnLabel") }
    }
    @Published var showENDOnLabel: Bool = false {
        didSet { defaults.set(showENDOnLabel, forKey: "showENDOnLabel") }
    }
    @Published var oxygenIsNarcotic: Bool = true {
        didSet { defaults.set(oxygenIsNarcotic, forKey: "oxygenIsNarcotic") }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    // Cached tank names - loaded once at init
    @Published var savedTankNames: [String] = ["Stage 1"]

    /// `defaults` is injectable so tests can use an isolated suite instead of
    /// writing into the app's real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

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
        waterTypeRaw = defaults.string(forKey: "waterType") ?? WaterType.fresh.rawValue
        preferredDensity = defaults.double(forKey: "preferredDensity")
        if preferredDensity == 0 { preferredDensity = 5.2 }
        showDensityDepthOnLabel = defaults.bool(forKey: "showDensityDepthOnLabel")
        showENDOnLabel = defaults.bool(forKey: "showENDOnLabel")
        oxygenIsNarcotic = defaults.object(forKey: "oxygenIsNarcotic") as? Bool ?? true

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

    var waterType: WaterType {
        get { WaterType(rawValue: waterTypeRaw) ?? .fresh }
        set { waterTypeRaw = newValue.rawValue }
    }

    func calculateMOD(oxygenPercent: Double, ppo2: Double? = nil) -> Double {
        guard let modMeters = GasCalculations.modMeters(
            oxygenPercent: oxygenPercent, ppo2: ppo2 ?? ppo2ForMOD, water: waterType
        ) else { return 0 }
        return GasCalculations.convert(meters: modMeters, to: depthUnit)
    }

    func formattedMOD(oxygenPercent: Double) -> String {
        let mod = calculateMOD(oxygenPercent: oxygenPercent)
        return String(format: "%.0f %@", mod, depthUnit.rawValue)
    }

    /// Depth where the mix reaches `preferredDensity`, in the user's depth unit.
    func calculateDensityDepth(oxygenPercent: Double, heliumPercent: Double) -> Double? {
        GasCalculations.densityLimitDepthMeters(
            oxygenPercent: oxygenPercent, heliumPercent: heliumPercent,
            densityLimit: preferredDensity, water: waterType
        ).map { GasCalculations.convert(meters: $0, to: depthUnit) }
    }

    /// Deepest depth the mix may be used: the shallower of the MOD and the
    /// preferred-density depth, in metres. END is evaluated here.
    func endDepthMeters(oxygenPercent: Double, heliumPercent: Double) -> Double? {
        let densityDepth = GasCalculations.densityLimitDepthMeters(
            oxygenPercent: oxygenPercent, heliumPercent: heliumPercent,
            densityLimit: preferredDensity, water: waterType
        )
        let mod = GasCalculations.modMeters(oxygenPercent: oxygenPercent, ppo2: ppo2ForMOD, water: waterType)
        switch (densityDepth, mod) {
        case let (density?, mod?): return min(density, mod)
        case let (density, mod): return density ?? mod
        }
    }

    /// END at `endDepthMeters`, in the user's depth unit.
    func calculateEND(oxygenPercent: Double, heliumPercent: Double) -> Double? {
        guard let depth = endDepthMeters(oxygenPercent: oxygenPercent, heliumPercent: heliumPercent) else { return nil }
        let end = GasCalculations.endMeters(
            oxygenPercent: oxygenPercent, heliumPercent: heliumPercent,
            depthMeters: depth, water: waterType, oxygenIsNarcotic: oxygenIsNarcotic
        )
        return GasCalculations.convert(meters: end, to: depthUnit)
    }

    // Round the density depth down and END up so the label errs conservative.
    func formattedDensityDepth(oxygenPercent: Double, heliumPercent: Double) -> String {
        guard let depth = calculateDensityDepth(oxygenPercent: oxygenPercent, heliumPercent: heliumPercent) else { return "--" }
        return String(format: "%.0f %@", depth.rounded(.down), depthUnit.rawValue)
    }

    func formattedENDDepth(oxygenPercent: Double, heliumPercent: Double) -> String {
        guard let depth = endDepthMeters(oxygenPercent: oxygenPercent, heliumPercent: heliumPercent) else { return "--" }
        let converted = GasCalculations.convert(meters: depth, to: depthUnit)
        return String(format: "%.0f %@", converted.rounded(.down), depthUnit.rawValue)
    }

    func formattedEND(oxygenPercent: Double, heliumPercent: Double) -> String {
        guard let end = calculateEND(oxygenPercent: oxygenPercent, heliumPercent: heliumPercent) else { return "--" }
        return String(format: "%.0f %@", end.rounded(.up), depthUnit.rawValue)
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

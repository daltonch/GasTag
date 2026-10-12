import Foundation

/// Water the diver is in. Sets how many metres of depth add one bar of pressure.
enum WaterType: String, CaseIterable {
    case fresh = "fresh"
    case salt = "salt"

    /// Salt uses the EN 13319 / Blender Toolkit convention of exactly 10 m per bar.
    /// Fresh uses 1000 kg/m³ water: 1 bar / (1000 kg/m³ × 9.80665 m/s²) ≈ 10.197 m.
    var metersPerBar: Double {
        switch self {
        case .salt: return 10.0
        case .fresh: return 100_000.0 / (1000.0 * 9.80665)
        }
    }

    var displayName: String {
        switch self {
        case .fresh: return "Fresh"
        case .salt: return "Salt"
        }
    }
}

/// Dive gas physics: MOD, gas density and END.
///
/// Matches the Blender Toolkit (blender-toolkit.t-provider.de) so labels agree with
/// what blenders check against: surface pressure is 1.01325 bar, depth adds
/// 1 bar per `WaterType.metersPerBar`, and gas densities are the 1 ata values
/// below. All depths are in metres.
enum GasCalculations {
    static let surfacePressureBar = 1.01325
    static let feetPerMeter = 1.0 / 0.3048

    static let oxygenDensityAt1Ata = 1.429    // g/L
    static let heliumDensityAt1Ata = 0.179    // g/L
    static let nitrogenDensityAt1Ata = 1.2506 // g/L

    /// Fraction of nitrogen in air, the reference gas for END.
    static let airNitrogenFraction = 0.79

    /// Density of the mix at 1 ata, in g/L. Nitrogen is whatever is not O2 or He.
    static func surfaceDensity(oxygenPercent: Double, heliumPercent: Double) -> Double {
        let fo2 = oxygenPercent / 100.0
        let fhe = heliumPercent / 100.0
        let fn2 = max(0, 1.0 - fo2 - fhe)
        return fo2 * oxygenDensityAt1Ata + fhe * heliumDensityAt1Ata + fn2 * nitrogenDensityAt1Ata
    }

    static func absolutePressureBar(depthMeters: Double, water: WaterType) -> Double {
        depthMeters / water.metersPerBar + surfacePressureBar
    }

    static func depthMeters(absolutePressureBar: Double, water: WaterType) -> Double {
        (absolutePressureBar - surfacePressureBar) * water.metersPerBar
    }

    /// Maximum operating depth for the given ppO2 (bar). Nil without oxygen.
    static func modMeters(oxygenPercent: Double, ppo2: Double, water: WaterType) -> Double? {
        guard oxygenPercent > 0 else { return nil }
        let depth = depthMeters(absolutePressureBar: ppo2 / (oxygenPercent / 100.0), water: water)
        return max(0, depth)
    }

    /// Gas density in g/L at depth.
    static func density(oxygenPercent: Double, heliumPercent: Double, depthMeters: Double, water: WaterType) -> Double {
        let ata = absolutePressureBar(depthMeters: depthMeters, water: water) / surfacePressureBar
        return surfaceDensity(oxygenPercent: oxygenPercent, heliumPercent: heliumPercent) * ata
    }

    /// Depth at which the mix reaches `densityLimit` g/L. Clamped at 0 when the
    /// mix is already that dense at the surface.
    static func densityLimitDepthMeters(oxygenPercent: Double, heliumPercent: Double, densityLimit: Double, water: WaterType) -> Double? {
        let rho = surfaceDensity(oxygenPercent: oxygenPercent, heliumPercent: heliumPercent)
        guard rho > 0, densityLimit > 0 else { return nil }
        let depth = depthMeters(absolutePressureBar: densityLimit / rho * surfacePressureBar, water: water)
        return max(0, depth)
    }

    /// Equivalent narcotic depth at `depthMeters`. With `oxygenIsNarcotic` O2 counts
    /// as fully narcotic (GUE / modern trimix convention), so the reference is all of
    /// air; without it only nitrogen counts (the Blender Toolkit default).
    /// Clamped at 0: a mix less narcotic than air at the surface reads as surface.
    static func endMeters(oxygenPercent: Double, heliumPercent: Double, depthMeters: Double, water: WaterType, oxygenIsNarcotic: Bool) -> Double {
        let fo2 = oxygenPercent / 100.0
        let fn2 = max(0, 1.0 - fo2 - heliumPercent / 100.0)
        let narcoticFraction = oxygenIsNarcotic ? fn2 + fo2 : fn2 / airNitrogenFraction
        let surfaceMeters = surfacePressureBar * water.metersPerBar
        let end = narcoticFraction * (depthMeters + surfaceMeters) - surfaceMeters
        return max(0, end)
    }

    static func convert(meters: Double, to unit: DepthUnit) -> Double {
        switch unit {
        case .feet: return meters * feetPerMeter
        case .meters: return meters
        }
    }
}

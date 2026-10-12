import XCTest
@testable import GasTag

/// Gas physics checked against the Blender Toolkit (blender-toolkit.t-provider.de),
/// which the salt-water convention is built to match. Fresh-water values use the
/// same model with 1000 kg/m³ water.
final class GasCalculationsTests: XCTestCase {

    private let accuracy = 0.05

    private func feet(_ meters: Double?) -> Double {
        GasCalculations.convert(meters: meters ?? .nan, to: .feet)
    }

    private func densityDepthFeet(_ o2: Double, _ he: Double, _ water: WaterType, limit: Double = 5.2) -> Double {
        feet(GasCalculations.densityLimitDepthMeters(oxygenPercent: o2, heliumPercent: he, densityLimit: limit, water: water))
    }

    private func endFeet(_ o2: Double, _ he: Double, atFeet depthFeet: Double, _ water: WaterType) -> Double {
        feet(GasCalculations.endMeters(oxygenPercent: o2, heliumPercent: he, depthMeters: depthFeet * 0.3048, water: water))
    }

    // MARK: - Density limit depth (salt, toolkit values)

    func testDensityDepthSaltMatchesToolkit() {
        XCTAssertEqual(densityDepthFeet(10, 70, .salt), 300.27, accuracy: accuracy)
        XCTAssertEqual(densityDepthFeet(7, 85, .salt), 457.53, accuracy: accuracy)
        XCTAssertEqual(densityDepthFeet(12, 65, .salt), 267.15, accuracy: accuracy)
        XCTAssertEqual(densityDepthFeet(15, 55, .salt), 218.02, accuracy: accuracy)
    }

    func testDensityDepthFreshIsDeeperThanSalt() {
        XCTAssertEqual(densityDepthFeet(10, 70, .fresh), 306.19, accuracy: accuracy)
        XCTAssertEqual(densityDepthFeet(7, 85, .fresh), 466.55, accuracy: accuracy)
        XCTAssertEqual(densityDepthFeet(12, 65, .fresh), 272.41, accuracy: accuracy)
        XCTAssertEqual(densityDepthFeet(15, 55, .fresh), 222.32, accuracy: accuracy)
    }

    func testDensityAtLimitDepthRoundTrips() {
        let depth = GasCalculations.densityLimitDepthMeters(oxygenPercent: 10, heliumPercent: 70, densityLimit: 6.2, water: .fresh)!
        let density = GasCalculations.density(oxygenPercent: 10, heliumPercent: 70, depthMeters: depth, water: .fresh)
        XCTAssertEqual(density, 6.2, accuracy: 1e-9)
    }

    func testDensityDepthClampsAtSurface() {
        // Pure O2 is 1.429 g/L at the surface, already above a 1.0 g/L limit.
        XCTAssertEqual(GasCalculations.densityLimitDepthMeters(oxygenPercent: 100, heliumPercent: 0, densityLimit: 1.0, water: .salt), 0)
    }

    // MARK: - END (nitrogen only)

    func testENDAtDensityDepthSalt() {
        XCTAssertEqual(endFeet(10, 70, atFeet: 300.27, .salt), 51.19, accuracy: accuracy)
        XCTAssertEqual(endFeet(7, 85, atFeet: 457.53, .salt), 16.46, accuracy: accuracy)
        XCTAssertEqual(endFeet(12, 65, atFeet: 267.15, .salt), 54.21, accuracy: accuracy)
        XCTAssertEqual(endFeet(15, 55, atFeet: 218.02, .salt), 62.17, accuracy: accuracy)
    }

    func testENDOfAirEqualsDepth() {
        XCTAssertEqual(endFeet(21, 0, atFeet: 100, .fresh), 100, accuracy: 1e-9)
    }

    func testENDClampsAtSurface() {
        XCTAssertEqual(endFeet(7, 85, atFeet: 100, .salt), 0)
    }

    // MARK: - MOD

    func testMODSalt() {
        XCTAssertEqual(feet(GasCalculations.modMeters(oxygenPercent: 32, ppo2: 1.4, water: .salt)), 110.29, accuracy: accuracy)
        XCTAssertEqual(feet(GasCalculations.modMeters(oxygenPercent: 10, ppo2: 1.4, water: .salt)), 426.07, accuracy: accuracy)
    }

    func testMODFresh() {
        XCTAssertEqual(feet(GasCalculations.modMeters(oxygenPercent: 32, ppo2: 1.4, water: .fresh)), 112.47, accuracy: accuracy)
    }

    func testMODWithoutOxygenIsNil() {
        XCTAssertNil(GasCalculations.modMeters(oxygenPercent: 0, ppo2: 1.4, water: .salt))
    }
}

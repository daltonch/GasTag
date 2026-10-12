import XCTest
@testable import GasTag

/// Records which search path `PrinterManager` used so tests can prove the
/// default search and launch verification never open the iOS accessory picker.
final class FakePrinterSearcher: @unchecked Sendable {
    private let lock = NSLock()
    private var _paired: [DiscoveredPrinter]
    private var _pickerResult: [DiscoveredPrinter]
    private var _pairedCalls = 0
    private var _pickerCalls = 0

    init(paired: [DiscoveredPrinter] = [], pickerResult: [DiscoveredPrinter] = []) {
        _paired = paired
        _pickerResult = pickerResult
    }

    var paired: [DiscoveredPrinter] {
        get { lock.withLock { _paired } }
        set { lock.withLock { _paired = newValue } }
    }
    var pairedCalls: Int { lock.withLock { _pairedCalls } }
    var pickerCalls: Int { lock.withLock { _pickerCalls } }

    /// Stands in for `BRLMPrinterSearcher.startBluetoothSearch()`.
    func searchPaired() -> [DiscoveredPrinter] {
        lock.withLock {
            _pairedCalls += 1
            return _paired
        }
    }

    /// Stands in for `BRLMPrinterSearcher.startBluetoothAccessorySearch`.
    func showPicker() async -> [DiscoveredPrinter] {
        lock.withLock {
            _pickerCalls += 1
            // Pairing through the picker makes the accessory show up as paired.
            _paired.append(contentsOf: _pickerResult)
            return _pickerResult
        }
    }
}

/// Regression tests for the printer connection bug where a QL-820NWB already
/// paired in iOS Settings never appeared in the app. The app searched only
/// through the iOS accessory picker, which lists unpaired accessories, instead
/// of the SDK's paired-printer query.
@MainActor
final class PrinterManagerSearchTests: XCTestCase {

    private let ql820 = DiscoveredPrinter(id: "QL820-SERIAL", name: "QL-820NWB", serialNumber: "QL820-SERIAL")
    private let other = DiscoveredPrinter(id: "OTHER-SERIAL", name: "QL-1110NWB", serialNumber: "OTHER-SERIAL")

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: UserSettings!

    override func setUp() {
        super.setUp()
        suiteName = "GasTagTests.PrinterManagerSearch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        settings = UserSettings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager(_ searcher: FakePrinterSearcher) -> PrinterManager {
        PrinterManager(
            settings: settings,
            pairedPrinterSearch: { searcher.searchPaired() },
            accessoryPairingSearch: { await searcher.showPicker() }
        )
    }

    // MARK: - Default search

    func testSearchListsPairedPrintersWithoutShowingPicker() async {
        let searcher = FakePrinterSearcher(paired: [ql820])
        let manager = makeManager(searcher)

        await manager.refreshPairedPrinters()

        XCTAssertEqual(manager.discoveredPrinters, [ql820])
        XCTAssertEqual(searcher.pairedCalls, 1)
        XCTAssertEqual(searcher.pickerCalls, 0, "Default search must not open the iOS accessory picker")
        XCTAssertEqual(manager.connectionState, .disconnected)
    }

    func testRepeatedSearchDoesNotDuplicatePrinters() async {
        let searcher = FakePrinterSearcher(paired: [ql820, other])
        let manager = makeManager(searcher)

        await manager.refreshPairedPrinters()
        await manager.refreshPairedPrinters()

        XCTAssertEqual(manager.discoveredPrinters, [ql820, other])
    }

    func testSearchWithSavedPrinterMissingEndsUnavailable() async {
        settings.savePrinter(identifier: ql820.serialNumber, name: ql820.name)
        let searcher = FakePrinterSearcher(paired: [other])
        let manager = makeManager(searcher)

        await manager.refreshPairedPrinters()

        XCTAssertEqual(manager.connectionState, .unavailable)
    }

    func testSearchWithSavedPrinterPresentEndsConnected() async {
        settings.savePrinter(identifier: ql820.serialNumber, name: ql820.name)
        let searcher = FakePrinterSearcher(paired: [ql820])
        let manager = makeManager(searcher)

        await manager.refreshPairedPrinters()

        XCTAssertEqual(manager.connectionState, .connected)
    }

    // MARK: - Launch verification

    func testVerifyConnectsWhenSavedPrinterIsPaired() async {
        settings.savePrinter(identifier: ql820.serialNumber, name: ql820.name)
        let searcher = FakePrinterSearcher(paired: [ql820])
        let manager = makeManager(searcher)

        await manager.verifySavedPrinter()

        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertEqual(manager.connectedPrinterName, ql820.name)
        XCTAssertEqual(searcher.pickerCalls, 0, "Launch verification must never pop the accessory picker")
    }

    func testVerifyIsUnavailableWhenSavedPrinterIsNotPaired() async {
        settings.savePrinter(identifier: ql820.serialNumber, name: ql820.name)
        let searcher = FakePrinterSearcher(paired: [other])
        let manager = makeManager(searcher)

        await manager.verifySavedPrinter()

        XCTAssertEqual(manager.connectionState, .unavailable)
        XCTAssertEqual(manager.connectedPrinterName, ql820.name, "Saved name is kept so the UI can label it unavailable")
    }

    func testVerifyWithoutSavedPrinterIsDisconnected() async {
        let searcher = FakePrinterSearcher(paired: [ql820])
        let manager = makeManager(searcher)

        await manager.verifySavedPrinter()

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertEqual(searcher.pairedCalls, 0)
    }

    // MARK: - Explicit pairing

    func testPairNewPrinterUsesPickerThenRefreshesPairedList() async {
        let searcher = FakePrinterSearcher(paired: [], pickerResult: [ql820])
        let manager = makeManager(searcher)

        await manager.pairNewPrinter()

        XCTAssertEqual(searcher.pickerCalls, 1)
        XCTAssertEqual(manager.discoveredPrinters, [ql820])
        XCTAssertEqual(manager.connectionState, .disconnected)
    }

    // MARK: - Pure state mapping

    func testVerificationStateMapping() {
        XCTAssertEqual(PrinterManager.verificationState(found: [ql820], savedSerial: ql820.serialNumber), .connected)
        XCTAssertEqual(PrinterManager.verificationState(found: [other], savedSerial: ql820.serialNumber), .unavailable)
        XCTAssertEqual(PrinterManager.verificationState(found: [], savedSerial: ql820.serialNumber), .unavailable)
    }

    func testIdleStateMapping() {
        XCTAssertEqual(PrinterManager.idleState(hasSavedPrinter: true), .unavailable)
        XCTAssertEqual(PrinterManager.idleState(hasSavedPrinter: false), .disconnected)
    }
}

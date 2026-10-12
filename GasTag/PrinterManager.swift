import Foundation
import SwiftUI
import BRLMPrinterKit

enum PrinterConnectionState: String {
    case disconnected = "Disconnected"
    case searching = "Searching"
    case connecting = "Connecting"
    case connected = "Connected"
    case unavailable = "Unavailable"
    case printing = "Printing"
    case error = "Error"
}

struct DiscoveredPrinter: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let serialNumber: String
}

extension DiscoveredPrinter {
    /// Builds an entry from an SDK channel. For MFi (Bluetooth Classic) printers
    /// `channelInfo` is the External Accessory serial number, which is what
    /// `BRLMChannel(bluetoothSerialNumber:)` needs to open the printer later.
    init(channel: BRLMChannel) {
        let serial = channel.channelInfo
        let model = channel.extraInfo?[BRLMChannelExtraInfoKeyModelName] as? String
        self.init(id: serial, name: model ?? "Brother Printer", serialNumber: serial)
    }
}

@MainActor
class PrinterManager: ObservableObject {
    /// Returns the Brother printers already paired with this iPhone. Shows no UI
    /// and may block briefly, so it is always run off the main thread.
    typealias PairedPrinterSearch = @Sendable () -> [DiscoveredPrinter]

    /// Presents the iOS "Select An Accessory" picker so the user can pair a new
    /// printer, and returns whatever they picked (empty on cancel).
    typealias AccessoryPairingSearch = @MainActor () async -> [DiscoveredPrinter]

    static let shared = PrinterManager()

    @Published var connectionState: PrinterConnectionState = .disconnected
    @Published var discoveredPrinters: [DiscoveredPrinter] = []
    @Published var errorMessage: String?
    @Published var connectedPrinterName: String?

    private var currentSerialNumber: String?
    private let settings: UserSettings
    private let pairedPrinterSearch: PairedPrinterSearch
    private let accessoryPairingSearch: AccessoryPairingSearch

    init(settings: UserSettings = .shared,
         pairedPrinterSearch: @escaping PairedPrinterSearch = PrinterManager.sdkPairedPrinterSearch,
         accessoryPairingSearch: @escaping AccessoryPairingSearch = PrinterManager.sdkAccessoryPairingSearch) {
        self.settings = settings
        self.pairedPrinterSearch = pairedPrinterSearch
        self.accessoryPairingSearch = accessoryPairingSearch

        if settings.hasSavedPrinter {
            connectedPrinterName = settings.printerName
            currentSerialNumber = settings.printerIdentifier
            // Don't set .connected - verifyConnection() proves it on app launch
        }
    }

    // MARK: - SDK search adapters

    /// Lists MFi printers that already show as paired in iOS Settings > Bluetooth.
    /// This is the search Brother's discovery guide uses for Bluetooth printers.
    nonisolated static let sdkPairedPrinterSearch: PairedPrinterSearch = {
        BRLMPrinterSearcher.startBluetoothSearch().channels.map(DiscoveredPrinter.init(channel:))
    }

    /// Presents the iOS accessory picker. The picker only lists accessories that
    /// are NOT yet paired, so a printer already "Connected" in Settings never
    /// appears in it. It exists only for the explicit "Pair New Printer" path.
    nonisolated static let sdkAccessoryPairingSearch: AccessoryPairingSearch = {
        await withCheckedContinuation { continuation in
            BRLMPrinterSearcher.startBluetoothAccessorySearch { result in
                continuation.resume(returning: result.channels.map(DiscoveredPrinter.init(channel:)))
            }
        }
    }

    // MARK: - Pure state mapping

    /// State to show once a search finishes and a printer is saved.
    nonisolated static func verificationState(found: [DiscoveredPrinter], savedSerial: String) -> PrinterConnectionState {
        found.contains { $0.serialNumber == savedSerial } ? .connected : .unavailable
    }

    /// State to fall back to when a search is stopped before it reports.
    nonisolated static func idleState(hasSavedPrinter: Bool) -> PrinterConnectionState {
        hasSavedPrinter ? .unavailable : .disconnected
    }

    nonisolated static func endOfSearchState(found: [DiscoveredPrinter], savedSerial: String?) -> PrinterConnectionState {
        guard let savedSerial else { return .disconnected }
        return verificationState(found: found, savedSerial: savedSerial)
    }

    nonisolated static func merge(_ existing: [DiscoveredPrinter], with found: [DiscoveredPrinter]) -> [DiscoveredPrinter] {
        var merged = existing
        for printer in found where !merged.contains(where: { $0.id == printer.id }) {
            merged.append(printer)
        }
        return merged
    }

    // MARK: - Discovery

    /// Fire-and-forget entry point for SwiftUI. See `refreshPairedPrinters()`.
    func startSearching() {
        Task { await refreshPairedPrinters() }
    }

    /// Replaces `discoveredPrinters` with the printers already paired with this
    /// iPhone. Shows no system UI.
    func refreshPairedPrinters() async {
        connectionState = .searching
        errorMessage = nil

        let search = pairedPrinterSearch
        let found = await Task.detached(priority: .userInitiated) { search() }.value

        discoveredPrinters = Self.merge([], with: found)

        // The user may have tapped Stop while the search ran.
        guard connectionState == .searching else { return }
        connectionState = Self.endOfSearchState(found: found, savedSerial: settings.printerIdentifier)
    }

    /// Fire-and-forget entry point for SwiftUI. See `pairNewPrinter()`.
    func startPairingNewPrinter() {
        Task { await pairNewPrinter() }
    }

    /// Opens the iOS accessory picker to pair a printer that is not yet paired,
    /// then re-lists paired printers so the new one shows up.
    func pairNewPrinter() async {
        connectionState = .searching
        errorMessage = nil

        let picked = await accessoryPairingSearch()

        // Always re-list after the picker: the user's pick must not be dropped
        // just because something else touched the state while the picker was up.
        await refreshPairedPrinters()
        // Keep what the user just picked visible even if the pairing is still settling.
        discoveredPrinters = Self.merge(discoveredPrinters, with: picked)
    }

    func stopSearching() {
        if connectionState == .searching {
            connectionState = Self.idleState(hasSavedPrinter: settings.hasSavedPrinter)
        }
    }

    // MARK: - Connection

    func connect(to printer: DiscoveredPrinter) {
        connectionState = .connecting
        currentSerialNumber = printer.serialNumber

        settings.savePrinter(identifier: printer.serialNumber, name: printer.name)

        // Test the connection by opening and closing channel — run blocking SDK call off main thread
        let serialNumber = printer.serialNumber
        let printerName = printer.name
        Task.detached { [weak self] in
            let channel = BRLMChannel(bluetoothSerialNumber: serialNumber)
            let result = BRLMPrinterDriverGenerator.open(channel)

            // Resolve the connection outcome off-main, then hop back via an optional-chained
            // @MainActor helper so we never reference the weak `self` var in concurrent code.
            if let driver = result.driver {
                driver.closeChannel()
                await self?.applyConnectSuccess(printerName: printerName)
            } else {
                let errorCode = result.error.code
                await self?.applyConnectFailure(message: "Connection failed: \(errorCode)")
            }
        }
    }

    @MainActor
    private func applyConnectSuccess(printerName: String) {
        connectedPrinterName = printerName
        connectionState = .connected
        errorMessage = nil
    }

    @MainActor
    private func applyConnectFailure(message: String) {
        errorMessage = message
        connectionState = .error
    }

    func disconnect() {
        currentSerialNumber = nil
        connectedPrinterName = nil
        connectionState = .disconnected
        settings.forgetPrinter()
    }

    func clearError() {
        errorMessage = nil
        // Re-verify connection instead of assuming connected
        if settings.hasSavedPrinter {
            verifyConnection()
        } else {
            connectionState = .disconnected
        }
    }

    // MARK: - Printing

    func printLabel(image: UIImage) async -> Bool {
        guard let serialNumber = currentSerialNumber ?? settings.printerIdentifier else {
            self.errorMessage = "No printer connected"
            return false
        }

        self.connectionState = .printing

        // Capture the CGImage on the main actor before hopping off-thread.
        // UIImage.cgImage is safe to access here (we're still on MainActor).
        guard let cgImage = image.cgImage else {
            self.errorMessage = "Failed to get image data"
            self.connectionState = .error
            return false
        }

        // Run all blocking Brother SDK calls on a background thread so the main
        // thread / UI is never blocked.  Only plain value types cross the boundary.
        enum PrintResult {
            case success
            case openStreamFailure
            case timeout
            case openError(String)
            case settingsError
            case wrongMedia
            case printError(String)
        }

        let result: PrintResult = await Task.detached(priority: .userInitiated) {
            let channel = BRLMChannel(bluetoothSerialNumber: serialNumber)
            let openResult = BRLMPrinterDriverGenerator.open(channel)

            guard let driver = openResult.driver else {
                let errorCode = openResult.error.code
                switch errorCode {
                case .openStreamFailure:
                    return PrintResult.openStreamFailure
                case .timeout:
                    return PrintResult.timeout
                default:
                    return PrintResult.openError("\(errorCode)")
                }
            }

            defer { driver.closeChannel() }

            // Configure print settings for QL-820NWB
            guard let printSettings = BRLMQLPrintSettings(defaultPrintSettingsWith: .QL_820NWB) else {
                return PrintResult.settingsError
            }

            // Auto-detect the loaded media from the printer
            let statusResult = driver.getPrinterStatus()
            var detectedSize: BRLMQLPrintSettingsLabelSize = .rollW62

            if let status = statusResult.status,
               let mediaInfo = status.mediaInfo {
                var succeeded = false
                let size = mediaInfo.getQLLabelSize(&succeeded)
                if succeeded {
                    detectedSize = size
                }
            }

            // Validate that a 62mm roll is loaded (label layout is designed for 62mm width)
            let valid62mmSizes: [BRLMQLPrintSettingsLabelSize] = [.rollW62, .rollW62RB]
            guard valid62mmSizes.contains(detectedSize) else {
                return PrintResult.wrongMedia
            }

            printSettings.labelSize = detectedSize
            printSettings.autoCut = true

            let printError = driver.printImage(with: cgImage, settings: printSettings)

            if printError.code == .noError {
                return PrintResult.success
            } else {
                return PrintResult.printError(printError.errorDescription)
            }
        }.value

        // Back on MainActor — update @Published state based on the result.
        switch result {
        case .success:
            self.connectionState = .connected
            self.errorMessage = nil
            return true
        case .openStreamFailure:
            self.errorMessage = "Cannot connect to printer. Try: turn printer off/on, or forget & reconnect in Settings"
            self.connectionState = .error
            return false
        case .timeout:
            self.errorMessage = "Printer connection timed out. Make sure printer is on and nearby"
            self.connectionState = .error
            return false
        case .openError(let code):
            self.errorMessage = "Failed to open printer: \(code)"
            self.connectionState = .error
            return false
        case .settingsError:
            self.errorMessage = "Failed to create print settings"
            self.connectionState = .error
            return false
        case .wrongMedia:
            self.errorMessage = "Please load a 62mm continuous roll (DK-2205 or DK-2251)"
            self.connectionState = .error
            return false
        case .printError(let desc):
            self.errorMessage = "Print failed: \(desc)"
            self.connectionState = .error
            return false
        }
    }

    // MARK: - Connection Verification

    /// Fire-and-forget entry point for SwiftUI. See `verifySavedPrinter()`.
    func verifyConnection() {
        Task { await verifySavedPrinter() }
    }

    /// Checks whether the saved printer is still paired with this iPhone and
    /// sets `.connected` or `.unavailable`. Shows no system UI, so it is safe
    /// to call on every app launch.
    func verifySavedPrinter() async {
        guard settings.hasSavedPrinter,
              let serialNumber = settings.printerIdentifier else {
            connectionState = .disconnected
            return
        }

        connectionState = .searching
        connectedPrinterName = settings.printerName
        currentSerialNumber = serialNumber

        let search = pairedPrinterSearch
        let found = await Task.detached(priority: .userInitiated) { search() }.value

        // Only update state if we're still searching (user may have stopped or reconnected)
        guard connectionState == .searching else { return }
        connectionState = Self.verificationState(found: found, savedSerial: serialNumber)
    }
}

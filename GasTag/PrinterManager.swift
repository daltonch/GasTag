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

struct DiscoveredPrinter: Identifiable {
    let id: String
    let name: String
    let serialNumber: String
}

@MainActor
class PrinterManager: ObservableObject {
    static let shared = PrinterManager()

    @Published var connectionState: PrinterConnectionState = .disconnected
    @Published var discoveredPrinters: [DiscoveredPrinter] = []
    @Published var errorMessage: String?
    @Published var connectedPrinterName: String?

    private var currentSerialNumber: String?
    private let settings = UserSettings.shared

    init() {
        if settings.hasSavedPrinter {
            connectedPrinterName = settings.printerName
            currentSerialNumber = settings.printerIdentifier
            // Don't set .connected - will be verified on app launch
        }
    }

    // MARK: - Discovery

    func startSearching() {
        connectionState = .searching
        discoveredPrinters = []
        errorMessage = nil

        // Use MFi Bluetooth search for Brother printers
        BRLMPrinterSearcher.startBluetoothAccessorySearch { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }

                for channel in result.channels {
                        let name = channel.extraInfo?[BRLMChannelExtraInfoKeyModelName] as? String
                            ?? "Brother Printer"
                        let serialNumber = channel.channelInfo

                        let printer = DiscoveredPrinter(
                            id: serialNumber,
                            name: name,
                            serialNumber: serialNumber
                        )

                    if !self.discoveredPrinters.contains(where: { $0.id == printer.id }) {
                        self.discoveredPrinters.append(printer)
                    }
                }

                if self.connectionState == .searching {
                    // If saved printer not found during search, mark as unavailable
                    self.connectionState = self.settings.hasSavedPrinter ? .unavailable : .disconnected
                }
            }
        }
    }

    func stopSearching() {
        if connectionState == .searching {
            // If we have a saved printer but stopped searching, mark as unavailable
            connectionState = settings.hasSavedPrinter ? .unavailable : .disconnected
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

    // MARK: - Reconnect

    func reconnectIfNeeded() {
        guard settings.hasSavedPrinter,
              currentSerialNumber == nil else { return }

        currentSerialNumber = settings.printerIdentifier
        connectedPrinterName = settings.printerName
        connectionState = .connected
    }

    // MARK: - Connection Verification

    func verifyConnection() {
        guard settings.hasSavedPrinter,
              let serialNumber = settings.printerIdentifier else {
            connectionState = .disconnected
            return
        }

        // Set searching state while we look for the printer
        connectionState = .searching
        connectedPrinterName = settings.printerName
        currentSerialNumber = serialNumber

        // Scan for the saved printer
        BRLMPrinterSearcher.startBluetoothAccessorySearch { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }

                // Only update state if we're still searching (not timed out)
                guard self.connectionState == .searching else { return }

                // Check if our saved printer is in the results
                let foundPrinter = result.channels.contains { channel in
                    channel.channelInfo == serialNumber
                }

                if foundPrinter {
                    self.connectionState = .connected
                } else {
                    self.connectionState = .unavailable
                }
            }
        }

        // Timeout after 5 seconds if no response
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if self.connectionState == .searching {
                    self.connectionState = .unavailable
                }
            }
        }
    }
}

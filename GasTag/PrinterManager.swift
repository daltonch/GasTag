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

        // Prove the connection with a real (retrying, serialized) open/close.
        let targetSerial = printer.serialNumber
        Task {
            let failureMessage = await probeConnection(serialNumber: targetSerial)
            // The user may have disconnected or picked another printer while
            // the probe ran; only apply the result if it's still current.
            guard currentSerialNumber == targetSerial else { return }
            if failureMessage == nil {
                connectedPrinterName = printer.name
                connectionState = .connected
                errorMessage = nil
            } else {
                errorMessage = failureMessage
                connectionState = .error
            }
        }
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
            errorMessage = "No printer connected"
            return false
        }

        guard let cgImage = image.cgImage else {
            errorMessage = "Failed to get image data"
            connectionState = .error
            return false
        }

        connectionState = .printing

        do {
            // The executor serializes this whole open/print/close cycle and
            // retries the open, so back-to-back prints (main + mix label) no
            // longer race a still-tearing-down channel.
            let outcome = try await PrinterChannelExecutor.shared.withOpenChannel(serialNumber: serialNumber) { driver in
                Self.performPrint(driver: driver, cgImage: cgImage)
            }

            switch outcome {
            case .success:
                connectionState = .connected
                errorMessage = nil
                return true
            case .settingsFailure:
                errorMessage = "Failed to create print settings"
                connectionState = .error
                return false
            case .wrongMedia:
                errorMessage = "Please load a 62mm continuous roll (DK-2205 or DK-2251)"
                connectionState = .error
                return false
            case .printFailed(let description):
                errorMessage = "Print failed: \(description)"
                connectionState = .error
                return false
            }
        } catch {
            errorMessage = Self.openErrorMessage(for: error)
            connectionState = .error
            return false
        }
    }

    /// Runs on the channel executor's background queue with a live driver.
    /// Detects the loaded media, validates it, and prints. Pure SDK work, no
    /// main-actor state.
    private nonisolated static func performPrint(driver: BRLMPrinterDriver, cgImage: CGImage) -> PrintOutcome {
        // Configure print settings for QL-820NWB
        guard let printSettings = BRLMQLPrintSettings(defaultPrintSettingsWith: .QL_820NWB) else {
            return .settingsFailure
        }

        // Auto-detect the loaded media from the printer
        var detectedSize: BRLMQLPrintSettingsLabelSize = .rollW62
        let statusResult = driver.getPrinterStatus()
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
            return .wrongMedia
        }

        printSettings.labelSize = detectedSize
        printSettings.autoCut = true

        let printError = driver.printImage(with: cgImage, settings: printSettings)
        if printError.code == .noError {
            return .success
        } else {
            return .printFailed(printError.errorDescription)
        }
    }

    // MARK: - Reconnect

    func reconnectIfNeeded() {
        guard settings.hasSavedPrinter,
              currentSerialNumber == nil else { return }

        // Don't assume connected; prove it with a real open/close.
        verifyConnection()
    }

    // MARK: - Connection Verification

    func verifyConnection() {
        guard settings.hasSavedPrinter,
              let serialNumber = settings.printerIdentifier else {
            connectionState = .disconnected
            return
        }

        connectionState = .connecting
        connectedPrinterName = settings.printerName
        currentSerialNumber = serialNumber

        // A real open/close is the only honest proof of connectivity. A
        // Bluetooth scan only tells us the accessory is paired, not that a
        // channel can actually be opened for printing.
        Task {
            let failureMessage = await probeConnection(serialNumber: serialNumber)
            // Ignore a result that no longer matches the current target.
            guard currentSerialNumber == serialNumber else { return }
            if failureMessage == nil {
                connectionState = .connected
                errorMessage = nil
            } else {
                // Unavailable is an expected condition (printer off / out of
                // range), not an error, so don't surface the error banner.
                errorMessage = nil
                connectionState = .unavailable
            }
        }
    }

    // MARK: - Helpers

    /// Attempts a real (retrying, serialized) open/close. Returns `nil` on
    /// success, or a user-facing error message on failure. The caller decides
    /// whether that failure is an error or simply "unavailable", so this does
    /// not mutate `errorMessage` itself.
    private func probeConnection(serialNumber: String) async -> String? {
        do {
            try await PrinterChannelExecutor.shared.withOpenChannel(serialNumber: serialNumber) { _ in }
            return nil
        } catch {
            return Self.openErrorMessage(for: error)
        }
    }

    private static func openErrorMessage(for error: Error) -> String {
        guard case PrinterChannelError.openFailed(let code) = error else {
            return "Failed to connect to printer"
        }
        switch code {
        case .openStreamFailure:
            return "Cannot connect to printer. Try: turn printer off/on, or forget & reconnect in Settings"
        case .timeout:
            return "Printer connection timed out. Make sure printer is on and nearby"
        default:
            return "Failed to open printer (code \(code.rawValue)). Restart the printer and try again."
        }
    }
}

/// Outcome of a single print attempt performed on the channel executor queue.
private enum PrintOutcome: Sendable {
    case success
    case settingsFailure
    case wrongMedia
    case printFailed(String)
}

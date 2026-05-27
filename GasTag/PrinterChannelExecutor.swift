import Foundation
import os
import BRLMPrinterKit

/// Errors surfaced while trying to open a Brother print channel.
enum PrinterChannelError: Error {
    /// The channel failed to open on every attempt. Carries the last SDK code.
    case openFailed(BRLMOpenChannelErrorCode)
}

/// Serializes every Brother channel operation onto a single dedicated queue.
///
/// MFi (External Accessory) printers such as the QL-820NWB allow only one
/// `EASession` at a time, and the underlying streams tear down asynchronously
/// after `closeChannel()`. Running opens concurrently, or reopening before the
/// previous session has finished tearing down, wedges the accessory until the
/// app is relaunched. This executor guarantees:
///
///   1. Only one open/operate/close cycle runs at a time (serial queue).
///   2. A short settle delay after each close before the next op may open.
///   3. A bounded retry on open, since the first open after the printer has
///      been idle frequently fails with openStreamFailure/timeout and then
///      succeeds moments later.
final class PrinterChannelExecutor: Sendable {
    static let shared = PrinterChannelExecutor()

    private static let log = Logger(subsystem: "com.daltonch.GasTag", category: "printer")

    private let queue = DispatchQueue(label: "com.daltonch.GasTag.printer-channel")
    private let maxAttempts: Int
    private let retryDelay: TimeInterval
    private let settleDelay: TimeInterval

    private init(maxAttempts: Int = 3,
                 retryDelay: TimeInterval = 0.4,
                 settleDelay: TimeInterval = 0.25) {
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelay = retryDelay
        self.settleDelay = settleDelay
    }

    /// Opens a channel to `serialNumber`, runs `operation` with the live driver,
    /// then closes the channel and waits out the settle delay. Only the open is
    /// retried (up to `maxAttempts`), never the operation itself.
    ///
    /// `operation` runs on a background serial queue and MUST NOT touch
    /// main-actor or `@Published` state. It must also not trap or let an
    /// Objective-C exception escape: either would skip `continuation.resume`
    /// and permanently suspend the awaiting task.
    func withOpenChannel<T: Sendable>(
        serialNumber: String,
        operation: @escaping @Sendable (BRLMPrinterDriver) -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.resume(throwing: PrinterChannelError.openFailed(.openStreamFailure))
                    return
                }

                var lastError: BRLMOpenChannelErrorCode = .openStreamFailure

                for attempt in 1...self.maxAttempts {
                    let channel = BRLMChannel(bluetoothSerialNumber: serialNumber)
                    let result = BRLMPrinterDriverGenerator.open(channel)

                    if let driver = result.driver {
                        Self.log.info("Channel opened on attempt \(attempt, privacy: .public)")
                        let value = operation(driver)
                        driver.closeChannel()
                        // Let the EA streams finish tearing down before the next
                        // queued operation is allowed to open a fresh channel.
                        Thread.sleep(forTimeInterval: self.settleDelay)
                        continuation.resume(returning: value)
                        return
                    }

                    lastError = result.error.code
                    Self.log.warning("Channel open attempt \(attempt, privacy: .public) failed: \(lastError.rawValue, privacy: .public)")
                    if attempt < self.maxAttempts {
                        Thread.sleep(forTimeInterval: self.retryDelay)
                    }
                }

                Self.log.error("Channel open exhausted \(self.maxAttempts, privacy: .public) attempts; last error \(lastError.rawValue, privacy: .public)")
                continuation.resume(throwing: PrinterChannelError.openFailed(lastError))
            }
        }
    }
}

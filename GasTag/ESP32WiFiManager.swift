import Foundation
import NetworkExtension

/// Manages connection to ESP32's WiFi SoftAP for OTA updates
class ESP32WiFiManager {
    // ESP32 WiFi AP configuration (must match ESP32 firmware)
    static let ssid = "GasTag-Update"
    static let password = "gastag123"
    static let deviceIP = "192.168.4.1"
    static let updateEndpoint = "http://192.168.4.1/update"

    // MARK: - Public Methods

    /// Join the ESP32's WiFi access point
    /// - Returns: true if connection was initiated successfully
    func joinESP32WiFi() async throws {
        let configuration = NEHotspotConfiguration(
            ssid: ESP32WiFiManager.ssid,
            passphrase: ESP32WiFiManager.password,
            isWEP: false
        )

        // Don't persist this network
        configuration.joinOnce = true

        return try await withCheckedThrowingContinuation { continuation in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error = error as NSError? {
                    // Check if already connected to this network
                    if error.domain == NEHotspotConfigurationErrorDomain {
                        switch error.code {
                        case NEHotspotConfigurationError.alreadyAssociated.rawValue:
                            // Already connected - this is success
                            continuation.resume()
                            return
                        case NEHotspotConfigurationError.userDenied.rawValue:
                            continuation.resume(throwing: WiFiError.userDenied)
                            return
                        case NEHotspotConfigurationError.invalid.rawValue:
                            continuation.resume(throwing: WiFiError.invalidConfiguration)
                            return
                        case NEHotspotConfigurationError.invalidSSID.rawValue:
                            continuation.resume(throwing: WiFiError.invalidSSID)
                            return
                        case NEHotspotConfigurationError.invalidWPAPassphrase.rawValue:
                            continuation.resume(throwing: WiFiError.invalidPassword)
                            return
                        case NEHotspotConfigurationError.systemConfiguration.rawValue:
                            continuation.resume(throwing: WiFiError.systemError)
                            return
                        default:
                            break
                        }
                    }
                    continuation.resume(throwing: WiFiError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Remove the ESP32 WiFi configuration (disconnect)
    func removeESP32WiFiConfiguration() {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ESP32WiFiManager.ssid)
    }

    /// Check if currently connected to the ESP32 WiFi
    /// Note: This uses a network reachability check to the ESP32's IP
    func isConnectedToESP32() async -> Bool {
        // Try to reach the ESP32's status page
        guard let url = URL(string: "http://\(ESP32WiFiManager.deviceIP)/") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Connection failed - not connected to ESP32
        }

        return false
    }

    // MARK: - Firmware Upload

    /// Upload firmware to ESP32 via HTTP POST
    /// - Parameters:
    ///   - firmwareUrl: Local file URL of the firmware binary
    ///   - progressHandler: Called with upload progress (0.0 to 1.0)
    /// - Returns: true if upload was successful
    func uploadFirmware(from firmwareUrl: URL, progressHandler: @escaping (Double) -> Void) async throws {
        guard let uploadUrl = URL(string: ESP32WiFiManager.updateEndpoint) else {
            throw WiFiError.invalidConfiguration
        }

        // Read firmware data
        let firmwareData = try Data(contentsOf: firmwareUrl)

        // Create upload request
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(firmwareData.count)", forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 120  // 2 minutes for upload

        // Use upload task with delegate for progress
        let delegate = UploadProgressDelegate(totalSize: firmwareData.count, progressHandler: progressHandler)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let (data, response) = try await session.upload(for: request, from: firmwareData)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WiFiError.uploadFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            // Parse response
            if let responseStr = String(data: data, encoding: .utf8) {
                if responseStr.contains("success") {
                    return  // Success!
                }
            }
            return  // Assume success if 200
        case 400:
            throw WiFiError.uploadFailed("Invalid firmware file")
        case 500:
            throw WiFiError.uploadFailed("Device error during update")
        default:
            throw WiFiError.uploadFailed("HTTP \(httpResponse.statusCode)")
        }
    }
}

// MARK: - Upload Progress Delegate

private class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let totalSize: Int
    let progressHandler: (Double) -> Void

    init(totalSize: Int, progressHandler: @escaping (Double) -> Void) {
        self.totalSize = totalSize
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalSize)
        DispatchQueue.main.async {
            self.progressHandler(min(progress, 1.0))
        }
    }
}

// MARK: - Errors

enum WiFiError: LocalizedError {
    case userDenied
    case invalidConfiguration
    case invalidSSID
    case invalidPassword
    case systemError
    case connectionFailed(String)
    case notConnected
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .userDenied:
            return "WiFi connection was denied. Please allow GasTag to connect to WiFi networks."
        case .invalidConfiguration:
            return "Invalid WiFi configuration"
        case .invalidSSID:
            return "Invalid network name"
        case .invalidPassword:
            return "Invalid WiFi password"
        case .systemError:
            return "System WiFi error. Please check WiFi settings."
        case .connectionFailed(let message):
            return "WiFi connection failed: \(message)"
        case .notConnected:
            return "Not connected to ESP32 WiFi network"
        case .uploadFailed(let message):
            return "Firmware upload failed: \(message)"
        }
    }
}

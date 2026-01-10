import Foundation
import Combine

// MARK: - Update State

enum FirmwareUpdateState: Equatable {
    case idle
    case checkingGitHub
    case updateAvailable(version: String)
    case downloading(progress: Double)
    case downloaded
    case preparingDevice        // Sending BLE command to enter OTA mode
    case waitingForWiFi         // Waiting for user to join ESP32 WiFi AP
    case uploading(progress: Double)
    case complete
    case error(message: String)

    var isInProgress: Bool {
        switch self {
        case .checkingGitHub, .downloading, .preparingDevice, .waitingForWiFi, .uploading:
            return true
        default:
            return false
        }
    }

    static func == (lhs: FirmwareUpdateState, rhs: FirmwareUpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.checkingGitHub, .checkingGitHub),
             (.downloaded, .downloaded),
             (.preparingDevice, .preparingDevice),
             (.waitingForWiFi, .waitingForWiFi),
             (.complete, .complete):
            return true
        case (.updateAvailable(let v1), .updateAvailable(let v2)):
            return v1 == v2
        case (.downloading(let p1), .downloading(let p2)):
            return p1 == p2
        case (.uploading(let p1), .uploading(let p2)):
            return p1 == p2
        case (.error(let m1), .error(let m2)):
            return m1 == m2
        default:
            return false
        }
    }
}

// MARK: - Firmware Update Manager

@MainActor
class FirmwareUpdateManager: ObservableObject {
    // MARK: - Published Properties

    @Published var state: FirmwareUpdateState = .idle
    @Published var currentVersion: String?
    @Published var latestVersion: String?
    @Published var latestRelease: GitHubRelease?
    @Published var downloadedFirmwareUrl: URL?

    // MARK: - Dependencies

    private let githubService: GitHubReleaseService
    private let bluetoothManager: BluetoothManager
    private let wifiManager: ESP32WiFiManager

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(bluetoothManager: BluetoothManager, githubService: GitHubReleaseService? = nil, wifiManager: ESP32WiFiManager? = nil) {
        self.bluetoothManager = bluetoothManager
        self.githubService = githubService ?? GitHubReleaseService()
        self.wifiManager = wifiManager ?? ESP32WiFiManager()

        setupBindings()
    }

    private func setupBindings() {
        // Observe firmware version from Bluetooth
        bluetoothManager.$firmwareVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                self?.currentVersion = version
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    /// Check GitHub for available firmware updates
    func checkForUpdates() async {
        guard !state.isInProgress else { return }

        state = .checkingGitHub

        do {
            guard let release = try await githubService.fetchLatestRelease() else {
                state = .idle
                return
            }

            latestRelease = release
            latestVersion = release.version

            // Check if update is available
            if let current = currentVersion,
               GitHubReleaseService.isUpdateAvailable(currentVersion: current, latestVersion: release.version) {
                state = .updateAvailable(version: release.version)
            } else if currentVersion == nil {
                // No current version known (not connected), show as available anyway
                state = .updateAvailable(version: release.version)
            } else {
                // Already up to date
                state = .idle
            }
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    /// Download the firmware binary from GitHub
    func downloadFirmware() async {
        guard let release = latestRelease else {
            state = .error(message: "No release available to download")
            return
        }

        // Find firmware binary asset
        guard let asset = release.assets.first(where: { $0.isFirmwareBinary }) else {
            state = .error(message: "No firmware binary found in release")
            return
        }

        state = .downloading(progress: 0)

        do {
            let url = try await githubService.downloadAsset(asset) { [weak self] progress in
                Task { @MainActor in
                    self?.state = .downloading(progress: progress)
                }
            }

            downloadedFirmwareUrl = url
            state = .downloaded
        } catch {
            state = .error(message: "Download failed: \(error.localizedDescription)")
        }
    }

    /// Prepare the ESP32 device for OTA update by sending BLE command
    func prepareDeviceForUpdate() async {
        guard downloadedFirmwareUrl != nil else {
            state = .error(message: "No firmware downloaded")
            return
        }

        state = .preparingDevice

        // Send OTA mode command via BLE
        let success = await bluetoothManager.enterOTAMode()

        if success {
            // Device will disconnect from BLE and start WiFi AP
            state = .waitingForWiFi
        } else {
            state = .error(message: "Failed to put device in update mode")
        }
    }

    /// Join the ESP32's WiFi access point
    func joinESP32WiFi() async {
        guard state == .waitingForWiFi else {
            state = .error(message: "Device not ready for WiFi connection")
            return
        }

        do {
            try await wifiManager.joinESP32WiFi()

            // Give the WiFi connection a moment to stabilize
            try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

            // Verify we can reach the ESP32
            let connected = await wifiManager.isConnectedToESP32()
            if connected {
                // Proceed to upload
                await uploadFirmware()
            } else {
                state = .error(message: "Connected to WiFi but cannot reach ESP32. Please try again.")
            }
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    /// Upload firmware to the ESP32
    func uploadFirmware() async {
        guard let firmwareUrl = downloadedFirmwareUrl else {
            state = .error(message: "No firmware file to upload")
            return
        }

        state = .uploading(progress: 0)

        do {
            try await wifiManager.uploadFirmware(from: firmwareUrl) { [weak self] progress in
                Task { @MainActor in
                    self?.state = .uploading(progress: progress)
                }
            }

            // Upload successful - device will reboot
            state = .complete

            // Clean up
            wifiManager.removeESP32WiFiConfiguration()
            try? FileManager.default.removeItem(at: firmwareUrl)
            downloadedFirmwareUrl = nil
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    /// Perform the full update flow: download -> prepare device -> join WiFi -> upload
    func performFullUpdate() async {
        // Download firmware if not already downloaded
        if downloadedFirmwareUrl == nil {
            await downloadFirmware()
            guard state == .downloaded else { return }
        }

        // Prepare device for OTA
        await prepareDeviceForUpdate()
        guard state == .waitingForWiFi else { return }

        // Wait a moment for ESP32 to start WiFi AP
        try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds

        // Join WiFi and upload
        await joinESP32WiFi()
    }

    /// Reset state to idle
    func reset() {
        state = .idle
        latestRelease = nil
        latestVersion = nil

        // Clean up downloaded file
        if let url = downloadedFirmwareUrl {
            try? FileManager.default.removeItem(at: url)
            downloadedFirmwareUrl = nil
        }
    }

    /// Cancel any in-progress operation
    func cancel() {
        // Clean up downloaded file if any
        if let url = downloadedFirmwareUrl {
            try? FileManager.default.removeItem(at: url)
            downloadedFirmwareUrl = nil
        }

        state = .idle
    }
}

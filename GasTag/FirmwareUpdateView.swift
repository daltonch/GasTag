import SwiftUI

struct FirmwareUpdateView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var updateManager: FirmwareUpdateManager
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Version info
                versionSection

                Spacer()

                // State-dependent content
                stateContent

                Spacer()

                // Action buttons
                actionButtons
            }
            .padding()
            .navigationTitle("Firmware Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Version Section

    private var versionSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Current Version")
                    .foregroundColor(.secondary)
                Spacer()
                Text(updateManager.currentVersion ?? "Unknown")
                    .fontWeight(.medium)
            }

            if let latest = updateManager.latestVersion {
                HStack {
                    Text("Latest Version")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(latest)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - State Content

    @ViewBuilder
    private var stateContent: some View {
        switch updateManager.state {
        case .idle:
            idleContent

        case .checkingGitHub:
            ProgressView("Checking for updates...")

        case .updateAvailable(let version):
            updateAvailableContent(version: version)

        case .downloading(let progress):
            progressContent(title: "Downloading firmware...", progress: progress)

        case .downloaded:
            downloadedContent

        case .preparingDevice:
            ProgressView("Preparing device for update...")

        case .waitingForWiFi:
            wifiInstructionsContent

        case .connectingToWiFi:
            connectingToWiFiContent

        case .uploading(let progress):
            progressContent(title: "Uploading firmware...", progress: progress)

        case .complete:
            completeContent

        case .error(let message):
            errorContent(message: message)
        }
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("Firmware is up to date")
                .font(.headline)
        }
    }

    private func updateAvailableContent(version: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("Update Available")
                .font(.headline)
            Text("Version \(version) is ready to install")
                .foregroundColor(.secondary)

            if let release = updateManager.latestRelease, let body = release.body, !body.isEmpty {
                ScrollView {
                    Text(body)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding()
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    private func progressContent(title: String, progress: Double) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            ProgressView(value: progress)
                .progressViewStyle(.linear)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var downloadedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("Firmware Downloaded")
                .font(.headline)
            Text("Ready to install on device")
                .foregroundColor(.secondary)
        }
    }

    private var wifiInstructionsContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text("Connect to Device WiFi")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("The device has started a WiFi network:")
                    .foregroundColor(.secondary)
                HStack {
                    Text("Network:")
                    Spacer()
                    Text("GasTag-Update")
                        .fontWeight(.medium)
                }
                HStack {
                    Text("Password:")
                    Spacer()
                    Text("gastag123")
                        .fontWeight(.medium)
                }
            }
            .padding()
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)

            Text("Tap 'Connect & Upload' to join automatically,\nor manually join WiFi then tap 'Upload Only'")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var connectingToWiFiContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Connecting to device...")
                .font(.headline)

            Text("Accept the WiFi prompt when it appears")
                .foregroundColor(.secondary)

            Spacer()
                .frame(height: 12)

            Button(action: {
                updateManager.switchToManualWiFi()
            }) {
                Text("Having trouble?")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
    }

    private var completeContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("Update Complete!")
                .font(.headline)
            Text("The device is restarting with the new firmware")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            Text("Update Failed")
                .font(.headline)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch updateManager.state {
        case .idle:
            Button("Check for Updates") {
                Task {
                    await updateManager.checkForUpdates()
                }
            }
            .buttonStyle(.borderedProminent)

        case .updateAvailable:
            Button("Download & Install") {
                Task {
                    await updateManager.performFullUpdate()
                }
            }
            .buttonStyle(.borderedProminent)

        case .downloaded:
            Button("Install Update") {
                Task {
                    await updateManager.prepareDeviceForUpdate()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(bluetoothManager.connectionState != .connected)

            if bluetoothManager.connectionState != .connected {
                Text("Connect to device first")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

        case .waitingForWiFi:
            VStack(spacing: 12) {
                Button("Connect & Upload") {
                    Task {
                        await updateManager.joinESP32WiFi()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Upload Only (Manual WiFi)") {
                    Task {
                        await updateManager.uploadFirmwareManual()
                    }
                }
                .buttonStyle(.bordered)
            }

        case .downloading, .uploading, .checkingGitHub, .preparingDevice, .connectingToWiFi:
            Button("Cancel") {
                updateManager.cancel()
            }
            .buttonStyle(.bordered)

        case .complete:
            Button("Done") {
                updateManager.reset()
                dismiss()
            }
            .buttonStyle(.borderedProminent)

        case .error:
            HStack(spacing: 16) {
                Button("Retry") {
                    Task {
                        await updateManager.checkForUpdates()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    updateManager.reset()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    FirmwareUpdateView(
        updateManager: FirmwareUpdateManager(bluetoothManager: BluetoothManager()),
        bluetoothManager: BluetoothManager()
    )
}

import Foundation
import CoreBluetooth
import Combine

struct GasReading: Codable {
    let helium: Double
    let heliumIsStale: Bool  // true when analyzer showed ***.* (using last known value)
    let oxygen: Double
    let oxygenIsStale: Bool  // true when analyzer showed ***.* (using last known value)
    let temperature: Double
    let pressure: Double
    let timestamp: String
}

enum BLEConnectionState: String {
    case disconnected = "Disconnected"
    case scanning = "Scanning..."
    case connecting = "Connecting..."
    case connected = "Connected"
    case disconnecting = "Disconnecting..."
    case bluetoothOff = "Bluetooth Off"
    case unauthorized = "Bluetooth Unauthorized"
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

class BluetoothManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var currentReading: GasReading?
    @Published var rawLines: [String] = []
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDeviceName: String?
    @Published var signalStrength: Int = 0
    @Published var isReceivingData: Bool = false
    @Published var isSimulating: Bool = false
    @Published var firmwareVersion: String?

    // Track when data was last received (for "Receiving" status)
    private var lastDataReceivedTime: Date?
    private var receivingStatusTimer: Timer?
    private let receivingTimeoutSeconds: TimeInterval = 5.0

    // Track last known values for when analyzer shows ***.*
    private var lastKnownHelium: Double = 0.0
    private var lastKnownOxygen: Double = 0.0

    // Simulation properties
    private var simulationTimer: Timer?
    private var simulatedHelium: Double = 50.0
    private var simulatedOxygen: Double = 21.0
    private var simulatedTemperature: Double = 72.0
    private var simulatedPressure: Double = 29.92

    // MARK: - BLE Constants
    static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    static let characteristicUUID = CBUUID(string: "A1B2C3D5-E5F6-7890-ABCD-EF1234567890")
    static let versionCharacteristicUUID = CBUUID(string: "A1B2C3D6-E5F6-7890-ABCD-EF1234567890")
    static let otaControlCharacteristicUUID = CBUUID(string: "A1B2C3D7-E5F6-7890-ABCD-EF1234567890")

    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var gasReadingCharacteristic: CBCharacteristic?
    private var versionCharacteristic: CBCharacteristic?
    private var otaControlCharacteristic: CBCharacteristic?
    private var rssiTimer: Timer?
    private var shouldReconnect = false
    private var lastConnectedPeripheralIdentifier: UUID?

    // Continuations for async BLE operations
    private var versionReadContinuation: CheckedContinuation<String?, Never>?
    private var otaModeContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    deinit {
        disconnect()
    }

    // MARK: - Public Methods

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            addRawLine("[Error] Bluetooth is not available")
            return
        }

        discoveredDevices.removeAll()
        connectionState = .scanning
        addRawLine("[Info] Scanning for GasTag Bridge devices...")

        // Scan for devices advertising our service UUID
        centralManager.scanForPeripherals(
            withServices: [BluetoothManager.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Auto-stop scanning after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.connectionState == .scanning else { return }
            self.stopScanning()
            self.addRawLine("[Info] Scan timeout - stopped scanning")
        }
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
        addRawLine("[Info] Stopped scanning")
    }

    func connect(to device: DiscoveredDevice) {
        stopScanning()
        connectionState = .connecting
        lastConnectedPeripheralIdentifier = device.peripheral.identifier
        shouldReconnect = true
        addRawLine("[Info] Connecting to \(device.name)...")

        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        // ADD THIS CHECK AT THE BEGINNING
        if isSimulating {
            stopSimulation()
            return
        }

        shouldReconnect = false
        rssiTimer?.invalidate()
        rssiTimer = nil
        stopReceivingStatusTimer()
        lastDataReceivedTime = nil

        if let peripheral = connectedPeripheral {
            connectionState = .disconnecting
            centralManager.cancelPeripheralConnection(peripheral)
        }

        connectedPeripheral = nil
        gasReadingCharacteristic = nil
        versionCharacteristic = nil
        otaControlCharacteristic = nil
        connectedDeviceName = nil
        firmwareVersion = nil
        signalStrength = 0
        connectionState = .disconnected
        addRawLine("[Info] Disconnected")
    }

    // MARK: - Simulation Methods

    func startSimulation() {
        // Stop any existing connection
        if connectedPeripheral != nil {
            disconnect()
        }
        stopScanning()

        // Initialize random base values within realistic ranges
        simulatedHelium = Double.random(in: 40...80)
        // Ensure He + O2 <= 100 (leave room for nitrogen)
        let maxOxygen = min(50.0, 100.0 - simulatedHelium - 10.0)  // Keep at least 10% N2
        simulatedOxygen = Double.random(in: 10...maxOxygen)
        simulatedTemperature = Double.random(in: 68...78)
        simulatedPressure = Double.random(in: 29.5...30.5)

        // Set state
        isSimulating = true
        connectionState = .connected
        connectedDeviceName = "GasTag Simulator"
        addRawLine("[Info] Simulation mode started")

        // Generate initial reading
        generateSimulatedReading()

        // Start timer for varying data
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.generateSimulatedReading()
        }

        // Start receiving status timer
        startReceivingStatusTimer()
    }

    func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        stopReceivingStatusTimer()
        isSimulating = false
        connectionState = .disconnected
        connectedDeviceName = nil
        currentReading = nil
        lastDataReceivedTime = nil
        addRawLine("[Info] Simulation mode stopped")
    }

    private func generateSimulatedReading() {
        // Drift values slightly
        simulatedHelium += Double.random(in: -0.3...0.3)
        simulatedHelium = max(40, min(80, simulatedHelium))

        // Adjust O2 to stay within constraint (He + O2 <= 100, keep at least 10% N2)
        let maxOxygen = min(50.0, 100.0 - simulatedHelium - 10.0)
        simulatedOxygen += Double.random(in: -0.3...0.3)
        simulatedOxygen = max(10, min(maxOxygen, simulatedOxygen))

        simulatedTemperature += Double.random(in: -0.2...0.2)
        simulatedTemperature = max(68, min(78, simulatedTemperature))

        simulatedPressure += Double.random(in: -0.05...0.05)
        simulatedPressure = max(29.5, min(30.5, simulatedPressure))

        // Format timestamp like real analyzer
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())

        // Create simulated reading line (matches real analyzer format)
        let line = String(format: "He  %5.1f %%  O2  %4.1f %%  Ti  %4.1f ~F   %5.2f inHg   %@",
                          simulatedHelium, simulatedOxygen, simulatedTemperature, simulatedPressure, timestamp)

        addRawLine("[Sim] \(line)")

        let reading = GasReading(
            helium: simulatedHelium,
            heliumIsStale: false,
            oxygen: simulatedOxygen,
            oxygenIsStale: false,
            temperature: simulatedTemperature,
            pressure: simulatedPressure,
            timestamp: timestamp
        )

        markDataReceived()

        DispatchQueue.main.async {
            self.currentReading = reading
        }
    }

    // MARK: - OTA Update Methods

    /// Read the firmware version from the connected device
    /// - Returns: The firmware version string, or nil if not available
    func readFirmwareVersion() async -> String? {
        guard connectionState == .connected,
              let peripheral = connectedPeripheral,
              let characteristic = versionCharacteristic else {
            addRawLine("[OTA] Cannot read version: not connected or characteristic not found")
            return nil
        }

        return await withCheckedContinuation { continuation in
            versionReadContinuation = continuation
            peripheral.readValue(for: characteristic)

            // Timeout after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let cont = self?.versionReadContinuation {
                    self?.versionReadContinuation = nil
                    self?.addRawLine("[OTA] Version read timeout")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Send command to ESP32 to enter OTA update mode
    /// The device will stop BLE and start WiFi AP for firmware upload
    /// - Returns: true if command was sent successfully
    func enterOTAMode() async -> Bool {
        guard connectionState == .connected,
              let peripheral = connectedPeripheral,
              let characteristic = otaControlCharacteristic else {
            addRawLine("[OTA] Cannot enter OTA mode: not connected or characteristic not found")
            return false
        }

        // Command 0x01 = enter OTA mode
        let command = Data([0x01])

        return await withCheckedContinuation { continuation in
            otaModeContinuation = continuation
            peripheral.writeValue(command, for: characteristic, type: .withResponse)

            // Timeout after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let cont = self?.otaModeContinuation {
                    self?.otaModeContinuation = nil
                    self?.addRawLine("[OTA] OTA mode command timeout")
                    cont.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func parseReading(_ line: String) {
        // Skip internal status messages (already displayed in raw log)
        if line.hasPrefix("[") {
            return
        }

        // Parse format: "He   0.4 %  O2  20.2 %  Ti  79.0 ~F    29.5 inHg   2025/12/15 21:36:26"
        // Note: He and O2 can be "***.*" when analyzer has no valid reading
        let pattern = #"He\s+([\d.*]+)\s*%\s+O2\s+([\d.*]+)\s*%\s+Ti\s+([\d.]+)\s*~F\s+([\d.]+)\s*inHg\s+(.+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) else {
            return  // Silently ignore unparseable lines
        }

        guard let heRange = Range(match.range(at: 1), in: line),
              let o2Range = Range(match.range(at: 2), in: line),
              let tempRange = Range(match.range(at: 3), in: line),
              let pressureRange = Range(match.range(at: 4), in: line),
              let timestampRange = Range(match.range(at: 5), in: line),
              let temperature = Double(line[tempRange]),
              let pressure = Double(line[pressureRange]) else {
            return  // Silently ignore unparseable lines
        }

        // He and O2 may be "***.*" when analyzer has no valid reading
        let heString = String(line[heRange])
        let o2String = String(line[o2Range])

        let heliumIsStale = heString.contains("*")
        let oxygenIsStale = o2String.contains("*")

        // Use current value or fall back to last known
        let helium = Double(heString) ?? lastKnownHelium
        let oxygen = Double(o2String) ?? lastKnownOxygen

        // Update last known values when we get good readings
        if !heliumIsStale { lastKnownHelium = helium }
        if !oxygenIsStale { lastKnownOxygen = oxygen }

        let reading = GasReading(
            helium: helium,
            heliumIsStale: heliumIsStale,
            oxygen: oxygen,
            oxygenIsStale: oxygenIsStale,
            temperature: temperature,
            pressure: pressure,
            timestamp: String(line[timestampRange]).trimmingCharacters(in: .whitespaces)
        )

        // Mark that we received valid analyzer data (for "Receiving" status)
        markDataReceived()

        DispatchQueue.main.async {
            self.currentReading = reading
        }
    }

    private func addRawLine(_ line: String) {
        DispatchQueue.main.async {
            self.rawLines.append(line)
            // Keep only last 100 lines
            if self.rawLines.count > 100 {
                self.rawLines.removeFirst()
            }
        }
    }

    private func startRSSITimer() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.connectedPeripheral?.readRSSI()
        }
    }

    private func startReceivingStatusTimer() {
        receivingStatusTimer?.invalidate()
        receivingStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateReceivingStatus()
        }
    }

    private func stopReceivingStatusTimer() {
        receivingStatusTimer?.invalidate()
        receivingStatusTimer = nil
        DispatchQueue.main.async {
            self.isReceivingData = false
        }
    }

    private func updateReceivingStatus() {
        DispatchQueue.main.async {
            if let lastTime = self.lastDataReceivedTime {
                self.isReceivingData = Date().timeIntervalSince(lastTime) < self.receivingTimeoutSeconds
            } else {
                self.isReceivingData = false
            }
        }
    }

    private func markDataReceived() {
        lastDataReceivedTime = Date()
        DispatchQueue.main.async {
            self.isReceivingData = true
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect, let identifier = lastConnectedPeripheralIdentifier else { return }

        addRawLine("[Info] Will attempt to reconnect...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self, self.shouldReconnect else { return }

            // Try to retrieve the peripheral by identifier
            let peripherals = self.centralManager.retrievePeripherals(withIdentifiers: [identifier])
            if let peripheral = peripherals.first {
                self.connectionState = .connecting
                self.addRawLine("[Info] Reconnecting to \(peripheral.name ?? "device")...")
                self.centralManager.connect(peripheral, options: nil)
            } else {
                // Peripheral not found, start scanning
                self.addRawLine("[Info] Device not found, scanning...")
                self.startScanning()
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            addRawLine("[Info] Bluetooth is ready")
            if connectionState == .bluetoothOff {
                connectionState = .disconnected
            }
        case .poweredOff:
            connectionState = .bluetoothOff
            addRawLine("[Error] Bluetooth is turned off")
        case .unauthorized:
            connectionState = .unauthorized
            addRawLine("[Error] Bluetooth permission not granted")
        case .unsupported:
            addRawLine("[Error] Bluetooth is not supported on this device")
        case .resetting:
            addRawLine("[Info] Bluetooth is resetting...")
        case .unknown:
            addRawLine("[Info] Bluetooth state unknown")
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let deviceName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown Device"

        // Check if we already have this device
        if !discoveredDevices.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            let device = DiscoveredDevice(
                id: peripheral.identifier,
                peripheral: peripheral,
                name: deviceName,
                rssi: RSSI.intValue
            )
            DispatchQueue.main.async {
                self.discoveredDevices.append(device)
            }
            addRawLine("[Info] Found: \(deviceName) (RSSI: \(RSSI.intValue) dBm)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        addRawLine("[Connected] Connected to \(peripheral.name ?? "device")")
        connectedPeripheral = peripheral
        connectedDeviceName = peripheral.name ?? "GasTag Bridge"
        connectionState = .connected
        peripheral.delegate = self

        // Discover services
        peripheral.discoverServices([BluetoothManager.serviceUUID])

        // Start RSSI monitoring
        startRSSITimer()

        // Start receiving status timer
        startReceivingStatusTimer()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        addRawLine("[Error] Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        connectionState = .disconnected
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rssiTimer?.invalidate()
        rssiTimer = nil
        stopReceivingStatusTimer()
        lastDataReceivedTime = nil
        connectedPeripheral = nil
        gasReadingCharacteristic = nil
        versionCharacteristic = nil
        otaControlCharacteristic = nil
        connectedDeviceName = nil
        firmwareVersion = nil
        signalStrength = 0

        if let error = error {
            addRawLine("[Error] Disconnected: \(error.localizedDescription)")
            connectionState = .disconnected
            scheduleReconnect()
        } else {
            addRawLine("[Info] Disconnected from device")
            connectionState = .disconnected
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            addRawLine("[Error] Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        for service in services {
            if service.uuid == BluetoothManager.serviceUUID {
                addRawLine("[Info] Found GasTag service")
                peripheral.discoverCharacteristics([
                    BluetoothManager.characteristicUUID,
                    BluetoothManager.versionCharacteristicUUID,
                    BluetoothManager.otaControlCharacteristicUUID
                ], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            addRawLine("[Error] Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            if characteristic.uuid == BluetoothManager.characteristicUUID {
                addRawLine("[Info] Found gas reading characteristic")
                gasReadingCharacteristic = characteristic

                // Enable notifications
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    addRawLine("[Info] Enabled notifications")
                }

                // Read current value
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            } else if characteristic.uuid == BluetoothManager.versionCharacteristicUUID {
                addRawLine("[Info] Found firmware version characteristic")
                versionCharacteristic = characteristic

                // Auto-read firmware version on connect
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            } else if characteristic.uuid == BluetoothManager.otaControlCharacteristicUUID {
                addRawLine("[Info] Found OTA control characteristic")
                otaControlCharacteristic = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addRawLine("[Error] Read failed: \(error.localizedDescription)")
            // Resume version continuation with nil on error
            if characteristic.uuid == BluetoothManager.versionCharacteristicUUID,
               let continuation = versionReadContinuation {
                versionReadContinuation = nil
                continuation.resume(returning: nil)
            }
            return
        }

        guard let data = characteristic.value,
              let message = String(data: data, encoding: .utf8) else {
            return
        }

        if characteristic.uuid == BluetoothManager.characteristicUUID {
            addRawLine(message)
            parseReading(message)
        } else if characteristic.uuid == BluetoothManager.versionCharacteristicUUID {
            addRawLine("[OTA] Firmware version: \(message)")
            DispatchQueue.main.async {
                self.firmwareVersion = message
            }
            // Resume continuation if waiting
            if let continuation = versionReadContinuation {
                versionReadContinuation = nil
                continuation.resume(returning: message)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addRawLine("[Error] Notification state update failed: \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            addRawLine("[Info] Subscribed to notifications")
        } else {
            addRawLine("[Info] Unsubscribed from notifications")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            DispatchQueue.main.async {
                self.signalStrength = RSSI.intValue
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == BluetoothManager.otaControlCharacteristicUUID {
            if let continuation = otaModeContinuation {
                otaModeContinuation = nil
                if let error = error {
                    addRawLine("[OTA] Failed to send OTA command: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    addRawLine("[OTA] OTA mode command sent successfully")
                    addRawLine("[OTA] Device will start WiFi AP 'GasTag-Update'")
                    continuation.resume(returning: true)
                }
            }
        }
    }
}

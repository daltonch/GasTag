# GasTag

[(GasTagApp.PNG)](https://github.com/daltonch/GasTag/blob/ff082769e666bee69dba1d39c1b543d2a8940064/GasTagApp.PNG)

A system for displaying and printing gas analyzer data on iPhone via an ESP32-S3 Bluetooth bridge. The gas analyzer outputs serial data over USB, which the ESP32-S3 reads as a USB host and broadcasts over Bluetooth Low Energy (BLE) to the iOS app.

## Prerequisites

Before setting up GasTag, you'll need the following hardware:

### Gas Analyzer
- **Divesoft He/O2 Analyzer** with USB Type-B output
  - Outputs serial data at 115200 baud
  - Data format: `He 0.4 % O2 20.2 % Ti 79.0 ~F 29.5 inHg 2025/12/15 21:36:26`

### ESP32-S3 Development Board
- **Recommended:** YD-ESP32-S3 (VCC-GND Studio clone)
  - Available from [Amazon - ESP32-S3 Development Board Type-C](https://amzn.to/490tVlt)
  - Features dual USB-C ports
  - Identifiable by: 4 LEDs in a row (RGB, Power, TX, RX) and "USB-OTG" solder pads on back

### Cables & Adapters
- USB-C to USB-A OTG adapter (e.g., [JSAUX adapter](https://amzn.to/4q7WVho))
- USB-A to USB-B cable (for gas analyzer connection)
- USB-C cable (for ESP32 power/programming)

### Label Printer
- **Brother QL-820NWB** [label printer with Bluetooth](https://amzn.to/3L9wgl2)
- **62mm continuous roll labels** [DK-2251](https://amzn.to/4sgpgn7)

### iOS Device
- iPhone with Bluetooth 5.0, iPhone 13 and 15 Pro were used in Testing, ESP32 can be powered via the iPhone 15 w/ USBC
- iOS 13 or later
- Xcode 15+ (for building the app)
- Android Studio or PlatformIO (for building and flashing the ESP32 Firmware)

---

## ESP32 Firmware

The ESP32 firmware creates a USB host to read data from the gas analyzer and a BLE server to broadcast readings to the iPhone.

### Hardware Setup

#### YD-ESP32-S3 with USB-OTG Jumper (Recommended)

1. Connect the **UART USB-C port** to power (iPhone or USB power source)
2. Connect the **OTG USB-C port** via adapter chain:
   ```
   ESP32 OTG Port → USB-C to USB-A adapter → USB-A to USB-B cable → Gas Analyzer
   ```

### Flashing the Firmware

#### Prerequisites

Install [PlatformIO](https://platformio.org/):
- **VS Code Extension:** Install "PlatformIO IDE" from the Extensions marketplace
- **CLI:** `pip install platformio`

#### Build and Flash

1. Navigate to the firmware directory:
   ```bash
   cd GasTag/ESP32Firmware
   ```

2. Connect the ESP32 to your computer via the UART USB-C port

3. Build and upload the firmware:
   ```bash
   pio run -t upload
   ```

4. Monitor serial output (optional, for debugging):
   ```bash
   pio device monitor
   ```
   - Baud rate: 115200
   - You should see BLE advertising messages and USB device detection

### Verifying the Firmware

Once flashed, the ESP32 will:
- Advertise as **"GasTag Bridge"** over BLE
- Wait for USB device connection
- Auto-detect the Divesoft analyzer (VID: 0xA600, PID: 0xE212)
- Forward serial data as BLE notifications

You can verify BLE advertising using the **nRF Connect** app on your phone before connecting with GasTag.

---

## iOS App

The GasTag iOS app displays gas readings, calculates MOD (Maximum Operating Depth), and prints labels to a Brother printer.

### Building the App

1. Open the Xcode project:
   ```bash
   open GasTag/GasTag.xcodeproj
   ```

2. Select your development team in **Signing & Capabilities**

3. Connect your iPhone and select it as the build target

4. Build and run (Cmd+R)

### Connecting to the ESP32

1. **Power on the ESP32** - it will begin advertising as "GasTag Bridge"

2. **Open GasTag** on your iPhone

3. **Tap the device status indicator** (shows "No Device" initially) or go to **Settings > Gas Analyzer**

4. **Tap "Scan for Devices"** - the app will search for nearby GasTag bridges

5. **Select "GasTag Bridge"** from the device list

6. Once connected:
   - Status shows "Connected" (or "Receiving" when data is flowing)
   - RSSI (signal strength) is displayed
   - Gas readings appear in real-time

#### Connection States

| State      | Description                               |
|------------|-------------------------------------------|
| No Device  | Not connected to any ESP32                |
| Scanning   | Searching for GasTag Bridge devices       |
| Connecting | Establishing BLE connection               |
| Connected  | Connected but not receiving data          |
| Receiving  | Connected and actively receiving gas data |
|------------|-------------------------------------------|

#### Troubleshooting

- **Can't find device:** Ensure ESP32 is powered and not connected to another device
- **Connection drops:** Check ESP32 power supply; reduce distance to device
- **No data received:** Verify gas analyzer is connected to ESP32 and outputting data

### Connecting to the Printer

1. **Power on the Brother QL-820NWB** and ensure Bluetooth is enabled on the printer

2. **Open GasTag Settings** (gear icon in top-right)

3. **Tap the printer status indicator** or go to **Printer > Search for Printers**

4. **Wait for printer discovery** - the app searches for Brother printers via Bluetooth

5. **Select your QL-820NWB** from the list

6. The printer connection is saved and will auto-reconnect on future app launches

#### Printing Labels

1. Ensure both the **ESP32 is connected** and **receiving data**

2. The **label preview** on the main screen shows what will be printed:
   - MOD calculation with PPO2 setting
   - He and O2 percentages
   - Temperature and timestamp
   - Custom tank name

3. **Tap "Print Label"** to print

4. Labels print on **62mm continuous roll** with auto-cut enabled

#### Label Customization

- **Tank Name:** Tap the tank name field to edit; recent names are saved
- **PPO2 for MOD:** Adjust in Settings > Units (default: 1.6)
- **Temperature Unit:** Choose Fahrenheit or Celsius in Settings
- **Depth Unit:** Choose feet or meters in Settings

#### Printer Troubleshooting

| Issue               | Solution                                                  |
|---------------------|-----------------------------------------------------------|
| Printer not found   | Ensure printer Bluetooth is on; restart printer           |
| "Wrong media" error | Load 62mm continuous roll (DK-2205 or DK-2251)            |
| Print fails         | Check printer has labels loaded; restart printer          |
| Connection timeout  | Move closer to printer; ensure no other devices connected |
|---------------------|-----------------------------------------------------------|

### App Features

- **Live Gas Readings:** He%, O2%, temperature, pressure
- **MOD Calculation:** Automatic Maximum Operating Depth based on O2% and PPO2
- **Stale Value Indication:** Values shown in brackets when analyzer displays `***.*`
- **Label Preview:** Real-time preview of what will be printed
- **Raw Data Log:** Color-coded log of all received data
- **Unit Preferences:** Temperature (F/C), Depth (ft/m)
- **Auto-Reconnect:** Automatically reconnects to ESP32 if connection drops

---

## BLE Protocol Reference

For developers modifying the system:

| Parameter           | Value                                  |
|---------------------|----------------------------------------|
| Service UUID        | `A1B2C3D4-E5F6-7890-ABCD-EF1234567890` |
| Characteristic UUID | `A1B2C3D5-E5F6-7890-ABCD-EF1234567890` |
| Device Name         | `GasTag Bridge`                        |
| Properties          | READ, NOTIFY                           |
|---------------------|----------------------------------------|

Data is transmitted as UTF-8 encoded strings matching the gas analyzer output format.

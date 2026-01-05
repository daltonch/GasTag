import SwiftUI

// MARK: - Mix Label Helper

func formatMixLabel(helium: Double, oxygen: Double) -> String {
    let he = Int(helium.rounded())
    let o2 = Int(oxygen.rounded())
    return "\(he)/\(o2)"
}

struct LabelView: View {
    let helium: Double
    let heliumIsStale: Bool
    let oxygen: Double
    let oxygenIsStale: Bool
    let temperature: Double
    let timestamp: String
    let customText: String
    let depthUnit: DepthUnit

    // Format value with brackets if stale (brackets include suffix when stale)
    private func formatValue(_ value: Double, isStale: Bool, suffix: String = "") -> String {
        let formatted = String(format: "%.1f", value)
        return isStale ? "[\(formatted)\(suffix)]" : "\(formatted)\(suffix)"
    }

    private var mod: String {
        UserSettings.shared.formattedMOD(oxygenPercent: oxygen)
    }

    private var ppo2Value: Double {
        UserSettings.shared.ppo2ForMOD
    }

    private var isPPO2Warning: Bool {
        UserSettings.shared.isPPO2Warning
    }

    private var formattedTimestamp: String {
        // Try to parse and reformat the timestamp
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy/MM/dd HH:mm:ss"

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MM-dd-yyyy HH:mm"

        if let date = inputFormatter.date(from: timestamp) {
            return outputFormatter.string(from: date)
        }
        // If parsing fails, try to return as-is without seconds
        return timestamp
    }

    private var formattedTemp: String {
        UserSettings.shared.formattedTemperature(temperature)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MOD Row - Red background, white text
            VStack(spacing: 4) {
                Text("MOD @ \(String(format: "%.1f", ppo2Value)) PPO\u{2082}")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(mod)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                if isPPO2Warning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text("HIGH PPO\u{2082}")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.yellow)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isPPO2Warning ? Color.orange : Color.red)

            // He Row
            Text("He: \(formatValue(helium, isStale: heliumIsStale, suffix: "%"))")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.black)
                .padding(.vertical, 12)

            // O2 Row
            Text("O\u{2082}: \(formatValue(oxygen, isStale: oxygenIsStale, suffix: "%"))")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.black)
                .padding(.vertical, 12)

            // Temp + Timestamp Row
            Text("\(formattedTemp)  •  \(formattedTimestamp)")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .padding(.vertical, 8)

            // Custom Text Row
            if !customText.isEmpty {
                Text(customText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.vertical, 8)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 300)
        .background(Color.white)
    }
}

// MARK: - Image Rendering Extension

extension LabelView {
    @MainActor
    func renderToImage() -> UIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 3.0
        return renderer.uiImage
    }
}

// MARK: - No Data View

struct NoDataView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No Data")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.gray)

            Text("Connect to GasTag Bridge to receive gas readings")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(width: 300)
        .padding(.vertical, 40)
        .background(Color(.systemGray6))
    }
}

// MARK: - Label Preview Card

struct LabelPreviewCard: View {
    let reading: GasReading?
    let isActivelyReceiving: Bool  // true when BLE connected AND data received within timeout
    @ObservedObject var settings: UserSettings
    @State private var showingTankNamePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LABEL PREVIEW")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Tap to edit name")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            Button {
                showingTankNamePicker = true
            } label: {
                VStack {
                    if let reading = reading {
                        // Show brackets when not actively receiving OR when analyzer reports stale data
                        LabelView(
                            helium: reading.helium,
                            heliumIsStale: reading.heliumIsStale || !isActivelyReceiving,
                            oxygen: reading.oxygen,
                            oxygenIsStale: reading.oxygenIsStale || !isActivelyReceiving,
                            temperature: reading.temperature,
                            timestamp: reading.timestamp,
                            customText: settings.customLabelText,
                            depthUnit: settings.depthUnit
                        )
                    } else {
                        NoDataView()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingTankNamePicker) {
            TankNamePickerView(settings: settings)
        }
    }
}

// MARK: - Tank Name Picker View

struct TankNamePickerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var settings: UserSettings
    @State private var newName: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationView {
            List {
                // New name section
                Section("New Name") {
                    HStack {
                        TextField("Enter tank name", text: $newName)
                            .focused($isTextFieldFocused)
                            .onSubmit {
                                if !newName.isEmpty {
                                    selectName(newName)
                                }
                            }
                        if !newName.isEmpty {
                            Button("Add") {
                                selectName(newName)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // Saved names section
                if !settings.savedTankNames.isEmpty {
                    Section("Recent Names") {
                        ForEach(settings.savedTankNames, id: \.self) { name in
                            HStack {
                                Button {
                                    settings.removeTankName(name)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    selectName(name)
                                } label: {
                                    HStack {
                                        Text(name)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if name == settings.customLabelText {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Clear option
                Section {
                    Button("Clear Tank Name") {
                        settings.customLabelText = ""
                        dismiss()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Tank Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func selectName(_ name: String) {
        settings.customLabelText = name
        settings.saveTankName(name)
        dismiss()
    }
}

// MARK: - Preview Provider

struct LabelView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            LabelView(
                helium: 0.4,
                heliumIsStale: false,
                oxygen: 20.2,
                oxygenIsStale: false,
                temperature: 79.0,
                timestamp: "2025/12/15 21:36:26",
                customText: "Tank #1 - Deco Mix",
                depthUnit: .feet
            )

            LabelView(
                helium: 35.0,
                heliumIsStale: true,
                oxygen: 21.0,
                oxygenIsStale: false,
                temperature: 22.0,
                timestamp: "2025/12/15 21:36:26",
                customText: "Stale He Example",
                depthUnit: .meters
            )
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}

// MARK: - Mix Label View

struct MixLabelView: View {
    let helium: Double
    let oxygen: Double

    private var mixText: String {
        formatMixLabel(helium: helium, oxygen: oxygen)
    }

    var body: some View {
        Text(mixText)
            .font(.system(size: 36, weight: .bold))
            .foregroundColor(.black)
            .frame(width: 300, height: 50)
            .background(Color.white)
    }
}

// MARK: - Mix Label Image Rendering

extension MixLabelView {
    @MainActor
    func renderToImage() -> UIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 3.0
        return renderer.uiImage
    }
}

// MARK: - Mix Label Preview Card

struct MixLabelPreviewCard: View {
    let reading: GasReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIX LABEL")
                .font(.caption)
                .foregroundColor(.secondary)

            if let reading = reading {
                MixLabelView(helium: reading.helium, oxygen: reading.oxygen)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            }
        }
    }
}

// MARK: - Image Combining Helper

@MainActor
func combineLabelsVertically(main: UIImage, mix: UIImage?, gap: CGFloat = 20) -> UIImage {
    guard let mixImage = mix else {
        return main
    }

    let totalWidth = max(main.size.width, mixImage.size.width)
    let totalHeight = main.size.height + gap + mixImage.size.height

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: totalHeight))

    return renderer.image { context in
        // Draw white background
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

        // Draw main label centered horizontally
        let mainX = (totalWidth - main.size.width) / 2
        main.draw(at: CGPoint(x: mainX, y: 0))

        // Draw mix label centered horizontally below main
        let mixX = (totalWidth - mixImage.size.width) / 2
        mixImage.draw(at: CGPoint(x: mixX, y: main.size.height + gap))
    }
}

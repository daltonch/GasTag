import SwiftUI

@main
struct GasTagApp: App {
    @ObservedObject private var settings = UserSettings.shared

    init() {
        print("GasTagApp")
        #if targetEnvironment(simulator)
        // Disable animations in simulator for better performance
        UIView.setAnimationsEnabled(false)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

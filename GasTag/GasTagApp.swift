import SwiftUI
import SwiftData

@main
struct GasTagApp: App {
    @ObservedObject private var settings = UserSettings.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([PrintedLabel.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        print("GasTagApp")
        #if targetEnvironment(simulator)
        UIView.setAnimationsEnabled(false)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
        }
        .modelContainer(sharedModelContainer)
    }

    private var colorScheme: ColorScheme? {
        switch settings.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

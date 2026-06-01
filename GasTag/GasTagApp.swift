import SwiftUI
import SwiftData
import OSLog

// MARK: - Versioned Schema

/// SchemaV1 captures the initial production schema for GasTag.
/// When adding a new field or making a breaking change, create SchemaV2 here,
/// add a migration stage in GasTagMigrationPlan, and update currentEntitiesForContainer.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [PrintedLabel.self] }
}

// MARK: - Migration Plan

/// GasTagMigrationPlan is the single source of truth for all SwiftData migrations.
/// Even with no migrations yet, this plan gives future changes a safe home.
/// To add a migration: define SchemaV2, create a MigrationStage, and append it to `stages`.
enum GasTagMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - Container Builder

private let logger = Logger(subsystem: "com.gatewaygeo.GasTag", category: "ModelContainer")

/// Attempts to build the persistent ModelContainer using the versioned migration plan.
/// Recovery strategy (three tiers, chosen to preserve user data as long as possible):
///   1. Normal path: versioned container on disk with migration plan applied.
///   2. If that fails (e.g. store file is corrupt but not schema-incompatible), log the error
///      and retry once with a fresh persistent store at the same URL after removing the
///      corrupted file. This is a last-resort data-loss step; we log prominently so it is
///      visible in crash reporters / Console.app.
///   3. If even that fails, fall back to an in-memory container so the app launches and
///      the user can at least use it (data will not persist this session).
///
/// NOTE: Tier 2 deletes the on-disk store and therefore loses existing persisted data.
/// This is intentional: a bricked app is worse than lost history that the user can
/// re-accumulate. The deletion is guarded behind a failed Tier 1, so it only fires
/// when the store is already unreadable.
private func buildModelContainer() -> ModelContainer {
    // Tier 1: normal versioned persistent container
    do {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(
            for: schema,
            migrationPlan: GasTagMigrationPlan.self,
            configurations: [config]
        )
    } catch {
        logger.error("ModelContainer (Tier 1) failed: \(error, privacy: .public)")
    }

    // Tier 2: delete the corrupted store and create a fresh persistent container
    // ⚠️ DATA LOSS: existing PrintedLabel history will be lost.
    let storeURL = ModelConfiguration().url
    do {
        try FileManager.default.removeItem(at: storeURL)
        logger.warning("Deleted corrupted SwiftData store at \(storeURL, privacy: .public) — user history cleared.")
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(
            for: schema,
            migrationPlan: GasTagMigrationPlan.self,
            configurations: [config]
        )
    } catch {
        logger.error("ModelContainer (Tier 2 – after store deletion) failed: \(error, privacy: .public)")
    }

    // Tier 3: in-memory container — app works this session but nothing persists
    logger.error("Falling back to in-memory ModelContainer. Data will NOT persist this session.")
    do {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    } catch {
        // If even an in-memory container fails something is deeply wrong with the binary.
        fatalError("Could not create even an in-memory ModelContainer: \(error)")
    }
}

@main
struct GasTagApp: App {
    @ObservedObject private var settings = UserSettings.shared

    var sharedModelContainer: ModelContainer = buildModelContainer()

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

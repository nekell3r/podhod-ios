// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Podhod",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PodhodCore", targets: ["PodhodCore"])],
    targets: [
        .target(name: "PodhodCore", path: "Podhod", exclude: ["NutritionExportView.swift", "NutritionDiaryView.swift", "NutritionSynchronization.swift", "NutritionView.swift", "Assets.xcassets", "CloudAccountView.swift", "CloudAuthentication.swift", "CloudSynchronization.swift", "Design.swift", "ExerciseDetailView.swift", "Info.plist", "PodhodApp.swift", "ProgramView.swift", "ProgressScreen.swift", "ProteinReminders.swift", "ProteinTodayCard.swift", "TodayView.swift", "TrainingCloudAPI.swift", "WorkoutView.swift", "WorkoutCompositionView.swift"], sources: ["NutritionDiary.swift", "NutritionSyncState.swift", "NutritionDiaryStore.swift", "NutritionPreferences.swift", "Nutrition.swift", "NutritionCatalog.swift", "Models.swift", "WorkoutProgress.swift", "ExerciseCatalog.swift", "MuscleVolume.swift", "WorkoutTiming.swift", "TrainingCalendar.swift", "CloudSyncModels.swift", "WorkoutStore.swift", "ProteinTracker.swift", "AccountWorkspaces.swift", "CloudAccountProfile.swift"], resources: [.process("Resources")]),
        .testTarget(name: "PodhodCoreTests", dependencies: ["PodhodCore"])
    ]
)

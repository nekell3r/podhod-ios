import Foundation

struct TrainingTemplateRecord: Codable, Equatable {
    var revision: Int64
    var days: [TrainingDay]
}

struct ActiveWorkoutState: Codable, Equatable {
    var session: WorkoutSession
    var restUntil: Date?
    var restKind: WorkoutRestKind?
    var restExerciseID: UUID?
}

struct ActiveWorkoutRecord: Codable, Equatable {
    var revision: Int64
    var state: ActiveWorkoutState?
}

struct TrainingCloudProfile: Decodable {
    var id: String
    var timezone: String?
}

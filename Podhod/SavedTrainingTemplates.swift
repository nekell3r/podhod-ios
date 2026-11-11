import Foundation

struct SavedTrainingTemplate: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var days: [TrainingDay]
    var structureVersion: Int?

    var isValid: Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && name.unicodeScalars.count <= 80 &&
            TrainingTemplateRecord(revision: 0, days: days, structureVersion: structureVersion).hasValidStructure &&
            days.allSatisfy { day in
                day.exercises.count <= 50 && Set(day.exercises.map(\.id)).count == day.exercises.count &&
                    day.exercises.allSatisfy {
                        !$0.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        (1...12).contains($0.setCount) && !$0.targetReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        (0...600).contains($0.restSeconds) && (0...600).contains($0.restAfterExerciseSeconds)
                    }
            }
    }
}

struct SavedTrainingTemplatesDocument: Codable, Equatable {
    var version = 1
    var templates: [SavedTrainingTemplate] = []
    var isValid: Bool {
        version == 1 && templates.count <= 20 && Set(templates.map(\.id)).count == templates.count &&
            templates.allSatisfy(\.isValid)
    }
}

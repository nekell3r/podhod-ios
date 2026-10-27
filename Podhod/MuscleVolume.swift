import Foundation

struct MuscleSetVolume: Equatable, Identifiable {
    let id: String
    let name: String
    let directSets: Int
    let indirectSets: Int
    var weightedSets: Double { Double(directSets) + Double(indirectSets) * 0.5 }
}

struct PlannedMuscleVolume: Equatable {
    let catalogVersion: String
    let totalSets: Int
    let muscles: [MuscleSetVolume]
    let unmappedExerciseCount: Int
    let unmappedSets: Int
}

extension ExerciseCatalog {
    func volume(for plans: [PlannedExercise]) -> PlannedMuscleVolume {
        var direct: [String: Int] = [:]
        var indirect: [String: Int] = [:]
        var unmappedExerciseCount = 0
        var unmappedSets = 0
        for plan in plans {
            guard let entry = entry(for: plan.exercise.id),
                  !entry.primaryMuscles.isEmpty || !entry.secondaryMuscles.isEmpty else {
                unmappedExerciseCount += 1
                unmappedSets += plan.setCount
                continue
            }
            let primary = Set(entry.primaryMuscles)
            let secondary = Set(entry.secondaryMuscles).subtracting(primary)
            for muscle in primary { direct[muscle, default: 0] += plan.setCount }
            for muscle in secondary { indirect[muscle, default: 0] += plan.setCount }
        }
        let totals = muscles.compactMap { muscle -> MuscleSetVolume? in
            let directSets = direct[muscle.id, default: 0]
            let indirectSets = indirect[muscle.id, default: 0]
            guard directSets > 0 || indirectSets > 0 else { return nil }
            return MuscleSetVolume(id: muscle.id, name: muscle.name, directSets: directSets, indirectSets: indirectSets)
        }
        return PlannedMuscleVolume(catalogVersion: version, totalSets: plans.reduce(0) { $0 + $1.setCount }, muscles: totals,
                                   unmappedExerciseCount: unmappedExerciseCount, unmappedSets: unmappedSets)
    }

    func volume(for day: TrainingDay) -> PlannedMuscleVolume {
        volume(for: day.exercises)
    }

    func volume(for week: TrainingWeek) -> PlannedMuscleVolume {
        volume(for: week.workouts.flatMap(\.exercises))
    }

    func volume(for template: [TrainingDay]) -> PlannedMuscleVolume {
        volume(for: template.flatMap(\.exercises))
    }
}

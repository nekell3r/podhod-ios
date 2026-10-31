import Foundation

struct PlannedSuperset: Codable, Equatable, Identifiable {
    var id = UUID()
    var exerciseIDs: [UUID]
    var restSeconds: Int
}

struct SupersetRound: Codable, Equatable, Identifiable {
    var id = UUID()
    var ordinal: Int
    var setIDs: [UUID?]
}

struct SessionSuperset: Codable, Equatable, Identifiable {
    var id = UUID()
    var exerciseIDs: [UUID]
    var restSeconds: Int
    var isClosed = false
    var rounds: [SupersetRound]
}

extension TrainingDay {
    mutating func setPlannedSetCount(exerciseID: UUID, count: Int) {
        guard (1...12).contains(count) else { return }
        let members = supersets?.first(where: { $0.exerciseIDs.contains(exerciseID) })?.exerciseIDs ?? [exerciseID]
        for index in exercises.indices where members.contains(exercises[index].id) { exercises[index].setCount = count }
    }

    var hasStructureMetadata: Bool { context != nil || !(supersets ?? []).isEmpty }

    var hasValidPlannedStructure: Bool {
        guard (1...7).contains(weekday), exercises.count <= 50,
              Set(exercises.map(\.id)).count == exercises.count,
              context?.isValid ?? true,
              exercises.allSatisfy({ plan in
                  !plan.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      (1...12).contains(plan.setCount) && !plan.targetReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      (0...600).contains(plan.restSeconds) && (0...600).contains(plan.restAfterExerciseSeconds)
              }) else { return false }
        let groups = supersets ?? []
        guard groups.count <= 25, Set(groups.map(\.id)).count == groups.count else { return false }
        var members = Set<UUID>()
        return groups.allSatisfy { group in
            guard (2...4).contains(group.exerciseIDs.count), (0...600).contains(group.restSeconds) else { return false }
            let plans = group.exerciseIDs.compactMap { id in exercises.first { $0.id == id } }
            return plans.count == group.exerciseIDs.count && Set(plans.map(\.setCount)).count == 1 &&
                group.exerciseIDs.allSatisfy { members.insert($0).inserted }
        }
    }
}

extension TrainingWeek {
    var hasValidStructure: Bool {
        guard (0...1).contains(structureVersion ?? 0),
              structureVersion == 1 || workouts.allSatisfy({ !$0.hasStructureMetadata }) else { return false }
        return workouts.allSatisfy { $0.day(calendar: TrainingCalendar(timezone: timezone)).hasValidPlannedStructure }
    }
}

extension WorkoutSession {
    var hasValidStructure: Bool {
        guard (0...1).contains(structureVersion ?? 0), context?.isValid ?? true else { return false }
        let groups = supersets ?? []
        guard structureVersion == 1 || (context == nil && groups.isEmpty), groups.count <= 50,
              Set(groups.map(\.id)).count == groups.count,
              Set(exercises.map(\.id)).count == exercises.count,
              Set(exercises.flatMap(\.sets).map(\.id)).count == exercises.flatMap(\.sets).count else { return false }
        let cards = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let sets = Dictionary(uniqueKeysWithValues: exercises.flatMap { card in card.sets.map { ($0.id, (card.id, $0)) } })
        var openMembers = Set<UUID>(), roundIDs = Set<UUID>(), linkedSets = Set<UUID>()
        return groups.allSatisfy { group in
            guard (2...4).contains(group.exerciseIDs.count), (0...600).contains(group.restSeconds),
                  (1...600).contains(group.rounds.count), Set(group.exerciseIDs).count == group.exerciseIDs.count,
                  group.exerciseIDs.allSatisfy({ cards[$0] != nil && (group.isClosed || openMembers.insert($0).inserted) })
            else { return false }
            var ordinal = 0
            return group.rounds.allSatisfy { round in
                guard roundIDs.insert(round.id).inserted, round.ordinal > ordinal, round.ordinal <= 600,
                      round.setIDs.count == group.exerciseIDs.count else { return false }
                ordinal = round.ordinal
                var participants = Set<UUID>()
                for (slot, id) in round.setIDs.enumerated() {
                    guard let id else { continue }
                    guard let (cardID, set) = sets[id], linkedSets.insert(id).inserted, participants.insert(cardID).inserted,
                          !group.isClosed || set.isCompleted,
                          set.isCompleted || cardID == group.exerciseIDs[slot] else { return false }
                }
                return !participants.isEmpty
            }
        }
    }

    mutating func closeSuperset(id: UUID) {
        guard let index = supersets?.firstIndex(where: { $0.id == id }) else { return }
        let completed = Set(exercises.flatMap(\.sets).filter(\.isCompleted).map(\.id))
        var group = supersets![index]
        group.isClosed = true
        group.rounds = group.rounds.compactMap { round in
            var retained = round
            retained.setIDs = round.setIDs.map { id in id.flatMap { completed.contains($0) ? $0 : nil } }
            return retained.setIDs.contains(where: { $0 != nil }) ? retained : nil
        }
        if group.rounds.isEmpty { supersets?.remove(at: index) }
        else { supersets?[index] = group }
        if supersets?.isEmpty == true { supersets = nil }
    }

    mutating func closeSupersetsAfterSkip() {
        let unskipped = Set(exercises.filter { !$0.isSkipped }.map(\.id))
        let closing = (supersets ?? []).filter { !$0.isClosed && $0.exerciseIDs.filter(unskipped.contains).count < 2 }
        for group in closing { closeSuperset(id: group.id) }
    }

    mutating func removeSupersetLink(setID: UUID) {
        supersets = supersets?.compactMap { original in
            var group = original
            group.rounds = group.rounds.compactMap { original in
                var round = original
                round.setIDs = round.setIDs.map { $0 == setID ? nil : $0 }
                return round.setIDs.contains(where: { $0 != nil }) ? round : nil
            }
            return group.rounds.isEmpty ? nil : group
        }
        if supersets?.isEmpty == true { supersets = nil }
    }

    mutating func remapSupersets(replacing original: SessionExercise, with replacement: SessionExercise) {
        let pending = original.sets.filter { !$0.isCompleted }
        let mapping = Dictionary(uniqueKeysWithValues: zip(pending.map(\.id), replacement.sets.map(\.id)))
        for index in (supersets ?? []).indices where supersets?[index].isClosed == false {
            guard let slot = supersets?[index].exerciseIDs.firstIndex(of: original.id) else { continue }
            supersets?[index].exerciseIDs[slot] = replacement.id
            for round in supersets![index].rounds.indices {
                if let old = supersets?[index].rounds[round].setIDs[slot], let new = mapping[old] {
                    supersets?[index].rounds[round].setIDs[slot] = new
                }
            }
        }
    }

    func supersetContinuation(after setID: UUID) -> (nextExerciseID: UUID?, restSeconds: Int)? {
        guard let group = supersets?.first(where: { !$0.isClosed && $0.rounds.contains { $0.setIDs.contains(setID) } }),
              let round = group.rounds.first(where: { $0.setIDs.contains(setID) }) else { return nil }
        let pending = Set(exercises.filter { !$0.isSkipped }.flatMap(\.sets).filter { !$0.isCompleted }.map(\.id))
        for (slot, id) in round.setIDs.enumerated() where id.map(pending.contains) == true {
            return (group.exerciseIDs[slot], 0)
        }
        for future in group.rounds where future.ordinal > round.ordinal {
            for (slot, id) in future.setIDs.enumerated() where id.map(pending.contains) == true {
                return (group.exerciseIDs[slot], group.restSeconds)
            }
        }
        let next = exercises.first { !$0.isResolved }
        return (next?.id, next == nil ? 0 : group.restSeconds)
    }

    func preservesSupersetLinks(from previous: WorkoutSession) -> Bool {
        guard id == previous.id else { return true }
        guard (structureVersion ?? 0) >= (previous.structureVersion ?? 0) else { return false }
        for oldGroup in previous.supersets ?? [] {
            for oldRound in oldGroup.rounds {
                for (slot, setID) in oldRound.setIDs.enumerated() {
                    guard let setID, let oldCard = previous.exercises.first(where: { $0.sets.contains { $0.id == setID && $0.isCompleted } })
                    else { continue }
                    guard let group = supersets?.first(where: { $0.id == oldGroup.id }), !oldGroup.isClosed || group.isClosed,
                          let round = group.rounds.first(where: { $0.id == oldRound.id && $0.ordinal == oldRound.ordinal }),
                          round.setIDs.indices.contains(slot), round.setIDs[slot] == setID,
                          let card = exercises.first(where: { $0.sets.contains { $0.id == setID } }),
                          card.id == oldCard.id, card.exercise.id == oldCard.exercise.id else { return false }
                }
            }
        }
        return true
    }
}

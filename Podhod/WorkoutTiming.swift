import Foundation

enum WorkoutTimingKind: String, Codable {
    case exercise
    case rest
    case other
}

struct WorkoutTimingInterval: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: WorkoutTimingKind
    var exerciseID: UUID?
    var restKind: WorkoutRestKind?
    var startedAt: Date
    var endedAt: Date?
    var restDeadline: Date?
}

struct WorkoutExerciseTimingTotals: Equatable {
    var exerciseSeconds: TimeInterval = 0
    var restSeconds: TimeInterval = 0
}

struct WorkoutTimingTotals: Equatable {
    var exerciseSeconds: TimeInterval = 0
    var restSeconds: TimeInterval = 0
    var otherSeconds: TimeInterval = 0
    var untrackedSeconds: TimeInterval = 0
    var exercises: [UUID: WorkoutExerciseTimingTotals] = [:]
}

struct WorkoutTiming: Codable, Equatable {
    var version = 1
    var trackedFrom: Date
    var intervals: [WorkoutTimingInterval] = []

    static func eventDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func startDate(_ date: Date) -> Date {
        let rounded = eventDate(date)
        return rounded < date ? rounded.addingTimeInterval(0.001) : rounded
    }

    func boundaryDate(_ date: Date) -> Date {
        max(Self.eventDate(date), max(trackedFrom, intervals.last?.endedAt ?? intervals.last?.startedAt ?? trackedFrom))
    }

    mutating func transition(to phase: WorkoutTimingPhase?, at date: Date) {
        let now = boundaryDate(date)
        if let last = intervals.last, last.endedAt == nil {
            if let phase, last.kind == phase.kind, last.exerciseID == phase.exerciseID,
               last.restKind == phase.restKind, last.restDeadline == phase.restDeadline { return }
            if now > last.startedAt { intervals[intervals.count - 1].endedAt = now }
            else { intervals.removeLast() }
        }
        if let phase {
            intervals.append(WorkoutTimingInterval(kind: phase.kind, exerciseID: phase.exerciseID,
                restKind: phase.restKind, startedAt: now, restDeadline: phase.restDeadline))
        }
    }

    mutating func settleRest(until date: Date, fallback: WorkoutTimingPhase) {
        guard let last = intervals.last, last.endedAt == nil, last.kind == .rest,
              let deadline = last.restDeadline, date >= deadline else { return }
        transition(to: fallback, at: deadline)
    }

    func isValid(for session: WorkoutSession) -> Bool {
        guard version == 1, trackedFrom.timeIntervalSinceReferenceDate.isFinite,
              trackedFrom >= session.startedAt, session.finishedAt.map({ trackedFrom <= $0 }) ?? true,
              Set(intervals.map(\.id)).count == intervals.count else { return false }
        let exerciseIDs = Set(session.exercises.map(\.id))
        var previousEnd = trackedFrom
        for (index, interval) in intervals.enumerated() {
            guard interval.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  interval.startedAt >= previousEnd else { return false }
            if let end = interval.endedAt {
                guard end.timeIntervalSinceReferenceDate.isFinite, end >= interval.startedAt,
                      session.finishedAt.map({ end <= $0 }) ?? true else { return false }
                previousEnd = end
            } else {
                guard index == intervals.count - 1, session.finishedAt == nil else { return false }
            }
            switch interval.kind {
            case .exercise:
                guard interval.exerciseID.map(exerciseIDs.contains) == true,
                      interval.restKind == nil, interval.restDeadline == nil else { return false }
            case .rest:
                guard interval.exerciseID.map(exerciseIDs.contains) == true,
                      interval.restKind != nil, let deadline = interval.restDeadline,
                      deadline.timeIntervalSinceReferenceDate.isFinite, deadline >= interval.startedAt,
                      interval.endedAt.map({ $0 <= deadline }) ?? true else { return false }
            case .other:
                guard interval.exerciseID == nil, interval.restKind == nil, interval.restDeadline == nil else { return false }
            }
        }
        return true
    }
}

struct WorkoutTimingPhase: Equatable {
    var kind: WorkoutTimingKind
    var exerciseID: UUID?
    var restKind: WorkoutRestKind?
    var restDeadline: Date?
}

extension WorkoutSession {
    var exerciseTimingPhase: WorkoutTimingPhase {
        guard exercises.indices.contains(currentExercise), !exercises[currentExercise].isResolved else {
            return WorkoutTimingPhase(kind: .other)
        }
        return WorkoutTimingPhase(kind: .exercise, exerciseID: exercises[currentExercise].id)
    }

    func timingTotals(at date: Date = Date()) -> WorkoutTimingTotals? {
        guard let timing else { return nil }
        let until = finishedAt ?? date
        var totals = WorkoutTimingTotals()
        for interval in timing.intervals {
            let end = min(interval.endedAt ?? until, until)
            if interval.kind == .rest, let deadline = interval.restDeadline {
                let seconds = max(0, min(end, deadline).timeIntervalSince(interval.startedAt))
                totals.restSeconds += seconds
                if let id = interval.exerciseID {
                    totals.exercises[id, default: WorkoutExerciseTimingTotals()].restSeconds += seconds
                }
                if interval.endedAt == nil, end > deadline {
                    let remainder = max(0, end.timeIntervalSince(max(deadline, interval.startedAt)))
                    if let id = exerciseTimingPhase.exerciseID {
                        totals.exerciseSeconds += remainder
                        totals.exercises[id, default: WorkoutExerciseTimingTotals()].exerciseSeconds += remainder
                    } else { totals.otherSeconds += remainder }
                }
            } else {
                let seconds = max(0, end.timeIntervalSince(interval.startedAt))
                switch interval.kind {
                case .exercise:
                    totals.exerciseSeconds += seconds
                    if let id = interval.exerciseID {
                        totals.exercises[id, default: WorkoutExerciseTimingTotals()].exerciseSeconds += seconds
                    }
                case .other: totals.otherSeconds += seconds
                case .rest: break
                }
            }
        }
        let elapsed = max(0, until.timeIntervalSince(startedAt))
        totals.untrackedSeconds = max(0, elapsed - totals.exerciseSeconds - totals.restSeconds - totals.otherSeconds)
        return totals
    }
}

extension TrainingArchive {
    @discardableResult
    mutating func reconcileActiveTiming(at date: Date) -> Date {
        guard var session = active else { return date }
        var timing = session.timing ?? WorkoutTiming(trackedFrom: WorkoutTiming.startDate(max(date, session.startedAt)))
        let now = timing.boundaryDate(max(date, session.startedAt))
        timing.settleRest(until: now, fallback: session.exerciseTimingPhase)
        var phase = session.exerciseTimingPhase
        if let until = restUntil, until > now {
            let id = restExerciseID ?? session.exercises[session.currentExercise].id
            phase = WorkoutTimingPhase(kind: .rest, exerciseID: id,
                                       restKind: restKind ?? .betweenSets, restDeadline: until)
        }
        timing.transition(to: phase, at: now)
        session.timing = timing
        active = session
        return now
    }
}

func workoutTimeText(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds < Double(Int.max) else { return "—" }
    let value = max(0, Int(seconds.rounded(.down)))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

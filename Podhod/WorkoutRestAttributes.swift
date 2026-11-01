import ActivityKit
import Foundation

struct WorkoutRestAttributes: ActivityAttributes, Equatable {
    struct ContentState: Codable, Hashable {
        var deadline: Date
        var betweenExercises: Bool
    }

    let workspaceID: String
    let sessionID: UUID

    func link(_ action: WorkoutRestAction, deadline: Date) -> URL? {
        WorkoutRestLink(workspaceID: workspaceID, sessionID: sessionID,
            expectedDeadline: deadline, action: action)?.url
    }
}

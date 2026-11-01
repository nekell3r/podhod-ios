import Foundation

enum WorkoutRestAction: String, CaseIterable {
    case open, extend, stop
}

struct WorkoutRestLink: Equatable {
    let workspaceID: String
    let sessionID: UUID
    let expectedDeadline: Date
    let action: WorkoutRestAction

    init?(workspaceID: String, sessionID: UUID, expectedDeadline: Date, action: WorkoutRestAction) {
        guard workspaceID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              expectedDeadline.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(expectedDeadline.timeIntervalSince1970) else { return nil }
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.expectedDeadline = expectedDeadline
        self.action = action
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "podhod", components.host?.lowercased() == "rest",
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              components.path.hasPrefix("/"), let action = WorkoutRestAction(rawValue: String(components.path.dropFirst())),
              let items = components.queryItems, items.count == 3,
              Set(items.map(\.name)) == Set(["workspace", "session", "deadline"]),
              let workspace = items.first(where: { $0.name == "workspace" })?.value,
              let session = items.first(where: { $0.name == "session" })?.value, let id = UUID(uuidString: session),
              let deadline = items.first(where: { $0.name == "deadline" })?.value,
              let seconds = Double(deadline), seconds.isFinite else { return nil }
        self.init(workspaceID: workspace, sessionID: id,
            expectedDeadline: Date(timeIntervalSinceReferenceDate: seconds), action: action)
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "podhod"
        components.host = "rest"
        components.path = "/\(action.rawValue)"
        components.queryItems = [URLQueryItem(name: "workspace", value: workspaceID),
            URLQueryItem(name: "session", value: sessionID.uuidString),
            URLQueryItem(name: "deadline", value: String(expectedDeadline.timeIntervalSinceReferenceDate))]
        return components.url
    }

    func matches(workspaceID: String, sessionID: UUID?, deadline: Date?) -> Bool {
        self.workspaceID == workspaceID && self.sessionID == sessionID && expectedDeadline == deadline
    }
}

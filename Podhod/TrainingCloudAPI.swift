import Foundation

struct TrainingCloudFailure: LocalizedError {
    var status: Int
    var code: String
    var message: String
    var currentRevision: Int64?
    var errorDescription: String? { message }
}

private struct TrainingCloudErrorEnvelope: Decodable {
    struct Detail: Decodable { var code: String; var message: String; var currentRevision: Int64? }
    var error: Detail
}

@MainActor
struct TrainingCloudAPI {
    let auth: CloudAuthentication
    let sessionID: UUID

    init(auth: CloudAuthentication) {
        self.auth = auth
        sessionID = auth.sessionID
    }

    private static let http = URLSession(configuration: .ephemeral, delegate: CloudHTTPSRedirectPolicy(), delegateQueue: nil)

    func profile() async throws -> TrainingCloudProfile {
        try await request("GET", path: "v1/profile")
    }

    func template() async throws -> TrainingTemplateRecord {
        try await request("GET", path: "v1/template")
    }

    func saveTemplate(_ days: [TrainingDay], revision: Int64) async throws -> TrainingTemplateRecord {
        struct Change: Encodable { var expectedRevision: Int64; var requestID = UUID(); var days: [TrainingDay] }
        return try await request("PUT", path: "v1/template", body: Self.encode(Change(expectedRevision: revision, days: days)))
    }

    func week(_ key: String, timezone: String) async throws -> TrainingWeek {
        try await request("GET", path: "v1/weeks/\(key)", query: [URLQueryItem(name: "timezone", value: timezone)])
    }

    func saveWeek(_ week: TrainingWeek, revision: Int64) async throws -> TrainingWeek {
        struct Change: Encodable { var expectedRevision: Int64; var requestID = UUID(); var timezone: String; var workouts: [ScheduledWorkout] }
        return try await request("PUT", path: "v1/weeks/\(week.weekStart)", body: Self.encode(Change(expectedRevision: revision, timezone: week.timezone, workouts: week.workouts)))
    }

    func history() async throws -> [WorkoutSession] {
        struct History: Decodable { var sessions: [WorkoutSession] }
        let result: History = try await request("GET", path: "v1/history")
        return result.sessions
    }

    func saveHistory(_ session: WorkoutSession) async throws {
        struct Change: Encodable { var requestID = UUID(); var session: WorkoutSession }
        let _: WorkoutSession = try await request("PUT", path: "v1/history/\(session.id.uuidString)", body: Self.encode(Change(session: session)))
    }

    func active() async throws -> ActiveWorkoutRecord {
        try await request("GET", path: "v1/active")
    }

    func saveActive(_ state: ActiveWorkoutState?, revision: Int64) async throws -> ActiveWorkoutRecord {
        struct Change: Encodable { var expectedRevision: Int64; var requestID = UUID(); var state: ActiveWorkoutState? }
        return try await request("PUT", path: "v1/active", body: Self.encode(Change(expectedRevision: revision, state: state)))
    }

    func proteinDay(_ key: String) async throws -> ProteinDayRecord {
        try await request("GET", path: "v1/protein/\(key)")
    }

    func saveProteinDay(_ day: ProteinDayRecord, revision: Int64) async throws -> ProteinDayRecord {
        struct Change: Encodable {
            var expectedRevision: Int64
            var requestID = UUID()
            var morningTakenAt: Date?
            var eveningTakenAt: Date?
        }
        return try await request("PUT", path: "v1/protein/\(day.date)", body: Self.encode(Change(
            expectedRevision: revision, morningTakenAt: day.morningTakenAt, eveningTakenAt: day.eveningTakenAt)))
    }

    private func request<Response: Decodable>(_ method: String, path: String, body: Data? = nil,
                                              query: [URLQueryItem] = []) async throws -> Response {
        guard auth.signedIn, auth.sessionID == sessionID else { throw CancellationError() }
        let token = try await auth.accessToken()
        guard auth.signedIn, auth.sessionID == sessionID else { throw CancellationError() }
        guard var components = URLComponents(url: auth.serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url, url.scheme == "https" else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await Self.http.data(for: request)
        guard auth.signedIn, auth.sessionID == sessionID else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            let detail = try? JSONDecoder().decode(TrainingCloudErrorEnvelope.self, from: data).error
            throw TrainingCloudFailure(status: response.statusCode, code: detail?.code ?? "http_error",
                                       message: detail?.message ?? "Сервер вернул ошибку \(response.statusCode).", currentRevision: detail?.currentRevision)
        }
        return try Self.decode(Response.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid server timestamp")
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }
}

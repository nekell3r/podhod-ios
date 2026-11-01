import XCTest
@testable import PodhodCore

final class WorkoutRestLinkTests: XCTestCase {
    private let workspace = String(repeating: "a", count: 64)
    private let session = UUID()
    private let deadline = Date(timeIntervalSinceReferenceDate: 815_344_410.1234567)

    func testEveryActionPreservesExactDateAndIdentityAcrossURLRoundTrip() throws {
        for action in WorkoutRestAction.allCases {
            let request = try XCTUnwrap(WorkoutRestLink(workspaceID: workspace, sessionID: session,
                expectedDeadline: deadline, action: action))
            let decoded = try XCTUnwrap(WorkoutRestLink(url: XCTUnwrap(request.url)))
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.expectedDeadline.timeIntervalSinceReferenceDate.bitPattern,
                deadline.timeIntervalSinceReferenceDate.bitPattern)
        }
    }

    func testForeignOwnerSessionDeadlineAndReplayAreRejected() throws {
        let request = try XCTUnwrap(WorkoutRestLink(workspaceID: workspace, sessionID: session,
            expectedDeadline: deadline, action: .extend))
        XCTAssertTrue(request.matches(workspaceID: workspace, sessionID: session, deadline: deadline))
        XCTAssertFalse(request.matches(workspaceID: String(repeating: "b", count: 64), sessionID: session, deadline: deadline))
        XCTAssertFalse(request.matches(workspaceID: workspace, sessionID: UUID(), deadline: deadline))
        XCTAssertFalse(request.matches(workspaceID: workspace, sessionID: session, deadline: deadline.addingTimeInterval(30)))
        XCTAssertFalse(request.matches(workspaceID: workspace, sessionID: session, deadline: nil))
        XCTAssertFalse(request.matches(workspaceID: workspace, sessionID: nil, deadline: deadline))
    }

    func testUnknownDuplicateAndMissingParametersCannotBeCommands() throws {
        let request = try XCTUnwrap(WorkoutRestLink(workspaceID: workspace, sessionID: session,
            expectedDeadline: deadline, action: .stop))
        let address = try XCTUnwrap(request.url).absoluteString
        for changed in [address + "&session=\(session)", address + "&extra=1",
            address.replacingOccurrences(of: "workspace=", with: "unknown="),
            address.replacingOccurrences(of: "session=\(session.uuidString)", with: "session=invalid"),
            address.replacingOccurrences(of: "deadline=", with: "deadline=nan"),
            address.replacingOccurrences(of: "/stop?", with: "/stop/extra?"),
            address.replacingOccurrences(of: "/stop?", with: "/erase?"), address + "#fragment"] {
            XCTAssertNil(WorkoutRestLink(url: try XCTUnwrap(URL(string: changed))), changed)
        }
    }

    func testOtherSchemesOAuthCredentialsPortsAndInvalidDatesAreRejected() throws {
        let suffix = "?workspace=\(workspace)&session=\(session)&deadline=\(deadline.timeIntervalSinceReferenceDate)"
        for prefix in ["https://rest/stop", "podhod://oauth/callback", "podhod://user@rest/stop", "podhod://rest:80/stop"] {
            XCTAssertNil(WorkoutRestLink(url: try XCTUnwrap(URL(string: prefix + suffix))))
        }
        for invalid in [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: 253_402_300_800)] {
            XCTAssertNil(WorkoutRestLink(workspaceID: workspace, sessionID: session, expectedDeadline: invalid, action: .stop))
        }
        XCTAssertNil(WorkoutRestLink(workspaceID: "../account", sessionID: session, expectedDeadline: deadline, action: .stop))
    }
}

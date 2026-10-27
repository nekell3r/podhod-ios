import Foundation
import XCTest
@testable import PodhodCore

final class AccountWorkspacesTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Accounts-\(UUID())", directoryHint: .isDirectory)
    }

    func testLegacyFilesRemainBackedUpUnderOriginalAccount() throws {
        let root = location()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("legacy".utf8)
        try original.write(to: root.appending(path: "training.json"))
        try Data("protein".utf8).write(to: root.appending(path: "protein.json"))
        let workspaces = AccountWorkspaces(rootURL: root)
        let other = try workspaces.prepare(accountID: "user-b", legacyAccountID: "user-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appending(path: "training.json").path))
        try workspaces.commit(accountID: "user-b")
        let owner = try workspaces.prepare(accountID: "user-a", legacyAccountID: nil)
        XCTAssertEqual(try Data(contentsOf: owner.appending(path: "training.json")), original)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "training.json")), original)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appending(path: "legacy-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first).appending(path: "training.json")), original)
    }

    func testAccountsAndGuestUseIndependentDirectories() throws {
        let root = location()
        let workspaces = AccountWorkspaces(rootURL: root)
        let first = try workspaces.prepare(accountID: "user-a", legacyAccountID: nil)
        try Data("A".utf8).write(to: first.appending(path: "training.json"))
        try workspaces.commit(accountID: "user-a")
        let guest = try workspaces.prepare(accountID: nil, legacyAccountID: "user-a")
        try workspaces.commit(accountID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: guest.appending(path: "training.json").path))
        let second = try workspaces.prepare(accountID: "user-b", legacyAccountID: nil)
        XCTAssertNotEqual(first, second)
        try workspaces.commit(accountID: "user-b")
        XCTAssertEqual(AccountWorkspaces(rootURL: root).accountID, "user-b")
        XCTAssertEqual(try Data(contentsOf: first.appending(path: "training.json")), Data("A".utf8))
    }

    func testAdoptedGuestIsNotReusedForAnotherUser() throws {
        let root = location()
        let workspaces = AccountWorkspaces(rootURL: root)
        let guest = try workspaces.prepare(accountID: nil, legacyAccountID: nil)
        try workspaces.commit(accountID: nil)
        let data = Data("guest workout".utf8)
        try data.write(to: guest.appending(path: "training.json"))
        let first = try workspaces.prepare(accountID: "user-a", legacyAccountID: nil)
        try workspaces.commit(accountID: "user-a")
        XCTAssertEqual(try Data(contentsOf: first.appending(path: "training.json")), data)
        let nextGuest = try workspaces.prepare(accountID: nil, legacyAccountID: "user-a")
        try workspaces.commit(accountID: nil)
        XCTAssertNotEqual(guest, nextGuest)
        let second = try workspaces.prepare(accountID: "user-b", legacyAccountID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appending(path: "training.json").path))
        XCTAssertEqual(try Data(contentsOf: guest.appending(path: "training.json")), data)
    }

    func testCorruptSelectorCannotBeReplaced() throws {
        let root = location()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appending(path: "workspace.json")
        try Data("broken".utf8).write(to: manifest)
        let workspaces = AccountWorkspaces(rootURL: root)
        XCTAssertNotNil(workspaces.errorMessage)
        XCTAssertThrowsError(try workspaces.prepare(accountID: "user-a", legacyAccountID: nil))
        XCTAssertThrowsError(try workspaces.commit(accountID: "user-a"))
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), "broken")
    }

    @MainActor func testSwitchingAccountDoesNotCountOtherUsersTime() throws {
        let root = location()
        let store = WorkoutStore(fileURL: root.appending(path: "training.json"))
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.start(day: TrainingDay.exampleWeek()[0], date: now))
        XCTAssertTrue(store.pauseTimingForAccountSwitch(date: now.addingTimeInterval(10)))
        store.resumeAccountTiming(date: now.addingTimeInterval(100))
        let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: now.addingTimeInterval(110)))
        XCTAssertEqual(totals.exerciseSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(totals.untrackedSeconds, 90, accuracy: 0.001)
    }
}

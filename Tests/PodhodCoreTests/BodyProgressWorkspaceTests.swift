import XCTest
@testable import PodhodCore

final class BodyProgressWorkspaceTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BodyWorkspacesQA-\(UUID())")
    }

    private func writePhotos(in directory: URL) throws -> (archive: Data, first: URL, second: URL) {
        let photos = [
            BodyProgressPhoto(date: "2026-11-01", timezone: "UTC", angle: .front),
            BodyProgressPhoto(date: "2026-11-02", timezone: "UTC", angle: .side)
        ]
        let data = try JSONEncoder().encode(BodyProgressArchive(photos: photos))
        let photoDirectory = directory.appendingPathComponent("progress-photos")
        try FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("body-progress.json"))
        let first = photoDirectory.appendingPathComponent("\(photos[0].id.uuidString).jpg")
        let second = photoDirectory.appendingPathComponent("\(photos[1].id.uuidString).jpg")
        try Data("synthetic photo one".utf8).write(to: first)
        try Data("synthetic photo two".utf8).write(to: second)
        return (data, first, second)
    }

    func testGuestPhotoAdoptionRotatesGuestAndKeepsBothOriginalsAndLegacyBackup() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        let guest = try writePhotos(in: workspace.currentDirectory)
        let directory = try workspace.prepare(accountID: "owner-a", legacyAccountID: nil)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("body-progress.json")), guest.archive)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("progress-photos/\(guest.first.lastPathComponent)")), Data("synthetic photo one".utf8))
        let backups = try FileManager.default.contentsOfDirectory(at: workspace.rootURL.appendingPathComponent("legacy-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("body-progress.json")), guest.archive)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("progress-photos/\(guest.second.lastPathComponent)")), Data("synthetic photo two".utf8))
        try workspace.commit(accountID: "owner-a")
        let freshGuest = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshGuest.appendingPathComponent("body-progress.json").path))
        XCTAssertEqual(try Data(contentsOf: guest.first), Data("synthetic photo one".utf8))
        let restored = try workspace.prepare(accountID: "owner-a", legacyAccountID: nil)
        XCTAssertEqual(restored, directory)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("body-progress.json")), guest.archive)
    }

    func testInterruptedGuestPhotoAdoptionResumesOnlyMatchingFilesAndRotatesGuest() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        _ = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let guestDirectory = workspace.currentDirectory
        let guest = try writePhotos(in: guestDirectory)
        let target = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        let missing = target.appendingPathComponent("progress-photos/\(guest.second.lastPathComponent)")
        try FileManager.default.removeItem(at: missing)
        let resumed = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        XCTAssertEqual(resumed, target)
        XCTAssertEqual(try Data(contentsOf: missing), Data("synthetic photo two".utf8))
        try workspace.commit(accountID: "owner")
        let fresh = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        XCTAssertNotEqual(fresh, guestDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("body-progress.json").path))
    }

    func testExistingAccountPhotoIsNotMergedWithDifferentGuestData() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        let ownerDirectory = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        try workspace.commit(accountID: "owner")
        let owner = try writePhotos(in: ownerDirectory)
        let guestDirectory = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let guest = try writePhotos(in: guestDirectory)
        let target = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("body-progress.json")), owner.archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("progress-photos/\(guest.first.lastPathComponent)").path))
        try workspace.commit(accountID: "owner")
        let retainedGuest = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        XCTAssertEqual(retainedGuest, guestDirectory)
        XCTAssertEqual(try Data(contentsOf: guest.first), Data("synthetic photo one".utf8))
    }

    func testChangedGuestResumesOwnedTransferWithBackupInsteadOfBecomingAnotherAccount() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        let guest = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let original = try writePhotos(in: guest)
        let target = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        try Data("new synthetic photo".utf8).write(to: original.first)
        let resumed = AccountWorkspaces(rootURL: workspace.rootURL)
        XCTAssertEqual(try resumed.prepare(accountID: "owner", legacyAccountID: nil), target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("progress-photos/\(original.first.lastPathComponent)")), Data("new synthetic photo".utf8))
        let backups = try FileManager.default.contentsOfDirectory(at: workspace.rootURL.appendingPathComponent("guest-transfer-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("progress-photos/\(original.first.lastPathComponent)")), Data("synthetic photo one".utf8))
        try resumed.commit(accountID: "owner")
        let fresh = try resumed.prepare(accountID: nil, legacyAccountID: nil)
        try resumed.commit(accountID: nil)
        XCTAssertNotEqual(fresh, guest)
    }

    func testAbandonedTransferCannotExposePreviousGuestsPhotosAfterAnotherAccountAdoptsThem() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        let guest = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let original = try writePhotos(in: guest)
        let abandoned = try workspace.prepare(accountID: "owner-a", legacyAccountID: nil)
        let resumed = AccountWorkspaces(rootURL: workspace.rootURL)
        let accepted = try resumed.prepare(accountID: "owner-b", legacyAccountID: nil)
        try resumed.commit(accountID: "owner-b")
        _ = try resumed.prepare(accountID: nil, legacyAccountID: nil)
        try resumed.commit(accountID: nil)
        let reopened = try resumed.prepare(accountID: "owner-a", legacyAccountID: nil)
        XCTAssertEqual(reopened, abandoned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.appendingPathComponent("body-progress.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.appendingPathComponent("progress-photos/\(original.first.lastPathComponent)").path))
        XCTAssertEqual(try Data(contentsOf: accepted.appendingPathComponent("body-progress.json")), original.archive)
        XCTAssertEqual(try Data(contentsOf: original.first), Data("synthetic photo one".utf8))
    }

    func testCommitReceiptProtectsCompletedAdoptionWhenJournalCleanupWasInterrupted() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        let guest = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let original = try writePhotos(in: guest)
        let account = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        let journal = account.appendingPathComponent("guest-adoption.json")
        let receipt = try Data(contentsOf: journal)
        try workspace.commit(accountID: "owner")
        try receipt.write(to: journal)
        _ = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let restored = AccountWorkspaces(rootURL: workspace.rootURL)
        _ = try restored.prepare(accountID: "owner", legacyAccountID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try Data(contentsOf: account.appendingPathComponent("body-progress.json")), original.archive)
        XCTAssertEqual(try Data(contentsOf: account.appendingPathComponent("progress-photos/\(original.first.lastPathComponent)")), Data("synthetic photo one".utf8))
    }

    func testUnexpectedTargetChangeAndWrongCommitKeepBothSidesIntact() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        let guest = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let original = try writePhotos(in: guest)
        let target = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        XCTAssertThrowsError(try workspace.commit(accountID: "different"))
        XCTAssertNil(AccountWorkspaces(rootURL: workspace.rootURL).accountID)
        let changed = target.appendingPathComponent("progress-photos/\(original.first.lastPathComponent)")
        try Data("unexpected external edit".utf8).write(to: changed)
        let resumed = AccountWorkspaces(rootURL: workspace.rootURL)
        XCTAssertThrowsError(try resumed.prepare(accountID: "owner", legacyAccountID: nil))
        XCTAssertThrowsError(try resumed.commit(accountID: "owner"))
        XCTAssertEqual(try Data(contentsOf: changed), Data("unexpected external edit".utf8))
        XCTAssertEqual(try Data(contentsOf: original.first), Data("synthetic photo one".utf8))
    }

    func testSelectorV1MigrationKeepsExactBackupAndLegacyMarkerKeepsOriginalDirectory() throws {
        let directory = root()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(#"{"version":1,"accountID":"owner","guestDirectory":"guest"}"#.utf8)
        let selector = directory.appendingPathComponent("workspace.json")
        try original.write(to: selector)
        let workspace = AccountWorkspaces(rootURL: directory)
        let before = workspace.currentDirectory
        XCTAssertTrue(workspace.enablePrivateProgressStorage())
        XCTAssertEqual(workspace.currentDirectory, before)
        XCTAssertEqual(workspace.accountID, "owner")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspace-v1-backup.json")), original)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: selector)) as! [String: Any]
        XCTAssertEqual(value["version"] as? Int, 2)
        let legacy = AccountWorkspaces(rootURL: root())
        XCTAssertTrue(legacy.enablePrivateProgressStorage())
        XCTAssertTrue(legacy.isLegacy)
        XCTAssertEqual(legacy.currentDirectory, legacy.rootURL)
        XCTAssertTrue(AccountWorkspaces(rootURL: legacy.rootURL).isLegacy)
    }

    func testFutureSelectorCannotBeDowngraded() throws {
        let directory = root()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(#"{"version":3,"accountID":null}"#.utf8)
        let selector = directory.appendingPathComponent("workspace.json")
        try original.write(to: selector)
        let workspace = AccountWorkspaces(rootURL: directory)
        XCTAssertFalse(workspace.enablePrivateProgressStorage())
        XCTAssertThrowsError(try workspace.prepare(accountID: "owner", legacyAccountID: nil))
        XCTAssertEqual(try Data(contentsOf: selector), original)
    }

    func testMalformedTransferJournalCannotTraverseDirectoriesOrChangeFiles() throws {
        let workspace = AccountWorkspaces(rootURL: root())
        let guest = try workspace.prepare(accountID: nil, legacyAccountID: nil)
        try workspace.commit(accountID: nil)
        let original = try writePhotos(in: guest)
        let target = try workspace.prepare(accountID: "owner", legacyAccountID: nil)
        let journal = target.appendingPathComponent("guest-adoption.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
        value["sourceFiles"] = ["progress-photos/../../body-progress.json": String(repeating: "a", count: 64)]
        let malformed = try JSONSerialization.data(withJSONObject: value)
        try malformed.write(to: journal)
        let resumed = AccountWorkspaces(rootURL: workspace.rootURL)
        XCTAssertThrowsError(try resumed.prepare(accountID: "owner", legacyAccountID: nil))
        XCTAssertEqual(try Data(contentsOf: journal), malformed)
        XCTAssertEqual(try Data(contentsOf: original.first), Data("synthetic photo one".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("body-progress.json")), original.archive)
    }
}

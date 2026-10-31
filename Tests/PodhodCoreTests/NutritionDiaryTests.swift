import Foundation
import XCTest
@testable import PodhodCore

final class NutritionDiaryTests: XCTestCase {
    private let facts = NutritionFacts(energyKcal: 884, proteinGrams: 0, fatGrams: 100, carbohydrateGrams: 0)
    private let target = NutritionFacts(energyKcal: 2000, proteinGrams: 100, fatGrams: 80, carbohydrateGrams: 220)

    private func entry(grams: Double = 10) -> NutritionDiaryEntry {
        NutritionDiaryEntry(meal: .lunch, grams: grams, food: NutritionFoodSnapshot(name: "Масло", per100Grams: facts))
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "NutritionDiary-\(UUID())/nutrition.json")
    }

    func testSnapshotTotalsKeepSourceEnergyAndZeroValues() throws {
        let oil = entry()
        let water = NutritionDiaryEntry(meal: .breakfast, grams: 300,
            food: NutritionFoodSnapshot(name: "Вода", per100Grams: .zero))
        let day = NutritionDayDocument(date: "2026-10-31", timezone: "Europe/Moscow", entries: [oil, water])
        XCTAssertTrue(day.isValid)
        XCTAssertEqual(try XCTUnwrap(day.totals).energyKcal, 88.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(day.totals).fatGrams, 10)
        XCTAssertEqual(day.totals(for: .breakfast), .zero)
        XCTAssertEqual(day.totals(for: .dinner), .zero)
        XCTAssertNotEqual(day.totals?.energyKcal, 90)
    }

    func testMissingOrNullFactsFailDecodingInsteadOfBecomingZero() {
        let missing = #"{"energyKcal":0,"proteinGrams":0,"fatGrams":0}"#
        let null = #"{"energyKcal":null,"proteinGrams":0,"fatGrams":0,"carbohydrateGrams":0}"#
        for json in [missing, null] {
            XCTAssertThrowsError(try JSONDecoder().decode(NutritionFacts.self, from: Data(json.utf8)))
        }
    }

    func testDomainBoundsAndExactOrigins() {
        XCTAssertFalse(entry(grams: 0).isValid)
        XCTAssertFalse(entry(grams: .infinity).isValid)
        XCTAssertFalse(entry(grams: 100_001).isValid)
        XCTAssertTrue(entry(grams: 100_000).isValid)
        XCTAssertFalse(NutritionOrigin(kind: .catalogFood, id: "usda-001", catalogVersion: "v1").isValid)
        XCTAssertFalse(NutritionOrigin(kind: .catalogFood, id: "171413", catalogVersion: "v1").isValid)
        XCTAssertFalse(NutritionOrigin(kind: .manual, id: "usda-171413", catalogVersion: "").isValid)
        XCTAssertTrue(NutritionOrigin(kind: .catalogFood, id: "usda-171413", catalogVersion: "v1").isValid)
        for date in ["2026-02-30", "1899-12-31", "2026-1-01"] {
            XCTAssertFalse(NutritionDayDocument(date: date, timezone: "UTC").isValid)
        }
        for timezone in ["", "Local", "Wrong/Timezone"] {
            XCTAssertFalse(NutritionDayDocument(date: "2026-10-31", timezone: timezone).isValid)
        }
        let duplicate = entry()
        XCTAssertFalse(NutritionDayDocument(date: "2026-10-31", timezone: "UTC", entries: [duplicate, duplicate]).isValid)
        XCTAssertFalse(NutritionPreferencesDocument(favoriteFoodIDs: [" usda-171413"]).isValid)
    }

    func testOwnRecipeUsesReadyMassAndRetainsIndependentDiarySnapshot() throws {
        var recipe = NutritionOwnRecipe(name: "Масло с водой", category: .snack, minutes: 1, servings: 2,
            preparedWeightGrams: 200, ingredients: [NutritionRecipeIngredient(grams: 10,
                food: NutritionFoodSnapshot(name: "Масло", per100Grams: facts))], steps: ["Смешать"])
        XCTAssertTrue(recipe.isValid)
        XCTAssertEqual(try XCTUnwrap(recipe.per100Grams).energyKcal, 44.2, accuracy: 0.0001)
        XCTAssertEqual(recipe.perServing, recipe.per100Grams)
        let saved = NutritionDiaryEntry(meal: .snack, grams: 100, food: try XCTUnwrap(recipe.snapshot))
        recipe.ingredients[0].grams = 20
        recipe.name = "Новый рецепт"
        XCTAssertEqual(try XCTUnwrap(saved.amount).energyKcal, 44.2, accuracy: 0.0001)
        XCTAssertEqual(saved.food.name, "Масло с водой")
        XCTAssertEqual(saved.food.origin.id, recipe.id.uuidString)
        recipe.preparedWeightGrams = 1
        XCTAssertFalse(recipe.isValid)
        XCTAssertNil(recipe.snapshot)
    }

    func testPendingRetryIsIdenticalAcrossEditsAndRelaunch() throws {
        var state = RevisionedDocumentState(localDocument: NutritionPreferencesDocument(favoriteFoodIDs: ["first"]))
        let original = try XCTUnwrap(state.pending)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalBytes = try encoder.encode(original)
        state.edit(NutritionPreferencesDocument(favoriteFoodIDs: ["second"]))
        let recovered = try JSONDecoder().decode(RevisionedDocumentState<NutritionPreferencesDocument>.self,
            from: JSONEncoder().encode(state))
        XCTAssertEqual(recovered.pending, original)
        XCTAssertEqual(try encoder.encode(try XCTUnwrap(recovered.pending)), originalBytes)
        try state.acknowledge(requestID: original.requestID,
            record: RevisionedDocumentRecord(revision: 1, document: original.document))
        let next = try XCTUnwrap(state.pending)
        XCTAssertEqual(next.expectedRevision, 1)
        XCTAssertNotEqual(next.requestID, original.requestID)
        XCTAssertEqual(next.document.favoriteFoodIDs, ["second"])
        XCTAssertEqual(state.document.favoriteFoodIDs, ["second"])
    }

    func testAcknowledgingOldRequestDoesNotResurrectDeletedData() throws {
        let populated = NutritionPreferencesDocument(favoriteFoodIDs: ["first"])
        var state = RevisionedDocumentState(localDocument: populated)
        let original = try XCTUnwrap(state.pending)
        state.edit(NutritionPreferencesDocument())
        try state.acknowledge(requestID: original.requestID, record: RevisionedDocumentRecord(revision: 1, document: populated))
        let deletion = try XCTUnwrap(state.pending)
        try state.acknowledge(requestID: deletion.requestID,
            record: RevisionedDocumentRecord(revision: 2, document: NutritionPreferencesDocument()))
        try state.acknowledge(requestID: original.requestID, record: RevisionedDocumentRecord(revision: 1, document: populated))
        try state.receive(RevisionedDocumentRecord(revision: 1, document: populated))
        XCTAssertEqual(state.acknowledged?.revision, 2)
        XCTAssertTrue(state.document.favoriteFoodIDs.isEmpty)
        XCTAssertNil(state.pending)
    }

    func testStaleReceiptKeepsNewerConflictAndLocalEdits() throws {
        var state = RevisionedDocumentState(localDocument: NutritionPreferencesDocument(favoriteFoodIDs: ["first"]))
        let original = try XCTUnwrap(state.pending)
        state.edit(NutritionPreferencesDocument(favoriteFoodIDs: ["latest local"]))
        let latest = RevisionedDocumentRecord(revision: 8, document: NutritionPreferencesDocument())
        try state.receive(latest)
        try state.acknowledge(requestID: original.requestID, record: RevisionedDocumentRecord(revision: 1, document: original.document))
        XCTAssertEqual(state.conflict, latest)
        XCTAssertEqual(state.document.favoriteFoodIDs, ["latest local"])
        XCTAssertNil(state.pending)
    }

    func testConcurrentChangesRequireExplicitChoiceAndNewRequestID() throws {
        let empty = NutritionPreferencesDocument()
        var state = RevisionedDocumentState(document: empty)
        try state.receive(RevisionedDocumentRecord(revision: 4, document: empty))
        state.edit(NutritionPreferencesDocument(favoriteRecipeIDs: ["local"]))
        let pending = try XCTUnwrap(state.pending)
        let remote = RevisionedDocumentRecord(revision: 5, document: NutritionPreferencesDocument(favoriteRecipeIDs: ["server"]))
        try state.receive(remote)
        XCTAssertEqual(state.document.favoriteRecipeIDs, ["local"])
        XCTAssertEqual(state.conflict, remote)
        XCTAssertThrowsError(try state.resolve(usingServer: false, expected: RevisionedDocumentRecord(revision: 4, document: empty)))
        try state.resolve(usingServer: false, expected: remote)
        XCTAssertNil(state.conflict)
        XCTAssertEqual(state.pending?.expectedRevision, 5)
        XCTAssertNotEqual(state.pending?.requestID, pending.requestID)
        XCTAssertEqual(state.pending?.document.favoriteRecipeIDs, ["local"])
    }

    @MainActor func testStoreAtomicallyRestoresLocalEditsAndExactPendingRequest() throws {
        let url = location()
        let store = NutritionDiaryStore(fileURL: url)
        let first = entry()
        XCTAssertTrue(store.saveEntry(first, on: "2026-10-31", timezone: "Europe/Moscow"))
        let pending = try XCTUnwrap(store.archive.days.first?.pending)
        XCTAssertTrue(store.removeEntry(first.id, on: "2026-10-31"))
        let loaded = NutritionDiaryStore(fileURL: url)
        XCTAssertFalse(loaded.loadFailed)
        XCTAssertTrue(try XCTUnwrap(loaded.archive.days.first).document.entries.isEmpty)
        XCTAssertEqual(loaded.archive.days.first?.pending, pending)
        XCTAssertTrue(loaded.acknowledgeDay(requestID: pending.requestID,
            record: RevisionedDocumentRecord(revision: 1, document: pending.document)))
        XCTAssertTrue(try XCTUnwrap(loaded.archive.days.first?.pending).document.entries.isEmpty)
        XCTAssertEqual(loaded.archive.days.first?.pending?.expectedRevision, 1)
        XCTAssertEqual(NutritionDiaryStore(fileURL: url).archive, loaded.archive)
    }

    @MainActor func testGoalsApplyOnlyAtFirstWriteIncludingDaysReadBeforehand() throws {
        let store = NutritionDiaryStore(fileURL: location())
        let key = "2026-10-31"
        let absent = NutritionDayDocument(date: key, timezone: "UTC")
        XCTAssertTrue(store.receiveDay(RevisionedDocumentRecord(revision: 0, document: absent)))
        let goal = NutritionGoal(effectiveFrom: key, timezone: "Europe/Moscow", target: target)
        XCTAssertTrue(store.saveGoal(goal))
        XCTAssertTrue(store.saveEntry(entry(), on: key, timezone: "Europe/Moscow"))
        var nextGoal = goal
        nextGoal.target = NutritionFacts(energyKcal: 2200, proteinGrams: 120, fatGrams: 80, carbohydrateGrams: 240)
        XCTAssertTrue(store.saveGoal(nextGoal))
        let saved = store.day(key, timezone: "America/New_York")
        XCTAssertEqual(saved.timezone, "Europe/Moscow")
        XCTAssertEqual(saved.goal, goal)
        XCTAssertEqual(store.day("2026-11-01", timezone: "Europe/Moscow").goal, nextGoal)
        var invalid = saved
        invalid.goal = nextGoal
        XCTAssertFalse(store.saveDay(invalid))
        invalid = saved
        invalid.timezone = "UTC"
        XCTAssertFalse(store.saveDay(invalid))
        XCTAssertEqual(store.day(key, timezone: "UTC"), saved)
    }

    @MainActor func testExplicitEmptyDayFreezesAbsenceOfGoal() throws {
        let store = NutritionDiaryStore(fileURL: location())
        let key = "2026-10-31"
        XCTAssertTrue(store.saveDay(NutritionDayDocument(date: key, timezone: "UTC")))
        let pending = try XCTUnwrap(store.archive.days.first?.pending)
        XCTAssertTrue(pending.document.entries.isEmpty)
        XCTAssertTrue(store.saveGoal(NutritionGoal(effectiveFrom: key, timezone: "UTC", target: target)))
        XCTAssertNil(store.day(key, timezone: "UTC").goal)
        XCTAssertTrue(store.acknowledgeDay(requestID: pending.requestID,
            record: RevisionedDocumentRecord(revision: 1, document: pending.document)))
        XCTAssertNil(store.day(key, timezone: "UTC").goal)
    }

    @MainActor func testConflictBackupAndServerChoicePreserveBothSides() throws {
        let url = location()
        let store = NutritionDiaryStore(fileURL: url)
        XCTAssertTrue(store.saveEntry(entry(), on: "2026-10-31", timezone: "Europe/Moscow"))
        let remote = RevisionedDocumentRecord(revision: 2, document: NutritionDayDocument(date: "2026-10-31", timezone: "UTC"))
        XCTAssertTrue(store.receiveDay(remote))
        XCTAssertFalse(store.resolveDay("2026-10-31", usingServer: false, expected: remote))
        XCTAssertTrue(store.resolveDay("2026-10-31", usingServer: true, expected: remote))
        XCTAssertEqual(store.archive.days.first?.document, remote.document)
        XCTAssertNil(store.archive.days.first?.pending)
        let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent().appending(path: "NutritionConflicts"), includingPropertiesForKeys: nil)
        let backup = try JSONDecoder().decode(NutritionDiaryArchive.self, from: Data(contentsOf: XCTUnwrap(backups.first)))
        XCTAssertEqual(backup.days.first?.document.entries.count, 1)
        XCTAssertEqual(backup.days.first?.conflict, remote)
    }

    @MainActor func testMigrationBacksUpFavoritesAndKeepsUnknownIDs() throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = url.deletingLastPathComponent().appending(path: "nutrition-preferences.json")
        let bytes = Data(#"{"version":1,"favoriteRecipeIDs":["unknown-recipe"],"favoriteFoodIDs":["future-food"]}"#.utf8)
        try bytes.write(to: legacy)
        let store = NutritionDiaryStore(fileURL: url)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.archive.preferences.document.favoriteRecipeIDs, ["unknown-recipe"])
        XCTAssertEqual(store.archive.preferences.pending?.expectedRevision, 0)
        let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent().appending(path: "NutritionBackups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first).appending(path: "nutrition-preferences.v1.json")), bytes)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(NutritionDiaryStore(fileURL: url).archive, store.archive)
    }

    @MainActor func testCorruptFutureAndBlockedFilesCannotBeOverwritten() throws {
        for data in [Data("broken".utf8), try JSONEncoder().encode(NutritionDiaryArchive(version: 9))] {
            let url = location()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            let store = NutritionDiaryStore(fileURL: url)
            XCTAssertTrue(store.loadFailed)
            XCTAssertFalse(store.saveEntry(entry(), on: "2026-10-31", timezone: "UTC"))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        let store = NutritionDiaryStore(fileURL: location())
        store.accountStorageError = "Broken selector"
        XCTAssertFalse(store.saveEntry(entry(), on: "2026-10-31", timezone: "UTC"))
        XCTAssertTrue(store.archive.days.isEmpty)
        let blocker = location()
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocker)
        let blocked = NutritionDiaryStore(fileURL: blocker.appending(path: "nutrition.json"))
        XCTAssertFalse(blocked.saveEntry(entry(), on: "2026-10-31", timezone: "UTC"))
        XCTAssertTrue(blocked.archive.days.isEmpty)
    }

    func testRejectedRequestAtSameRevisionStillNeedsExplicitChoice() throws {
        var state = RevisionedDocumentState(localDocument: NutritionPreferencesDocument(favoriteFoodIDs: ["local"]))
        let pending = try XCTUnwrap(state.pending)
        let remote = RevisionedDocumentRecord(revision: 0, document: NutritionPreferencesDocument())
        try state.reject(requestID: pending.requestID, remote: remote)
        XCTAssertEqual(state.conflict, remote)
        XCTAssertEqual(state.pending, pending)
        try state.resolve(usingServer: false, expected: remote)
        XCTAssertNotEqual(state.pending?.requestID, pending.requestID)
        XCTAssertEqual(state.pending?.document, pending.document)
    }

    @MainActor func testStaleEntryEditorCannotReplaceNewerEntryOrDeletedRecipe() throws {
        let store = NutritionDiaryStore(fileURL: location())
        let first = entry()
        XCTAssertTrue(store.saveEntry(first, on: "2026-10-31", timezone: "UTC"))
        var newer = first
        newer.grams = 20
        XCTAssertTrue(store.saveEntry(newer, on: "2026-10-31", timezone: "UTC", expected: first))
        XCTAssertFalse(store.saveEntry(first, on: "2026-10-31", timezone: "UTC", expected: first))
        XCTAssertFalse(store.removeEntry(first.id, on: "2026-10-31", expected: first))
        XCTAssertEqual(store.archive.days.first?.document.entries.first, newer)
        let recipe = NutritionOwnRecipe(name: "Масло", category: .snack, minutes: 1, servings: 1, preparedWeightGrams: 100,
            ingredients: [NutritionRecipeIngredient(grams: 100, food: first.food)], steps: ["Подать"])
        XCTAssertTrue(store.saveRecipe(recipe))
        XCTAssertTrue(store.removeRecipe(recipe.id))
        XCTAssertFalse(store.saveRecipe(recipe, expected: recipe))
        XCTAssertTrue(store.archive.recipes.document.recipes.isEmpty)
    }

    @MainActor func testFavoritesAdapterWritesSameAtomicArchiveAndSeesRemoteChanges() throws {
        let store = NutritionDiaryStore(fileURL: location())
        let preferences = NutritionPreferences(diary: store)
        XCTAssertTrue(preferences.setFavoriteFood("usda-171413", favorite: true))
        XCTAssertEqual(store.archive.preferences.pending?.document.favoriteFoodIDs, ["usda-171413"])
        let pending = try XCTUnwrap(store.archive.preferences.pending)
        XCTAssertTrue(store.acknowledge(requestID: pending.requestID,
            record: RevisionedDocumentRecord(revision: 1, document: pending.document), at: \.preferences))
        XCTAssertTrue(store.receive(RevisionedDocumentRecord(revision: 2,
            document: NutritionPreferencesDocument(favoriteRecipeIDs: ["from another device"])), at: \.preferences))
        XCTAssertTrue(preferences.favoriteFoodIDs.isEmpty)
        XCTAssertEqual(preferences.favoriteRecipeIDs, ["from another device"])
        XCTAssertEqual(NutritionDiaryStore(fileURL: store.fileURL).archive, store.archive)
    }

    @MainActor func testAccountBindingAndBrokenSelectorPreventMigrationWrites() throws {
        let url = location()
        let store = NutritionDiaryStore(fileURL: url)
        XCTAssertTrue(store.bindAccount("owner"))
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(store.bindAccount("other"))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(NutritionDiaryStore(fileURL: url).archive.accountID, "owner")
        let blockedURL = location()
        let directory = blockedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appending(path: "nutrition-preferences.json")
        let legacyBytes = Data(#"{"version":1,"favoriteRecipeIDs":["original"],"favoriteFoodIDs":[]}"#.utf8)
        try legacyBytes.write(to: legacy)
        let blocked = NutritionDiaryStore(fileURL: blockedURL, accountStorageError: "Broken selector")
        XCTAssertTrue(blocked.loadFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedURL.path))
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
    }

    @MainActor func testNutritionOnlyGuestAdoptionCanResumeAndRotatesGuest() throws {
        let root = location().deletingLastPathComponent()
        let workspaces = AccountWorkspaces(rootURL: root)
        let guest = try workspaces.prepare(accountID: nil, legacyAccountID: nil)
        try workspaces.commit(accountID: nil)
        let store = NutritionDiaryStore(fileURL: guest.appending(path: "nutrition.json"))
        XCTAssertTrue(store.saveEntry(entry(), on: "2026-10-31", timezone: "UTC"))
        let account = try workspaces.prepare(accountID: "owner", legacyAccountID: nil)
        let resumed = AccountWorkspaces(rootURL: root)
        XCTAssertEqual(try resumed.prepare(accountID: "owner", legacyAccountID: nil), account)
        try resumed.commit(accountID: "owner")
        let nextGuest = try resumed.prepare(accountID: nil, legacyAccountID: "owner")
        try resumed.commit(accountID: nil)
        XCTAssertNotEqual(guest, nextGuest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextGuest.appending(path: "nutrition.json").path))
        XCTAssertEqual(try Data(contentsOf: account.appending(path: "nutrition.json")), try Data(contentsOf: guest.appending(path: "nutrition.json")))
        let other = try resumed.prepare(accountID: "other", legacyAccountID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appending(path: "nutrition.json").path))
    }

    func testExportRangeUsesCalendarDaysAcrossDSTAndBounds() throws {
        let range = try NutritionExportRange(from: "2026-10-31", through: "2026-11-02", timezone: "America/New_York")
        XCTAssertEqual(range.dayKeys, ["2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(try NutritionExportRange(from: "2024-01-01", through: "2024-12-31", timezone: "UTC").dayKeys.count, 366)
        XCTAssertThrowsError(try NutritionExportRange(from: "2024-01-01", through: "2025-01-01", timezone: "UTC"))
        XCTAssertThrowsError(try NutritionExportRange(from: "2026-11-02", through: "2026-11-01", timezone: "UTC"))
        XCTAssertThrowsError(try NutritionExportRange(from: "2026-02-30", through: "2026-03-01", timezone: "UTC"))
        XCTAssertThrowsError(try NutritionExportRange(from: "2026-01-01", through: "2026-01-01", timezone: "Local"))
        XCTAssertEqual(try NutritionExportRange(from: "9999-12-31", through: "9999-12-31", timezone: "UTC").dayKeys, ["9999-12-31"])
    }

    @MainActor func testMissingPendingForDirtyCheckpointIsProtectedAsCorrupt() throws {
        var state = RevisionedDocumentState(document: NutritionPreferencesDocument())
        try state.receive(RevisionedDocumentRecord(revision: 2, document: NutritionPreferencesDocument()))
        state.edit(NutritionPreferencesDocument(favoriteFoodIDs: ["local edit"]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "pending")
        let broken = try JSONDecoder().decode(RevisionedDocumentState<NutritionPreferencesDocument>.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(broken.isValid(documentIsValid: { $0.isValid }))
        var archive = NutritionDiaryArchive()
        archive.preferences = broken
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(archive)
        try bytes.write(to: url)
        let store = NutritionDiaryStore(fileURL: url)
        XCTAssertTrue(store.loadFailed)
        XCTAssertFalse(store.savePreferences(NutritionPreferencesDocument()))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testDifferentDocumentsAtSameRevisionCannotClearConflictOnReceipt() throws {
        var state = RevisionedDocumentState(localDocument: NutritionPreferencesDocument(favoriteFoodIDs: ["local"]))
        let pending = try XCTUnwrap(state.pending)
        let remote = RevisionedDocumentRecord(revision: 1, document: NutritionPreferencesDocument(favoriteFoodIDs: ["other"]))
        try state.receive(remote)
        XCTAssertThrowsError(try state.acknowledge(requestID: pending.requestID,
            record: RevisionedDocumentRecord(revision: 1, document: pending.document)))
        XCTAssertEqual(state.conflict, remote)
        XCTAssertEqual(state.pending, pending)
        XCTAssertEqual(state.document.favoriteFoodIDs, ["local"])
    }

    @MainActor func testStaleDeleteConfirmationPreservesNewerGoalAndRecipe() throws {
        let store = NutritionDiaryStore(fileURL: location())
        let goal = NutritionGoal(effectiveFrom: "2026-10-31", timezone: "UTC", target: target)
        XCTAssertTrue(store.saveGoal(goal))
        let goalPending = try XCTUnwrap(store.archive.goals.pending)
        XCTAssertTrue(store.acknowledge(requestID: goalPending.requestID,
            record: RevisionedDocumentRecord(revision: 1, document: goalPending.document), at: \.goals))
        var newerGoal = goal
        newerGoal.target = NutritionFacts(energyKcal: 2200, proteinGrams: 120, fatGrams: 80, carbohydrateGrams: 230)
        XCTAssertTrue(store.receive(RevisionedDocumentRecord(revision: 2,
            document: NutritionGoalsDocument(goals: [newerGoal])), at: \.goals))
        XCTAssertFalse(store.removeGoal(goal.id, expected: goal))
        XCTAssertEqual(store.archive.goals.document.goals, [newerGoal])
        let recipe = NutritionOwnRecipe(name: "Масло", category: .snack, minutes: 1, servings: 1, preparedWeightGrams: 100,
            ingredients: [NutritionRecipeIngredient(grams: 100, food: entry().food)], steps: ["Подать"])
        XCTAssertTrue(store.saveRecipe(recipe))
        let recipePending = try XCTUnwrap(store.archive.recipes.pending)
        XCTAssertTrue(store.acknowledge(requestID: recipePending.requestID,
            record: RevisionedDocumentRecord(revision: 1, document: recipePending.document), at: \.recipes))
        var newerRecipe = recipe
        newerRecipe.name = "Новое название"
        XCTAssertTrue(store.receive(RevisionedDocumentRecord(revision: 2,
            document: NutritionRecipesDocument(recipes: [newerRecipe])), at: \.recipes))
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertFalse(store.removeRecipe(recipe.id, expected: recipe))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertEqual(store.archive.recipes.document.recipes, [newerRecipe])
    }

    @MainActor func testGuestExportKeepsSnapshotsAndDoesNotInventGoalsForUnwrittenDays() throws {
        let store = NutritionDiaryStore(fileURL: location())
        XCTAssertTrue(store.saveEntry(entry(), on: "2026-10-31", timezone: "Europe/Moscow"))
        XCTAssertTrue(store.saveGoal(NutritionGoal(effectiveFrom: "2026-10-31", timezone: "UTC", target: target)))
        let range = try NutritionExportRange(from: "2026-10-31", through: "2026-11-01", timezone: "UTC")
        let archiveBefore = store.archive
        let report = try store.exportGuestDays(range)
        XCTAssertEqual(report.source, "local-guest")
        XCTAssertEqual(report.days.count, 2)
        XCTAssertEqual(report.days[0].document.timezone, "Europe/Moscow")
        XCTAssertEqual(report.days[0].document.entries, archiveBefore.days[0].document.entries)
        XCTAssertNil(report.days[0].document.goal)
        XCTAssertTrue(report.days[1].document.entries.isEmpty)
        XCTAssertNil(report.days[1].document.goal)
        XCTAssertEqual(store.archive, archiveBefore)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "local-guest")
        XCTAssertTrue(store.bindAccount("owner"))
        XCTAssertThrowsError(try store.exportGuestDays(range))
    }

    @MainActor func testConflictImmediatelyBacksUpBothSidesBeforeFurtherLocalEdits() throws {
        let store = NutritionDiaryStore(fileURL: location())
        let first = entry()
        XCTAssertTrue(store.saveEntry(first, on: "2026-10-31", timezone: "UTC"))
        var changed = first
        changed.grams = 20
        XCTAssertTrue(store.saveEntry(changed, on: "2026-10-31", timezone: "UTC", expected: first))
        let sent = try XCTUnwrap(store.archive.days.first?.pending)
        let remote = RevisionedDocumentRecord(revision: 1, document: NutritionDayDocument(date: "2026-10-31", timezone: "UTC"))
        XCTAssertTrue(store.rejectDay(requestID: sent.requestID, record: remote))
        let directory = store.fileURL.deletingLastPathComponent().appending(path: "NutritionConflicts")
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let bytes = try Data(contentsOf: XCTUnwrap(backups.first))
        let backup = try JSONDecoder().decode(NutritionDiaryArchive.self, from: bytes)
        XCTAssertEqual(backup.days.first?.document.entries.first?.grams, 20)
        XCTAssertEqual(backup.days.first?.pending, sent)
        XCTAssertEqual(backup.days.first?.conflict, remote)
        var newest = changed
        newest.grams = 30
        XCTAssertTrue(store.saveEntry(newest, on: "2026-10-31", timezone: "UTC", expected: changed))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
        XCTAssertEqual(store.archive.days.first?.document.entries.first?.grams, 30)
    }

    func testUnicodeTextBoundsMatchServerCodePoints() {
        let name = String(repeating: "👨‍👩‍👧‍👦", count: 30)
        XCTAssertLessThan(name.count, 200)
        XCTAssertGreaterThan(name.unicodeScalars.count, 200)
        XCTAssertFalse(NutritionFoodSnapshot(name: name, per100Grams: .zero).isValid)
        XCTAssertFalse(NutritionPreferencesDocument(favoriteRecipeIDs: [name]).isValid)
        let recipe = NutritionOwnRecipe(name: "Вода", category: .snack, minutes: 1, servings: 1, preparedWeightGrams: 100,
            ingredients: [NutritionRecipeIngredient(grams: 100, food: NutritionFoodSnapshot(name: "Вода", per100Grams: .zero))],
            steps: [String(repeating: "a\u{0301}", count: 1001)])
        XCTAssertFalse(recipe.isValid)
    }

    @MainActor func testUnchangedServerReadDoesNotRewriteLocalArchive() throws {
        let store = NutritionDiaryStore(fileURL: location())
        let remote = RevisionedDocumentRecord(revision: 4, document: NutritionGoalsDocument())
        XCTAssertTrue(store.receive(remote, at: \.goals))
        let previous = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: previous], ofItemAtPath: store.fileURL.path)
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertTrue(store.receive(remote, at: \.goals))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, previous)
    }
}

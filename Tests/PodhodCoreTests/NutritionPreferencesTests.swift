import XCTest
@testable import PodhodCore

final class NutritionPreferencesTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "NutritionPreferencesTests-\(UUID())/nutrition-preferences.json")
    }

    @MainActor func testFavoritesPersistAndDifferentAccountsRemainIndependent() async throws {
        let firstURL = location()
        let secondURL = location()
        let first = NutritionPreferences(fileURL: firstURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(first.setFavoriteRecipe("banana-oatmeal", favorite: true))
        XCTAssertTrue(first.setFavoriteFood("usda-171413", favorite: true))
        let reloaded = NutritionPreferences(fileURL: firstURL)
        XCTAssertEqual(reloaded.favoriteRecipeIDs, ["banana-oatmeal"])
        XCTAssertEqual(reloaded.favoriteFoodIDs, ["usda-171413"])
        let other = NutritionPreferences(fileURL: secondURL)
        XCTAssertTrue(other.favoriteRecipeIDs.isEmpty)
        XCTAssertTrue(reloaded.setFavoriteRecipe("banana-oatmeal", favorite: false))
        XCTAssertTrue(NutritionPreferences(fileURL: firstURL).favoriteRecipeIDs.isEmpty)
        XCTAssertEqual(NutritionPreferences(fileURL: firstURL).favoriteFoodIDs, ["usda-171413"])
    }

    @MainActor func testCorruptAndFutureFilesCannotBeOverwrittenAndUnknownFavoritesAreRetained() async throws {
        for data in [Data("broken".utf8), Data(#"{"version":2,"favoriteRecipeIDs":[],"favoriteFoodIDs":[]}"#.utf8),
                     Data(#"{"version":1,"favoriteRecipeIDs":["duplicate","duplicate"],"favoriteFoodIDs":[]}"#.utf8)] {
            let url = location()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            let preferences = NutritionPreferences(fileURL: url)
            XCTAssertTrue(preferences.loadFailed)
            XCTAssertFalse(preferences.setFavoriteRecipe("new", favorite: true))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        let url = location()
        let preferences = NutritionPreferences(fileURL: url)
        XCTAssertTrue(preferences.setFavoriteRecipe("not-in-this-catalog-anymore", favorite: true))
        XCTAssertEqual(NutritionPreferences(fileURL: url).favoriteRecipeIDs, ["not-in-this-catalog-anymore"])
    }

    @MainActor func testWriteFailureAndAccountProtectionLeaveMemoryAndDiskUnchanged() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocking parent".utf8).write(to: url)
        let blocked = NutritionPreferences(fileURL: url.appending(path: "file.json"))
        XCTAssertFalse(blocked.setFavoriteFood("usda-17", favorite: true))
        XCTAssertTrue(blocked.favoriteFoodIDs.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "blocking parent")
        let protectedURL = location()
        let protected = NutritionPreferences(fileURL: protectedURL)
        protected.accountStorageError = "Broken account selector"
        XCTAssertFalse(protected.setFavoriteRecipe("new", favorite: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: protectedURL.path))
    }

    @MainActor func testCombinedFavoritesLimitPreservesPreviouslySavedData() async throws {
        let url = location()
        let recipes = (0..<499).map { "recipe-\($0)" }
        let document: [String: Any] = ["version": 1, "favoriteRecipeIDs": recipes, "favoriteFoodIDs": ["usda-171413"]]
        let data = try JSONSerialization.data(withJSONObject: document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let preferences = NutritionPreferences(fileURL: url)
        XCTAssertFalse(preferences.loadFailed)
        XCTAssertFalse(preferences.setFavoriteFood("usda-174158", favorite: true))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertTrue(preferences.setFavoriteRecipe("recipe-0", favorite: false))
        XCTAssertTrue(preferences.setFavoriteFood("usda-174158", favorite: true))
        XCTAssertEqual(preferences.favoriteRecipeIDs.count + preferences.favoriteFoodIDs.count, 500)
    }

    func testGuestFavoritesAdoptionRotatesGuestAndDoesNotOverwriteExistingAccount() throws {
        let root = location().deletingLastPathComponent()
        let workspaces = AccountWorkspaces(rootURL: root)
        let guest = try workspaces.prepare(accountID: nil, legacyAccountID: nil)
        try workspaces.commit(accountID: nil)
        let favorites = Data(#"{"version":1,"favoriteRecipeIDs":["guest-recipe"],"favoriteFoodIDs":[]}"#.utf8)
        try favorites.write(to: guest.appending(path: "nutrition-preferences.json"))
        let first = try workspaces.prepare(accountID: "first", legacyAccountID: nil)
        try workspaces.commit(accountID: "first")
        XCTAssertEqual(try Data(contentsOf: first.appending(path: "nutrition-preferences.json")), favorites)
        let nextGuest = try workspaces.prepare(accountID: nil, legacyAccountID: "first")
        try workspaces.commit(accountID: nil)
        XCTAssertNotEqual(guest, nextGuest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextGuest.appending(path: "nutrition-preferences.json").path))
        try Data("different guest favorites".utf8).write(to: nextGuest.appending(path: "nutrition-preferences.json"))
        let existing = try workspaces.prepare(accountID: "first", legacyAccountID: nil)
        XCTAssertEqual(try Data(contentsOf: existing.appending(path: "nutrition-preferences.json")), favorites)
        XCTAssertEqual(try String(contentsOf: nextGuest.appending(path: "nutrition-preferences.json"), encoding: .utf8), "different guest favorites")
    }

    func testLegacyFavoritesAreBackedUpWithTheirOriginalOwner() throws {
        let root = location().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let favorites = Data("legacy favorites".utf8)
        try favorites.write(to: root.appending(path: "nutrition-preferences.json"))
        let workspaces = AccountWorkspaces(rootURL: root)
        let other = try workspaces.prepare(accountID: "other", legacyAccountID: "owner")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appending(path: "nutrition-preferences.json").path))
        try workspaces.commit(accountID: "other")
        let owner = try workspaces.prepare(accountID: "owner", legacyAccountID: nil)
        XCTAssertEqual(try Data(contentsOf: owner.appending(path: "nutrition-preferences.json")), favorites)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appending(path: "legacy-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first).appending(path: "nutrition-preferences.json")), favorites)
    }
}

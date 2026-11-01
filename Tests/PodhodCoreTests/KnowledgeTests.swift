import XCTest
@testable import PodhodCore

final class KnowledgeCatalogTests: XCTestCase {
    func testBundledArticlesAndRussianSearchIncludeTextTagsAndYo() throws {
        let catalog = KnowledgeCatalog.bundled
        XCTAssertEqual(catalog.articles.count, 6)
        XCTAssertTrue(catalog.articles.allSatisfy(\.isValid))
        XCTAssertTrue(catalog.search(query: "  ЗАПАС ").contains { $0.id == "repetitions-in-reserve" })
        XCTAssertTrue(catalog.search(query: "трехминутные").contains { $0.id == "rest-between-sets" })
        XCTAssertTrue(catalog.search(query: "RIR").contains { $0.id == "repetitions-in-reserve" })
        XCTAssertTrue(catalog.search(query: "строка без совпадений 12345").isEmpty)
        XCTAssertEqual(catalog.search(query: " \n "), catalog.articles)
        XCTAssertEqual(ExerciseCatalog.bundled.exercises.count, 58)
        XCTAssertTrue(ExerciseCatalog.bundled.exercises.allSatisfy { !$0.attribution.author.isEmpty && !$0.attribution.license.isEmpty })
    }

    func testBothDecodePathsRejectInvalidSourcesDuplicatesAndFutureVersion() throws {
        let article: [String: Any] = ["id": "article", "title": "Название", "summary": "Описание", "tags": [],
            "sections": [["title": "Раздел", "paragraphs": ["Пояснение"]]], "mistakes": [],
            "sources": [["title": "Источник", "author": "Автор", "url": "https://example.com/source"]]]
        let valid: [String: Any] = ["version": 1, "articles": [article]]
        XCTAssertNoThrow(try KnowledgeCatalog(data: JSONSerialization.data(withJSONObject: valid)))
        var cases: [[String: Any]] = [["version": 2, "articles": [article]], ["version": 1, "articles": [article, article]]]
        for url in ["http://example.com", "https://user:password@example.com", "file:///private/file"] {
            var changed = article
            changed["sources"] = [["title": "Источник", "author": "Автор", "url": url]]
            cases.append(["version": 1, "articles": [changed]])
        }
        var empty = article
        empty["sections"] = []
        cases.append(["version": 1, "articles": [empty]])
        for value in cases {
            let data = try JSONSerialization.data(withJSONObject: value)
            XCTAssertThrowsError(try KnowledgeCatalog(data: data))
            XCTAssertThrowsError(try JSONDecoder().decode(KnowledgeCatalog.self, from: data))
        }
    }
}

final class KnowledgeBookmarksTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeQA-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("knowledge-bookmarks.json")
    }

    @MainActor func testKnownAndUnknownBookmarksPersistAndRemoveIndependently() throws {
        let url = try location()
        let store = KnowledgeBookmarks(fileURL: url)
        let exercise = UUID()
        XCTAssertTrue(store.setArticle("repetitions-in-reserve", saved: true))
        XCTAssertTrue(store.setArticle("future-article", saved: true))
        XCTAssertTrue(store.setExercise(exercise, saved: true))
        let restored = KnowledgeBookmarks(fileURL: url)
        XCTAssertEqual(restored.articleIDs, ["repetitions-in-reserve", "future-article"])
        XCTAssertEqual(restored.exerciseIDs, [exercise])
        XCTAssertTrue(restored.setArticle("repetitions-in-reserve", saved: false))
        XCTAssertEqual(KnowledgeBookmarks(fileURL: url).articleIDs, ["future-article"])
        XCTAssertEqual(KnowledgeBookmarks(fileURL: url).exerciseIDs, [exercise])
    }

    @MainActor func testOpeningUnboundArchiveDoesNotRewriteTransferBytesAndNextEditBindsOwner() throws {
        let url = try location()
        let guest = KnowledgeBookmarks(fileURL: url)
        XCTAssertTrue(guest.setArticle("unknown-material", saved: true))
        let original = try Data(contentsOf: url)
        let account = KnowledgeBookmarks(fileURL: url, accountID: "owner")
        XCTAssertFalse(account.loadFailed)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(account.setArticle("unknown-material", saved: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(account.setArticle("training-volume", saved: true))
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(value["accountID"] as? String, "owner")
        XCTAssertEqual(KnowledgeBookmarks(fileURL: url, accountID: "owner").articleIDs, ["unknown-material", "training-volume"])
    }

    @MainActor func testForeignOwnerRetiredAndBlockedWorkspaceCannotReadSavedStateOrWrite() throws {
        let url = try location()
        let store = KnowledgeBookmarks(fileURL: url, accountID: "owner")
        XCTAssertTrue(store.setArticle("rest-between-sets", saved: true))
        let original = try Data(contentsOf: url)
        for invalid in [KnowledgeBookmarks(fileURL: url), KnowledgeBookmarks(fileURL: url, accountID: "other"),
            KnowledgeBookmarks(fileURL: url, accountID: "owner", accountStorageError: "blocked")] {
            XCTAssertTrue(invalid.loadFailed)
            XCTAssertTrue(invalid.articleIDs.isEmpty)
            XCTAssertFalse(invalid.setArticle("training-volume", saved: true))
        }
        store.retire()
        XCTAssertTrue(store.articleIDs.isEmpty)
        XCTAssertFalse(store.setArticle("training-volume", saved: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testCorruptFutureAndDuplicateArchivesStayIntact() throws {
        let url = try location()
        for original in [Data("broken".utf8),
            Data(#"{"version":2,"articleIDs":[],"exerciseIDs":[]}"#.utf8),
            Data(#"{"version":1,"articleIDs":["a","a"],"exerciseIDs":[]}"#.utf8)] {
            try original.write(to: url)
            let store = KnowledgeBookmarks(fileURL: url)
            XCTAssertTrue(store.loadFailed)
            XCTAssertFalse(store.setArticle("a", saved: true))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    @MainActor func testCapacityAndInvalidIDDoNotTruncateUnknownMaterials() throws {
        let url = try location()
        let ids = (0..<500).map { "future-material-\($0)" }
        let original = try JSONSerialization.data(withJSONObject: ["version": 1, "articleIDs": ids, "exerciseIDs": []])
        try original.write(to: url)
        let store = KnowledgeBookmarks(fileURL: url)
        XCTAssertFalse(store.loadFailed)
        XCTAssertFalse(store.setArticle("one-more", saved: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(store.setArticle(ids[0], saved: false))
        XCTAssertFalse(store.setArticle("", saved: true))
        XCTAssertTrue(store.setArticle("one-more", saved: true))
        XCTAssertEqual(store.articleIDs.count, 500)
        XCTAssertTrue(store.articleIDs.contains(ids[499]))
    }

    @MainActor func testFailedWriteKeepsPreviousInMemoryAndPreservedBytes() throws {
        let url = try location()
        let store = KnowledgeBookmarks(fileURL: url)
        XCTAssertTrue(store.setArticle("first", saved: true))
        let original = try Data(contentsOf: url)
        let backup = url.appendingPathExtension("before-test")
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertFalse(store.setArticle("second", saved: true))
        XCTAssertEqual(store.articleIDs, ["first"])
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    @MainActor func testGuestAdoptionCopiesBookmarksRotatesGuestAndKeepsExistingAccountSeparate() throws {
        let url = try location()
        let workspaces = AccountWorkspaces(rootURL: url.deletingLastPathComponent())
        let guest = KnowledgeBookmarks(fileURL: workspaces.currentDirectory.appendingPathComponent("knowledge-bookmarks.json"))
        XCTAssertTrue(guest.setArticle("future-material", saved: true))
        let directory = try workspaces.prepare(accountID: "owner", legacyAccountID: nil)
        let account = KnowledgeBookmarks(fileURL: directory.appendingPathComponent("knowledge-bookmarks.json"), accountID: "owner")
        XCTAssertEqual(account.articleIDs, ["future-material"])
        try workspaces.commit(accountID: "owner")
        XCTAssertTrue(account.setArticle("training-volume", saved: true))
        let newGuestDirectory = try workspaces.prepare(accountID: nil, legacyAccountID: nil)
        try workspaces.commit(accountID: nil)
        let newGuest = KnowledgeBookmarks(fileURL: newGuestDirectory.appendingPathComponent("knowledge-bookmarks.json"))
        XCTAssertTrue(newGuest.articleIDs.isEmpty)
        XCTAssertTrue(newGuest.setArticle("other-guest", saved: true))
        let reopened = try workspaces.prepare(accountID: "owner", legacyAccountID: nil)
        try workspaces.commit(accountID: "owner")
        XCTAssertEqual(KnowledgeBookmarks(fileURL: reopened.appendingPathComponent("knowledge-bookmarks.json"), accountID: "owner").articleIDs,
            ["future-material", "training-volume"])
        XCTAssertEqual(guest.articleIDs, ["future-material"])
    }
}

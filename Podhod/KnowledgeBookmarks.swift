import Foundation
import Observation

private struct KnowledgeBookmarksArchive: Codable {
    var version = 1
    var accountID: String?
    var articleIDs: [String] = []
    var exerciseIDs: [UUID] = []

    var isValid: Bool {
        version == 1 && (accountID.map { !$0.isEmpty } ?? true) && articleIDs.count + exerciseIDs.count <= 500 &&
            Set(articleIDs).count == articleIDs.count && Set(exerciseIDs).count == exerciseIDs.count &&
            articleIDs.allSatisfy { !$0.isEmpty && $0.count <= 200 }
    }
}

@MainActor @Observable
final class KnowledgeBookmarks {
    private var archive = KnowledgeBookmarksArchive()
    private(set) var loadFailed = false
    private(set) var isRetired = false
    var errorMessage: String?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let accountID: String?
    @ObservationIgnored private let accountStorageError: String?

    var articleIDs: Set<String> { isRetired || loadFailed ? [] : Set(archive.articleIDs) }
    var exerciseIDs: Set<UUID> { isRetired || loadFailed ? [] : Set(archive.exerciseIDs) }

    init(fileURL: URL, accountID: String? = nil, accountStorageError: String? = nil) {
        self.fileURL = fileURL
        self.accountID = accountID
        self.accountStorageError = accountStorageError
        do {
            guard accountStorageError == nil else { throw KnowledgeError.invalidBookmarks }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let attributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink == false else { throw KnowledgeError.invalidBookmarks }
                let value = try JSONDecoder().decode(KnowledgeBookmarksArchive.self, from: Data(contentsOf: fileURL))
                guard value.version == 1 else { throw KnowledgeError.unsupportedBookmarks }
                guard value.isValid else { throw KnowledgeError.invalidBookmarks }
                guard value.accountID == nil || value.accountID == accountID else { throw KnowledgeError.accountMismatch }
                archive = value
            }
        } catch {
            loadFailed = true
            errorMessage = (error as? KnowledgeError)?.localizedDescription ?? KnowledgeError.invalidBookmarks.localizedDescription
        }
    }

    func retire() { isRetired = true }

    @discardableResult
    func setArticle(_ id: String, saved: Bool) -> Bool {
        var changed = archive
        changed.articleIDs.removeAll { $0 == id }
        if saved { changed.articleIDs.append(id) }
        changed.articleIDs.sort()
        return save(changed)
    }

    @discardableResult
    func setExercise(_ id: UUID, saved: Bool) -> Bool {
        var changed = archive
        changed.exerciseIDs.removeAll { $0 == id }
        if saved { changed.exerciseIDs.append(id) }
        changed.exerciseIDs.sort { $0.uuidString < $1.uuidString }
        return save(changed)
    }

    private func save(_ changed: KnowledgeBookmarksArchive) -> Bool {
        guard changed.articleIDs.count + changed.exerciseIDs.count <= 500 else {
            errorMessage = KnowledgeError.capacity.localizedDescription
            return false
        }
        guard !loadFailed, !isRetired, accountStorageError == nil, changed.isValid else {
            errorMessage = KnowledgeError.saveFailed.localizedDescription
            return false
        }
        if changed.articleIDs == archive.articleIDs && changed.exerciseIDs == archive.exerciseIDs { return true }
        do {
            var value = changed
            value.accountID = accountID
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            archive = value
            errorMessage = nil
            return true
        } catch {
            errorMessage = KnowledgeError.saveFailed.localizedDescription
            return false
        }
    }
}

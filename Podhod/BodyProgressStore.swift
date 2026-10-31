import Foundation
import Observation

@MainActor @Observable
final class BodyProgressStore {
    private(set) var archive = BodyProgressArchive()
    private(set) var loadFailed = false
    private(set) var isRetired = false
    var errorMessage: String?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var accountStorageError: String?
    @ObservationIgnored private let accountID: String?

    init(fileURL: URL, accountID: String? = nil, accountStorageError: String? = nil) {
        self.fileURL = fileURL
        self.accountID = accountID
        self.accountStorageError = accountStorageError
        do {
            guard accountStorageError == nil else { throw BodyProgressError.invalidArchive }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let attributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink == false else { throw BodyProgressError.invalidArchive }
                let value = try JSONDecoder().decode(BodyProgressArchive.self, from: Data(contentsOf: fileURL))
                guard value.version == 1 else { throw BodyProgressError.unsupportedArchive }
                guard value.isValid else { throw BodyProgressError.invalidArchive }
                guard value.accountID == nil || value.accountID == accountID else { throw BodyProgressError.accountMismatch }
                archive = value
            }
            try validatePhotoDirectory()
        } catch {
            loadFailed = true
            errorMessage = (error as? BodyProgressError)?.localizedDescription ?? BodyProgressError.invalidArchive.localizedDescription
        }
    }

    var hasPendingDeletions: Bool { !archive.pendingPhotoDeletions.isEmpty }

    func retire() { isRetired = true }

    func entry(on date: String) -> BodyMeasurementEntry? { archive.entries.first { $0.date == date } }

    @discardableResult
    func saveEntry(_ entry: BodyMeasurementEntry, expected: BodyMeasurementEntry?) -> Bool {
        guard entry.isValid else { return fail(.invalidMeasurement) }
        let previous = archive.entries.first { $0.id == entry.id }
        guard previous == expected else { return fail(.staleEdit) }
        guard previous == nil || (previous?.date == entry.date && previous?.timezone == entry.timezone) else { return fail(.staleEdit) }
        guard !archive.entries.contains(where: { $0.date == entry.date && $0.id != entry.id }) else { return fail(.dateOccupied) }
        guard previous != nil || archive.entries.count < 5000 else { return fail(.capacity) }
        var changed = archive
        changed.entries.removeAll { $0.id == entry.id }
        changed.entries.append(entry)
        changed.entries.sort { $0.date < $1.date }
        return save(changed)
    }

    @discardableResult
    func removeEntry(_ expected: BodyMeasurementEntry) -> Bool {
        guard archive.entries.first(where: { $0.id == expected.id }) == expected else { return fail(.staleEdit) }
        var changed = archive
        changed.entries.removeAll { $0.id == expected.id }
        return save(changed)
    }

    @discardableResult
    func addPhoto(_ photo: BodyProgressPhoto, preparedJPEG: Data) -> Bool {
        guard !loadFailed, accountStorageError == nil, !isRetired else { return fail(.saveFailed) }
        guard photo.isValid, ProgressPhotoImport.isPreparedJPEG(preparedJPEG) else { return fail(.invalidPhoto) }
        guard archive.photos.count < 500, archive.pendingPhotoDeletions.count < 500 else { return fail(.capacity) }
        guard !archive.photos.contains(where: { $0.id == photo.id }), !archive.pendingPhotoDeletions.contains(photo.id) else {
            return fail(.staleEdit)
        }
        let destination = photoURL(photo.id)
        do {
            try validatePhotoDirectory()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.deletingLastPathComponent().path)
            #endif
            guard !FileManager.default.fileExists(atPath: destination.path) else { return fail(.staleEdit) }
            try writePrivateData(preparedJPEG, to: destination)
            var changed = archive
            changed.photos.append(photo)
            guard save(changed) else {
                try FileManager.default.removeItem(at: destination)
                return false
            }
            return true
        } catch { return fail(.saveFailed) }
    }

    func photoData(for id: UUID) throws -> Data {
        guard !loadFailed, accountStorageError == nil, !isRetired,
              archive.photos.contains(where: { $0.id == id }) else { throw BodyProgressError.photoUnavailable }
        do {
            try validatePhotoDirectory()
            let url = photoURL(id)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false,
                  let size = values.fileSize, size <= ProgressPhotoImport.maximumJPEGBytes else { throw BodyProgressError.photoUnavailable }
            let data = try Data(contentsOf: url)
            guard ProgressPhotoImport.isPreparedJPEG(data) else { throw BodyProgressError.photoUnavailable }
            return data
        } catch { throw BodyProgressError.photoUnavailable }
    }

    @discardableResult
    func removePhoto(_ expected: BodyProgressPhoto) -> Bool {
        guard archive.photos.first(where: { $0.id == expected.id }) == expected else { return fail(.staleEdit) }
        guard archive.pendingPhotoDeletions.count < 500 else { return fail(.capacity) }
        var changed = archive
        changed.photos.removeAll { $0.id == expected.id }
        changed.pendingPhotoDeletions.append(expected.id)
        guard save(changed) else { return false }
        return retryPendingPhotoDeletions()
    }

    @discardableResult
    func retryPendingPhotoDeletions() -> Bool {
        guard !loadFailed, accountStorageError == nil, !isRetired else { return fail(.saveFailed) }
        guard hasPendingDeletions else { return true }
        var changed = archive
        do {
            try validatePhotoDirectory()
            for id in archive.pendingPhotoDeletions {
                let url = photoURL(id)
                if FileManager.default.fileExists(atPath: url.path) {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink == false else { throw BodyProgressError.deletionIncomplete }
                    try FileManager.default.removeItem(at: url)
                }
                changed.pendingPhotoDeletions.removeAll { $0 == id }
            }
            guard save(changed) else { return fail(.deletionIncomplete) }
            return true
        } catch { return fail(.deletionIncomplete) }
    }

    private func photoURL(_ id: UUID) -> URL {
        fileURL.deletingLastPathComponent().appending(path: "progress-photos", directoryHint: .isDirectory)
            .appending(path: "\(id.uuidString).jpg")
    }

    private func validatePhotoDirectory() throws {
        let directory = fileURL.deletingLastPathComponent().appending(path: "progress-photos", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false else { throw BodyProgressError.invalidArchive }
        }
    }

    private func save(_ value: BodyProgressArchive) -> Bool {
        guard !loadFailed, accountStorageError == nil, !isRetired else { return fail(.saveFailed) }
        do {
            var changed = value
            changed.accountID = accountID
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(changed)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writePrivateData(data, to: fileURL)
            archive = changed
            return true
        } catch { return fail(.saveFailed) }
    }

    private func writePrivateData(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func fail(_ error: BodyProgressError) -> Bool {
        errorMessage = error.localizedDescription
        return false
    }
}

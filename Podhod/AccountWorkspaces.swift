import CryptoKit
import Foundation

final class AccountWorkspaces {
    private struct Selection: Codable {
        var version = 2
        var accountID: String?
        var guestDirectory: String?
        var legacyWorkspace: Bool?
        var completedGuestAdoptions: [String: String]?
    }

    private struct GuestAdoption: Codable {
        var version = 1
        var id = UUID()
        var sourceDirectory: String
        var previousTarget: [String: String]
        var sourceFiles: [String: String]
    }

    private static let archiveNames = ["training.json", "protein.json", "sync-state.json", "nutrition-preferences.json", "nutrition.json", "body-progress.json"]

    private enum Destination: Equatable { case guest, account(String) }

    let rootURL: URL
    private var selection: Selection?
    private var rotateGuestOnCommit = false
    private var legacySelectorData: Data?
    private var preparedAdoptions: [String: String] = [:]
    private var preparedDestination: Destination?
    private(set) var errorMessage: String?
    var accountID: String? { selection?.accountID }
    var isLegacy: Bool { selection == nil || selection?.legacyWorkspace == true }
    var currentDirectory: URL { isLegacy ? rootURL : directory(for: accountID) }
    var storageID: String { SHA256.hash(data: Data(currentDirectory.path.utf8)).map { String(format: "%02x", $0) }.joined() }

    init(rootURL: URL = URL.applicationSupportDirectory.appending(path: "Podhod", directoryHint: .isDirectory)) {
        self.rootURL = rootURL
        let manifest = rootURL.appending(path: "workspace.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            do {
                let data = try Data(contentsOf: manifest)
                let value = try JSONDecoder().decode(Selection.self, from: data)
                guard (1...2).contains(value.version), value.accountID.map({ !$0.isEmpty }) ?? true,
                      Self.validGuestDirectory(value.guestDirectory ?? "guest"),
                      value.legacyWorkspace != true || (value.accountID == nil && value.guestDirectory == nil),
                      (value.completedGuestAdoptions ?? [:]).allSatisfy({
                          $0.key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && UUID(uuidString: $0.value) != nil
                      }) else {
                    throw TrainingError.unsupportedArchive
                }
                selection = value
                if value.version == 1 { legacySelectorData = data }
            } catch {
                errorMessage = "Не удалось прочитать список аккаунтов. Исходные файлы защищены от перезаписи."
            }
        }
    }

    private static func validGuestDirectory(_ name: String) -> Bool {
        name.range(of: "^guest(-[0-9A-Fa-f-]{36})?$", options: .regularExpression) != nil
    }

    @discardableResult
    func enablePrivateProgressStorage() -> Bool {
        guard errorMessage == nil else { return false }
        if selection?.version == 2 { return true }
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let manifest = rootURL.appending(path: "workspace.json")
            if let original = legacySelectorData {
                guard try Data(contentsOf: manifest) == original else { throw TrainingError.invalidArchive }
                var backup = rootURL.appending(path: "workspace-v1-backup.json")
                if FileManager.default.fileExists(atPath: backup.path) {
                    if try Data(contentsOf: backup) != original { backup = rootURL.appending(path: "workspace-v1-backup-\(UUID()).json") }
                }
                if !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
            }
            var value = selection ?? Selection(legacyWorkspace: true)
            value.version = 2
            try JSONEncoder().encode(value).write(to: manifest, options: .atomic)
            selection = value
            legacySelectorData = nil
            return true
        } catch {
            errorMessage = "Не удалось защитить список аккаунтов. Исходные файлы сохранены; переключение недоступно."
            return false
        }
    }

    private func directory(for id: String?) -> URL {
        guard let id else { return rootURL.appending(path: selection?.guestDirectory ?? "guest", directoryHint: .isDirectory) }
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return rootURL.appending(path: "accounts/\(key)", directoryHint: .isDirectory)
    }

    func prepare(accountID: String?, legacyAccountID: String?) throws -> URL {
        preparedDestination = nil
        preparedAdoptions = [:]
        rotateGuestOnCommit = false
        guard errorMessage == nil, accountID.map({ !$0.isEmpty }) ?? true,
              enablePrivateProgressStorage() else { throw TrainingError.invalidArchive }
        let target = directory(for: accountID)
        if isLegacy {
            rotateGuestOnCommit = accountID != nil
            let backup = rootURL.appending(path: "legacy-backups/\(UUID())", directoryHint: .isDirectory)
            let owner = directory(for: legacyAccountID ?? accountID)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
            let files = try workspaceFiles(in: rootURL)
            try copyWorkspaceFiles(files, from: rootURL, to: backup)
            try copyWorkspaceFiles(files, from: rootURL, to: owner)
        } else if self.accountID == nil, accountID != nil {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let files = try workspaceFiles(in: currentDirectory)
            let sourceDirectory = selection?.guestDirectory ?? "guest"
            let accountKey = target.lastPathComponent
            let journalURL = target.appending(path: "guest-adoption.json")
            var pending: GuestAdoption?
            if FileManager.default.fileExists(atPath: journalURL.path) {
                pending = try readGuestAdoption(at: journalURL)
                if selection?.completedGuestAdoptions?[accountKey] == pending?.id.uuidString {
                    try FileManager.default.removeItem(at: journalURL)
                    pending = nil
                } else if pending?.sourceDirectory != sourceDirectory {
                    let snapshot = try workspaceFingerprint(in: target)
                    guard let abandoned = pending, snapshot.allSatisfy({ abandoned.previousTarget[$0.key] == $0.value || abandoned.sourceFiles[$0.key] == $0.value }) else {
                        throw TrainingError.invalidArchive
                    }
                    try backupAndRemoveAdoptionFiles(snapshot, in: target)
                    try FileManager.default.removeItem(at: journalURL)
                    pending = nil
                }
            }
            let targetFiles = try workspaceFiles(in: target)
            let targetNames = try FileManager.default.contentsOfDirectory(atPath: target.path)
            let isUnclaimed = targetFiles.isEmpty && targetNames.allSatisfy { $0 == "progress-photos" || $0 == "guest-adoption.json" }
            if let previous = pending {
                let snapshot = try workspaceFingerprint(in: target)
                guard snapshot.allSatisfy({ previous.previousTarget[$0.key] == $0.value || previous.sourceFiles[$0.key] == $0.value }) else {
                    throw TrainingError.invalidArchive
                }
                let source = try workspaceFingerprint(in: currentDirectory)
                let next = GuestAdoption(id: previous.id, sourceDirectory: sourceDirectory, previousTarget: snapshot, sourceFiles: source)
                try writeGuestAdoption(next, to: journalURL)
                if snapshot.contains(where: { source[$0.key] != $0.value }) {
                    try backupAndRemoveAdoptionFiles(snapshot, in: target)
                }
                try copyWorkspaceFiles(files, from: currentDirectory, to: target)
                rotateGuestOnCommit = true
                preparedAdoptions[accountKey] = next.id.uuidString
            } else if isUnclaimed && !files.isEmpty {
                let source = try workspaceFingerprint(in: currentDirectory)
                let next = GuestAdoption(sourceDirectory: sourceDirectory, previousTarget: [:], sourceFiles: source)
                try writeGuestAdoption(next, to: journalURL)
                try copyWorkspaceFiles(files, from: currentDirectory, to: target)
                rotateGuestOnCommit = true
                preparedAdoptions[accountKey] = next.id.uuidString
            }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        preparedDestination = accountID.map { .account($0) } ?? .guest
        return target
    }

    private func workspaceFingerprint(in directory: URL) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        for name in try workspaceFiles(in: directory) {
            let data = try Data(contentsOf: directory.appending(path: name))
            snapshot[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return snapshot
    }

    private func readGuestAdoption(at url: URL) throws -> GuestAdoption {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink == false else { throw TrainingError.invalidArchive }
        let value = try JSONDecoder().decode(GuestAdoption.self, from: Data(contentsOf: url))
        let names = Set(Self.archiveNames)
        guard value.version == 1, Self.validGuestDirectory(value.sourceDirectory),
              [value.previousTarget, value.sourceFiles].allSatisfy({ snapshot in snapshot.allSatisfy { path, hash in
                  let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                  let photo = parts.count == 2 && parts[0] == "progress-photos" && !parts[1].isEmpty && parts[1] != "." && parts[1] != ".." && !parts[1].contains("\\")
                  return (names.contains(path) || photo) && hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
              } }) else { throw TrainingError.invalidArchive }
        return value
    }

    private func writeGuestAdoption(_ value: GuestAdoption, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func backupAndRemoveAdoptionFiles(_ snapshot: [String: String], in directory: URL) throws {
        guard !snapshot.isEmpty else { return }
        let backup = rootURL.appending(path: "guest-transfer-backups/\(UUID())", directoryHint: .isDirectory)
        try copyWorkspaceFiles(snapshot.keys.sorted(), from: directory, to: backup)
        for name in snapshot.keys.sorted() { try FileManager.default.removeItem(at: directory.appending(path: name)) }
    }

    private func workspaceFiles(in directory: URL) throws -> [String] {
        let names = Self.archiveNames
        var files = names.filter { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
        let photos = directory.appending(path: "progress-photos", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: photos.path) {
            let values = try photos.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false else { throw TrainingError.invalidArchive }
            files += try FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil).map {
                "progress-photos/\($0.lastPathComponent)"
            }
        }
        for path in files {
            let values = try directory.appending(path: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false else { throw TrainingError.invalidArchive }
        }
        return files.sorted()
    }

    private func copyWorkspaceFiles(_ files: [String], from source: URL, to target: URL) throws {
        for name in files {
            let origin = source.appending(path: name)
            let destination = target.appending(path: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink == false,
                      FileManager.default.contentsEqual(atPath: origin.path, andPath: destination.path) else {
                    throw TrainingError.invalidArchive
                }
                continue
            }
            let parent = destination.deletingLastPathComponent()
            if name.hasPrefix("progress-photos/"), FileManager.default.fileExists(atPath: parent.path) {
                let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink == false else { throw TrainingError.invalidArchive }
            }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try Data(contentsOf: origin)
            #if os(iOS)
            if name == "body-progress.json" || name.hasPrefix("progress-photos/") {
                if name.hasPrefix("progress-photos/") {
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: parent.path)
                }
                try data.write(to: destination, options: [.atomic, .completeFileProtection])
            } else { try data.write(to: destination, options: .atomic) }
            #else
            try data.write(to: destination, options: .atomic)
            #endif
        }
    }

    func commit(accountID: String?) throws {
        let expected = accountID.map { Destination.account($0) } ?? .guest
        guard errorMessage == nil, preparedDestination == expected,
              accountID.map({ !$0.isEmpty }) ?? true, enablePrivateProgressStorage() else { throw TrainingError.invalidArchive }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var completed = selection?.completedGuestAdoptions ?? [:]
        for (key, source) in preparedAdoptions { completed[key] = source }
        let value = Selection(accountID: accountID,
                              guestDirectory: rotateGuestOnCommit ? "guest-\(UUID())" : selection?.guestDirectory,
                              completedGuestAdoptions: completed.isEmpty ? nil : completed)
        try JSONEncoder().encode(value).write(to: rootURL.appending(path: "workspace.json"), options: .atomic)
        selection = value
        rotateGuestOnCommit = false
        for key in preparedAdoptions.keys {
            let journal = rootURL.appending(path: "accounts/\(key)/guest-adoption.json")
            try? FileManager.default.removeItem(at: journal)
        }
        preparedAdoptions = [:]
        preparedDestination = nil
    }
}

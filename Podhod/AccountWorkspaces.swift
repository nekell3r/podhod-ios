import CryptoKit
import Foundation

final class AccountWorkspaces {
    private struct Selection: Codable {
        var version = 1
        var accountID: String?
        var guestDirectory: String?
    }

    let rootURL: URL
    private var selection: Selection?
    private var rotateGuestOnCommit = false
    private(set) var errorMessage: String?
    var accountID: String? { selection?.accountID }
    var isLegacy: Bool { selection == nil }
    var currentDirectory: URL { isLegacy ? rootURL : directory(for: accountID) }

    init(rootURL: URL = URL.applicationSupportDirectory.appending(path: "Podhod", directoryHint: .isDirectory)) {
        self.rootURL = rootURL
        let manifest = rootURL.appending(path: "workspace.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            do {
                let value = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: manifest))
                guard value.version == 1,
                      (value.guestDirectory ?? "guest").range(of: "^guest(-[0-9A-Fa-f-]{36})?$", options: .regularExpression) != nil else {
                    throw TrainingError.unsupportedArchive
                }
                selection = value
            } catch {
                errorMessage = "Не удалось прочитать список аккаунтов. Исходные файлы защищены от перезаписи."
            }
        }
    }

    private func directory(for id: String?) -> URL {
        guard let id else { return rootURL.appending(path: selection?.guestDirectory ?? "guest", directoryHint: .isDirectory) }
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return rootURL.appending(path: "accounts/\(key)", directoryHint: .isDirectory)
    }

    func prepare(accountID: String?, legacyAccountID: String?) throws -> URL {
        guard errorMessage == nil, accountID.map({ !$0.isEmpty }) ?? true else { throw TrainingError.invalidArchive }
        let target = directory(for: accountID)
        rotateGuestOnCommit = false
        let files = ["training.json", "protein.json", "sync-state.json"]
        if isLegacy {
            rotateGuestOnCommit = accountID != nil
            let backup = rootURL.appending(path: "legacy-backups/\(UUID())", directoryHint: .isDirectory)
            let owner = directory(for: legacyAccountID ?? accountID)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
            for name in files {
                let source = rootURL.appending(path: name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let data = try Data(contentsOf: source)
                try data.write(to: backup.appending(path: name), options: .atomic)
                let destination = owner.appending(path: name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard try Data(contentsOf: destination) == data else { throw TrainingError.invalidArchive }
                } else { try data.write(to: destination, options: .atomic) }
            }
        } else if self.accountID == nil, accountID != nil {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let targetHasFiles = files.contains { FileManager.default.fileExists(atPath: target.appending(path: $0).path) }
            let guestTraining = try? Data(contentsOf: currentDirectory.appending(path: "training.json"))
            let targetTraining = try? Data(contentsOf: target.appending(path: "training.json"))
            let canResumeAdoption = guestTraining != nil && guestTraining == targetTraining && files.allSatisfy { name in
                let destination = target.appending(path: name)
                guard FileManager.default.fileExists(atPath: destination.path) else { return true }
                return (try? Data(contentsOf: currentDirectory.appending(path: name))) == (try? Data(contentsOf: destination))
            }
            if !targetHasFiles || canResumeAdoption {
                for name in files {
                    let source = currentDirectory.appending(path: name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        let data = try Data(contentsOf: source)
                        let destination = target.appending(path: name)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            guard try Data(contentsOf: destination) == data else { throw TrainingError.invalidArchive }
                        } else { try data.write(to: destination, options: .atomic) }
                        rotateGuestOnCommit = true
                    }
                }
            }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func commit(accountID: String?) throws {
        guard errorMessage == nil else { throw TrainingError.invalidArchive }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let value = Selection(accountID: accountID,
                              guestDirectory: rotateGuestOnCommit ? "guest-\(UUID())" : selection?.guestDirectory)
        try JSONEncoder().encode(value).write(to: rootURL.appending(path: "workspace.json"), options: .atomic)
        selection = value
        rotateGuestOnCommit = false
    }
}

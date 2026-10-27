import Foundation

enum CloudAccountProfileError: Error { case accountMismatch, invalidLinks }

struct CloudAccountProfile: Decodable, Equatable {
    let id: String
    var username: String?
    var firstName: String?
    var lastName: String?

    var displayName: String {
        let name = [firstName, lastName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        let login = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return login.isEmpty ? "Аккаунт" : login
    }
}

struct CloudAccountLink: Decodable, Equatable {
    let providerAlias: String
    let connected: Bool
    var linkedUsername: String?
}

struct CloudAccountDetails: Equatable {
    let profile: CloudAccountProfile
    let telegram: CloudAccountLink?

    init(profile: CloudAccountProfile, links: [CloudAccountLink], expectedAccountID: String) throws {
        guard !expectedAccountID.isEmpty, profile.id == expectedAccountID else { throw CloudAccountProfileError.accountMismatch }
        let matches = links.filter { $0.providerAlias == "telegram" }
        guard matches.count <= 1 else { throw CloudAccountProfileError.invalidLinks }
        self.profile = profile
        telegram = matches.first
    }
}

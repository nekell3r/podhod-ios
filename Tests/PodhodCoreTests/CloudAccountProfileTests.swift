import Foundation
import XCTest
@testable import PodhodCore

final class CloudAccountProfileTests: XCTestCase {
    func testProfileWithoutOptionalNamesDisplaysLogin() throws {
        let profile = try JSONDecoder().decode(CloudAccountProfile.self, from: Data(#"{"id":"account-a","username":"owner","userProfileMetadata":{}}"#.utf8))
        XCTAssertEqual(profile.displayName, "owner")
    }

    func testProfileDisplaysTrimmedFullName() {
        let profile = CloudAccountProfile(id: "a", username: "login", firstName: " Павел ", lastName: " Иванов ")
        XCTAssertEqual(profile.displayName, "Павел Иванов")
    }

    func testAccountResponseFromDifferentSubjectIsRejected() {
        XCTAssertThrowsError(try CloudAccountDetails(profile: CloudAccountProfile(id: "other"), links: [], expectedAccountID: "current"))
    }

    func testAvailableTelegramProviderDoesNotMeanConnectedAccount() throws {
        let links = try JSONDecoder().decode([CloudAccountLink].self, from: Data(#"[{"providerAlias":"telegram","connected":false,"displayName":"Telegram"}]"#.utf8))
        let details = try CloudAccountDetails(profile: CloudAccountProfile(id: "a"), links: links, expectedAccountID: "a")
        XCTAssertEqual(details.telegram?.connected, false)
        XCTAssertNil(details.telegram?.linkedUsername)
    }

    func testConnectedTelegramAccountAndUnknownProvidersAreKeptSeparate() throws {
        let details = try CloudAccountDetails(profile: CloudAccountProfile(id: "a"), links: [
            CloudAccountLink(providerAlias: "another", connected: true, linkedUsername: "other"),
            CloudAccountLink(providerAlias: "telegram", connected: true, linkedUsername: "12345")
        ], expectedAccountID: "a")
        XCTAssertEqual(details.telegram?.linkedUsername, "12345")
        XCTAssertEqual(details.telegram?.connected, true)
    }

    func testAmbiguousTelegramConnectionsAreRejected() {
        XCTAssertThrowsError(try CloudAccountDetails(profile: CloudAccountProfile(id: "a"), links: [
            CloudAccountLink(providerAlias: "telegram", connected: true),
            CloudAccountLink(providerAlias: "telegram", connected: false)
        ], expectedAccountID: "a"))
    }
}

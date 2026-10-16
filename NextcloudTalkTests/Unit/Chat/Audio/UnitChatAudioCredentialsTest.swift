//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatAudioCredentialsTest: XCTestCase {

    private let server = "https://cloud.example.com"

    private func belongs(_ urlString: String, server: String? = "https://cloud.example.com", userId: String? = "alice") -> Bool {
        return ChatAudioCredentials.belongsToAccount(url: URL(string: urlString)!, server: server, userId: userId)
    }

    func testFilesOfTheAccountGetCredentials() {
        XCTAssertTrue(belongs("https://cloud.example.com/remote.php/dav/files/alice/Talk/Recording.mp3"))
        XCTAssertTrue(belongs("https://CLOUD.example.com/remote.php/dav/files/alice/Talk/Recording.mp3"))
    }

    func testServerInSubdirectory() {
        XCTAssertTrue(belongs("https://example.com/nextcloud/remote.php/dav/files/alice/a.mp3", server: "https://example.com/nextcloud"))
        XCTAssertFalse(belongs("https://example.com/remote.php/dav/files/alice/a.mp3", server: "https://example.com/nextcloud"))
    }

    func testOtherUsersDoNotGetCredentials() {
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/bob/a.mp3"))
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/alice2/a.mp3"))
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/alice"))
    }

    func testOtherServersDoNotGetCredentials() {
        XCTAssertFalse(belongs("https://evil.example.com/remote.php/dav/files/alice/a.mp3"))
        XCTAssertFalse(belongs("https://cloud.example.com.evil.com/remote.php/dav/files/alice/a.mp3"))
        XCTAssertFalse(belongs("http://cloud.example.com/remote.php/dav/files/alice/a.mp3"))
        XCTAssertFalse(belongs("https://cloud.example.com:8443/remote.php/dav/files/alice/a.mp3"))
    }

    func testOtherEndpointsDoNotGetCredentials() {
        XCTAssertFalse(belongs("https://cloud.example.com/index.php/apps/files/alice/a.mp3"))
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/alice/../bob/a.mp3"))
    }

    func testMissingAccountDataGetsNoCredentials() {
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/alice/a.mp3", server: nil))
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/alice/a.mp3", server: ""))
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/alice/a.mp3", userId: nil))
        XCTAssertFalse(belongs("https://cloud.example.com/remote.php/dav/files/alice/a.mp3", userId: ""))
    }

    func testUserIdsWithSpecialCharacters() {
        XCTAssertTrue(belongs("https://cloud.example.com/remote.php/dav/files/alice%20smith/a.mp3", userId: "alice smith"))
        XCTAssertTrue(belongs("https://cloud.example.com/remote.php/dav/files/alice@example.com/a.mp3", userId: "alice@example.com"))
    }
}

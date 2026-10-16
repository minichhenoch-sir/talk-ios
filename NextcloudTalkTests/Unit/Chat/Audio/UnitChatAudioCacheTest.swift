//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatAudioCacheTest: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testCacheKeyUsesServerFileIdAndEtag() {
        let key = ChatAudioTrack.cacheKey(server: "https://cloud.example.com", fileId: "42", etag: "abc", fallbackURL: "https://cloud.example.com/remote.php/dav/files/alice/a.mp3")

        XCTAssertEqual(key, "https://cloud.example.com/42/abc")
    }

    func testCacheKeyChangesWithEtagButNotWithFileName() {
        let original = ChatAudioTrack.cacheKey(server: "https://cloud.example.com", fileId: "42", etag: "abc", fallbackURL: "https://cloud.example.com/remote.php/dav/files/alice/a.mp3")
        let renamed = ChatAudioTrack.cacheKey(server: "https://cloud.example.com", fileId: "42", etag: "abc", fallbackURL: "https://cloud.example.com/remote.php/dav/files/alice/b.mp3")
        let changed = ChatAudioTrack.cacheKey(server: "https://cloud.example.com", fileId: "42", etag: "def", fallbackURL: "https://cloud.example.com/remote.php/dav/files/alice/a.mp3")
        let otherServer = ChatAudioTrack.cacheKey(server: "https://other.example.com", fileId: "42", etag: "abc", fallbackURL: "https://other.example.com/remote.php/dav/files/alice/a.mp3")

        XCTAssertEqual(original, renamed)
        XCTAssertNotEqual(original, changed)
        XCTAssertNotEqual(original, otherServer)
    }

    func testCacheKeyFallsBackToTheUrlWithoutFileId() {
        let url = "https://cloud.example.com/remote.php/dav/files/alice/a.mp3"

        XCTAssertEqual(ChatAudioTrack.cacheKey(server: "https://cloud.example.com", fileId: nil, etag: "abc", fallbackURL: url), url)
        XCTAssertEqual(ChatAudioTrack.cacheKey(server: "https://cloud.example.com", fileId: "", etag: "abc", fallbackURL: url), url)
    }

    func testFileNamesAreStableAndDoNotContainTheKey() {
        let name = ChatAudioCache.fileName(forCacheKey: "https://cloud.example.com/42/abc")

        XCTAssertEqual(name, ChatAudioCache.fileName(forCacheKey: "https://cloud.example.com/42/abc"))
        XCTAssertNotEqual(name, ChatAudioCache.fileName(forCacheKey: "https://cloud.example.com/42/abd"))
        XCTAssertFalse(name.contains("/"))
    }

    func testCompletedDownloadIsCached() throws {
        let cache = ChatAudioCache(directory: directory, maxSize: 1024)
        cache.prepareDirectory(forAccountId: "alice@cloud")

        try Data(count: 10).write(to: cache.partialFileURL(forCacheKey: "a", accountId: "alice@cloud"))
        XCTAssertNil(cache.cachedFile(forCacheKey: "a", accountId: "alice@cloud"))

        XCTAssertNotNil(cache.completeDownload(forCacheKey: "a", accountId: "alice@cloud"))
        XCTAssertNotNil(cache.cachedFile(forCacheKey: "a", accountId: "alice@cloud"))
        XCTAssertNil(cache.cachedFile(forCacheKey: "a", accountId: "bob@cloud"))
    }

    func testTrimEvictsLeastRecentlyUsedFilesButKeepsFilesInUse() throws {
        let cache = ChatAudioCache(directory: directory, maxSize: 250)
        cache.prepareDirectory(forAccountId: "alice")

        for (index, key) in ["old", "used", "new"].enumerated() {
            let url = cache.completeFileURL(forCacheKey: key, accountId: "alice")
            try Data(count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)], ofItemAtPath: url.path)
        }

        cache.beginUse(cacheKey: "old")
        cache.trim()

        XCTAssertNotNil(cache.cachedFile(forCacheKey: "old", accountId: "alice"))
        XCTAssertNil(cache.cachedFile(forCacheKey: "used", accountId: "alice"))
        XCTAssertNotNil(cache.cachedFile(forCacheKey: "new", accountId: "alice"))

        cache.endUse(cacheKey: "old")
    }

    func testRemovingAnAccountRemovesOnlyItsFiles() throws {
        let cache = ChatAudioCache(directory: directory, maxSize: 1024)

        for account in ["alice", "bob"] {
            cache.prepareDirectory(forAccountId: account)
            try Data(count: 10).write(to: cache.completeFileURL(forCacheKey: "a", accountId: account))
        }

        cache.removeAll(forAccountId: "alice")

        XCTAssertNil(cache.cachedFile(forCacheKey: "a", accountId: "alice"))
        XCTAssertNotNil(cache.cachedFile(forCacheKey: "a", accountId: "bob"))
    }
}

//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatAudioMetadataTest: XCTestCase {

    private var directory: URL!
    private let key = ChatAudioKey(accountId: "alice@https://cloud.example.com", roomToken: "abc123", messageId: 7)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> ChatAudioMetadataStore {
        return ChatAudioMetadataStore(directory: directory)
    }

    func testOnlyLongRecordingsKeepTheirPosition() {
        let short = ChatAudioMetadata(duration: 60, position: 30)
        let long = ChatAudioMetadata(duration: 5 * 60, position: 30)

        XCTAssertEqual(short.persistablePosition, 0)
        XCTAssertEqual(long.persistablePosition, 30)
    }

    func testResumePositionStartsOverAtTheEnd() {
        XCTAssertEqual(ChatAudioMetadata(duration: 600, position: 120).resumePosition, 120)
        XCTAssertEqual(ChatAudioMetadata(duration: 600, position: 599.5).resumePosition, 0)
        XCTAssertEqual(ChatAudioMetadata(duration: 0, position: 12).resumePosition, 12)
        XCTAssertEqual(ChatAudioMetadata(duration: 600, position: 0).resumePosition, 0)
    }

    func testMetadataSurvivesARestart() {
        let store = makeStore()
        store.rememberDuration(600, for: key)
        store.rememberWaveform([0.1, 0.5, 1], for: key)
        store.rememberPosition(120, duration: 600, for: key)
        store.flush()

        let restored = makeStore().metadata(for: key)

        XCTAssertEqual(restored?.duration, 600)
        XCTAssertEqual(restored?.position, 120)
        XCTAssertEqual(restored?.waveform, [0.1, 0.5, 1])
    }

    func testPositionOfShortRecordingsIsNotPersisted() {
        let store = makeStore()
        store.rememberPosition(20, duration: 60, for: key)
        store.flush()

        XCTAssertEqual(store.metadata(for: key)?.position, 20)

        let restored = makeStore().metadata(for: key)
        XCTAssertEqual(restored?.duration, 60)
        XCTAssertEqual(restored?.position, 0)
    }

    func testEmptyWaveformIsRememberedForUndecodableFiles() {
        let store = makeStore()
        store.rememberWaveform([], for: key)
        store.flush()

        XCTAssertEqual(makeStore().metadata(for: key)?.waveform, [])
    }

    func testForgetPosition() {
        let store = makeStore()
        store.rememberPosition(400, duration: 600, for: key)
        store.forgetPosition(for: key)
        store.flush()

        XCTAssertEqual(makeStore().metadata(for: key)?.position, 0)
    }

    func testRemovingAnAccountForgetsOnlyItsMessages() {
        let otherKey = ChatAudioKey(accountId: "bob@https://cloud.example.com", roomToken: "abc123", messageId: 7)
        let store = makeStore()
        store.rememberDuration(10, for: key)
        store.rememberDuration(20, for: otherKey)

        store.removeAll(forAccountId: key.accountId)
        store.flush()

        XCTAssertNil(store.metadata(for: key))
        XCTAssertNil(makeStore().metadata(for: key))
        XCTAssertEqual(makeStore().metadata(for: otherKey)?.duration, 20)
    }

    func testInvalidValuesAreIgnored() {
        let store = makeStore()
        store.rememberDuration(.nan, for: key)
        store.rememberDuration(-1, for: key)

        XCTAssertNil(store.metadata(for: key))
    }

    func testWaveformReduction() {
        XCTAssertEqual(Waveforms.reduce([0.1, 0.2, 0.4, 0.2], to: 2), [0.5, 1])
        XCTAssertEqual(Waveforms.reduce([0.5], to: 3), [1, 1, 1])
        XCTAssertEqual(Waveforms.reduce([], to: 2), [0, 0])
        XCTAssertEqual(Waveforms.reduce([0, 0], to: 2), [0, 0])
        XCTAssertEqual(Waveforms.reduce([1, 2], to: 0), [])
    }
}

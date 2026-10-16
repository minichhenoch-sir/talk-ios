//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatAudioQueueTest: XCTestCase {

    private struct Message {
        let id: Int
        let kind: ChatAudioKind?
    }

    private func build(_ messages: [Message], startId: Int) -> ChatAudioQueue.Selection<Message>? {
        return ChatAudioQueue.build(messages: messages, startId: startId, idOf: { $0.id }, kindOf: { $0.kind })
    }

    func testVoiceMessagesContinueWithNewerVoiceMessagesOnly() {
        let messages = [
            Message(id: 1, kind: .voiceMessage),
            Message(id: 2, kind: .audioFile),
            Message(id: 3, kind: .voiceMessage),
            Message(id: 4, kind: nil),
            Message(id: 5, kind: .voiceMessage)
        ]

        let selection = build(messages, startId: 3)

        XCTAssertEqual(selection?.items.map(\.id), [3, 5])
        XCTAssertEqual(selection?.startIndex, 0)
    }

    func testAudioFilesQueueOnlyContainsAudioFiles() {
        let messages = [
            Message(id: 1, kind: .audioFile),
            Message(id: 2, kind: .voiceMessage),
            Message(id: 3, kind: .audioFile),
            Message(id: 4, kind: .audioFile)
        ]

        let selection = build(messages, startId: 3)

        XCTAssertEqual(selection?.items.map(\.id), [1, 3, 4])
        XCTAssertEqual(selection?.startIndex, 1)
    }

    func testAudioFilesQueueIsLimitedAroundTappedFile() {
        let messages = (1...200).map { Message(id: $0, kind: .audioFile) }

        let selection = build(messages, startId: 100)

        XCTAssertEqual(selection?.items.count, ChatAudioQueue.maxSize)
        XCTAssertEqual(selection?.items.first?.id, 75)
        XCTAssertEqual(selection?.items[selection?.startIndex ?? 0].id, 100)
    }

    func testAudioFilesQueueAtTheEdges() {
        let messages = (1...200).map { Message(id: $0, kind: .audioFile) }

        let first = build(messages, startId: 1)
        XCTAssertEqual(first?.items.first?.id, 1)
        XCTAssertEqual(first?.startIndex, 0)

        let last = build(messages, startId: 200)
        XCTAssertEqual(last?.items.count, ChatAudioQueue.maxSize)
        XCTAssertEqual(last?.items.last?.id, 200)
        XCTAssertEqual(last?.items[last?.startIndex ?? 0].id, 200)
    }

    func testVoiceMessageQueueIsLimited() {
        let messages = (1...80).map { Message(id: $0, kind: .voiceMessage) }

        let selection = build(messages, startId: 10)

        XCTAssertEqual(selection?.items.count, ChatAudioQueue.maxSize)
        XCTAssertEqual(selection?.items.first?.id, 10)
    }

    func testUnplayableOrUnknownMessageGivesNoQueue() {
        let messages = [Message(id: 1, kind: nil), Message(id: 2, kind: .audioFile)]

        XCTAssertNil(build(messages, startId: 1))
        XCTAssertNil(build(messages, startId: 3))
    }
}

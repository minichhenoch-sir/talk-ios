//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatAudioRepeatModeTest: XCTestCase {

    func testRepeatModeCycles() {
        XCTAssertEqual(ChatAudioRepeatMode.off.next, .all)
        XCTAssertEqual(ChatAudioRepeatMode.all.next, .one)
        XCTAssertEqual(ChatAudioRepeatMode.one.next, .off)
    }

    func testRepeatModeIsRestoredFromItsRawValue() {
        XCTAssertEqual(ChatAudioRepeatMode(rawValue: ChatAudioRepeatMode.one.rawValue), .one)
        XCTAssertNil(ChatAudioRepeatMode(rawValue: "unknown"))
    }

    func testOrderedQueueStopsAtTheEndWithoutRepeat() {
        var order = ChatAudioQueueOrder(count: 3, startIndex: 1, shuffled: false)

        XCTAssertEqual(order.currentIndex, 1)
        XCTAssertEqual(order.nextIndex(repeatMode: .off, userInitiated: false), 2)

        order.moveTo(index: 2)
        XCTAssertNil(order.nextIndex(repeatMode: .off, userInitiated: false))
        XCTAssertEqual(order.previousIndex(repeatMode: .off), 1)
    }

    func testRepeatAllWrapsAround() {
        var order = ChatAudioQueueOrder(count: 3, startIndex: 2, shuffled: false)

        XCTAssertEqual(order.nextIndex(repeatMode: .all, userInitiated: false), 0)

        order.moveTo(index: 0)
        XCTAssertEqual(order.previousIndex(repeatMode: .all), 2)
        XCTAssertNil(order.previousIndex(repeatMode: .off))
    }

    func testRepeatOneRepeatsUnlessTheUserSkips() {
        let order = ChatAudioQueueOrder(count: 3, startIndex: 0, shuffled: false)

        XCTAssertEqual(order.nextIndex(repeatMode: .one, userInitiated: false), 0)
        XCTAssertEqual(order.nextIndex(repeatMode: .one, userInitiated: true), 1)
    }

    func testShuffleStartsWithTheTappedItemAndKeepsAllItems() {
        let order = ChatAudioQueueOrder(count: 5, startIndex: 3, shuffled: true, randomIndices: { $0.reversed() })

        XCTAssertEqual(order.order, [3, 4, 2, 1, 0])
        XCTAssertEqual(order.currentIndex, 3)
        XCTAssertEqual(order.nextIndex(repeatMode: .off, userInitiated: false), 4)
    }

    func testTogglingShuffleKeepsTheCurrentItem() {
        var order = ChatAudioQueueOrder(count: 4, startIndex: 0, shuffled: false)
        order.moveTo(index: 2)

        order.setShuffled(true, randomIndices: { $0.reversed() })
        XCTAssertEqual(order.order, [2, 3, 1, 0])
        XCTAssertEqual(order.currentIndex, 2)

        order.setShuffled(false)
        XCTAssertEqual(order.order, [0, 1, 2, 3])
        XCTAssertEqual(order.currentIndex, 2)
        XCTAssertEqual(order.nextIndex(repeatMode: .off, userInitiated: false), 3)
    }

    func testEmptyQueue() {
        let order = ChatAudioQueueOrder(count: 0, startIndex: 0, shuffled: true)

        XCTAssertNil(order.currentIndex)
        XCTAssertNil(order.nextIndex(repeatMode: .all, userInitiated: true))
        XCTAssertNil(order.previousIndex(repeatMode: .all))
    }

    func testSpeedsCycle() {
        XCTAssertEqual(ChatAudioSpeed.next(after: 1.0), 1.5)
        XCTAssertEqual(ChatAudioSpeed.next(after: 1.5), 2.0)
        XCTAssertEqual(ChatAudioSpeed.next(after: 2.0), 1.0)
        XCTAssertEqual(ChatAudioSpeed.next(after: 3.0), 1.0)
    }
}

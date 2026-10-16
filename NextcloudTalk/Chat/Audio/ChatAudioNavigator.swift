//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum ChatAudioNavigator {

    /// Opens the conversation of the current track at its message, switching back to its account if needed.
    static func openCurrentMessage(of player: ChatAudioPlayer = .shared) {
        guard let key = player.state.currentTrack?.key,
              NCDatabaseManager.sharedInstance().talkAccount(forAccountId: key.accountId) != nil
        else { return }

        let roomsManager = NCRoomsManager.shared
        let activeAccountId = NCDatabaseManager.sharedInstance().activeAccount().accountId

        if activeAccountId == key.accountId,
           let chatViewController = roomsManager.chatViewController,
           chatViewController.room.token == key.roomToken,
           chatViewController.indexPathAndMessage(forMessageId: key.messageId) != nil {

            chatViewController.highlightMessageWithContentOffset(messageId: key.messageId)
            return
        }

        if activeAccountId != key.accountId {
            roomsManager.chatViewController?.leaveChat()
            NCSettingsController.sharedInstance().setActiveAccountWithAccountId(key.accountId)
        }

        let userInfo: [String: Any] = ["token": key.roomToken, "messageId": key.messageId]
        NotificationCenter.default.post(name: .NCPresentChatHighlightingMessage, object: self, userInfo: userInfo)
    }
}

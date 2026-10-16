//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

extension NCChatMessage {

    /// Voice messages and audio files can be played in the chat, other messages cannot.
    var chatAudioKind: ChatAudioKind? {
        if self.isVoiceMessage {
            return .voiceMessage
        }

        guard let file = self.file(), NCUtils.isAudio(fileType: file.mimetype ?? "") else { return nil }

        return .audioFile
    }

    func chatAudioKey(accountId: String) -> ChatAudioKey? {
        guard let token = self.token, !token.isEmpty else { return nil }

        return ChatAudioKey(accountId: accountId, roomToken: token, messageId: self.messageId)
    }

    func chatAudioTrack(for account: TalkAccount) -> ChatAudioTrack? {
        guard let kind = self.chatAudioKind,
              let file = self.file(),
              let key = self.chatAudioKey(accountId: account.accountId)
        else { return nil }

        var remoteURL: URL?

        if let path = file.path, !path.isEmpty {
            let encodedUserId = account.userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account.userId
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            remoteURL = URL(string: "\(account.server)/remote.php/dav/files/\(encodedUserId)/\(encodedPath)")
        }

        var localFileURL: URL?

        if let fileLocalPath = file.fileStatus?.fileLocalPath, !fileLocalPath.isEmpty {
            localFileURL = URL(fileURLWithPath: fileLocalPath)
        }

        guard remoteURL != nil || localFileURL != nil else { return nil }

        let cacheKey = ChatAudioTrack.cacheKey(server: account.server, fileId: file.parameterId, etag: file.etag, fallbackURL: remoteURL?.absoluteString ?? localFileURL?.path ?? "")
        let actorDisplayName = self.actorDisplayName ?? ""
        let fileName = file.name

        return ChatAudioTrack(key: key,
                              kind: kind,
                              remoteURL: remoteURL,
                              localFileURL: localFileURL,
                              cacheKey: cacheKey,
                              mimeType: file.mimetype,
                              title: kind == .audioFile && !fileName.isEmpty ? fileName : actorDisplayName,
                              subtitle: kind == .voiceMessage ? NSLocalizedString("Voice message", comment: "") : actorDisplayName,
                              actorId: self.actorId,
                              actorType: self.actorType,
                              actorDisplayName: actorDisplayName)
    }
}

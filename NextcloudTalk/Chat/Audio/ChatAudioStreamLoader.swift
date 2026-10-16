//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import UniformTypeIdentifiers

/// Streams an audio file through the app's own URL session into the audio cache, so playback can start while the file
/// is still downloading. Requests far ahead of the download are fetched separately with a range request.
final class ChatAudioStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {

    static let customScheme = "nctalk-audio"
    static let errorDomain = "ChatAudioStreamLoader"
    private static let maxResponseChunk = 512 * 1024
    private static let rangeRequestDistance: Int64 = 2 * 1024 * 1024

    let remoteURL: URL
    let cacheKey: String
    let accountId: String
    private let authHeader: String?
    private let fallbackContentType: String?
    private let cache: ChatAudioCache
    private let queue = DispatchQueue(label: "com.nextcloud.talk.chataudio.loader")

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    // All state below is accessed on `queue` only
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var downloadTask: URLSessionDataTask?
    private var rangeTasks: [URLSessionDataTask: (request: AVAssetResourceLoadingRequest, offset: Int64)] = [:]
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    private var readURL: URL?
    private var downloadedBytes: Int64 = 0
    private var contentLength: Int64?
    private var contentType: String?
    private var isComplete = false
    private var isCancelled = false
    private var downloadError: Error?

    /// Called on the main queue once the whole file is in the cache.
    var onDownloadComplete: ((URL) -> Void)?

    init(remoteURL: URL, cacheKey: String, accountId: String, authHeader: String?, mimeType: String?, cache: ChatAudioCache = .shared) {
        self.remoteURL = remoteURL
        self.cacheKey = cacheKey
        self.accountId = accountId
        self.authHeader = authHeader
        self.fallbackContentType = mimeType.flatMap { UTType(mimeType: $0)?.identifier }
        self.cache = cache
        super.init()

        cache.beginUse(cacheKey: cacheKey)
    }

    deinit {
        cache.endUse(cacheKey: cacheKey)
    }

    func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
        components?.scheme = ChatAudioStreamLoader.customScheme
        let asset = AVURLAsset(url: components?.url ?? remoteURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func cancel() {
        queue.async {
            self.isCancelled = true
            self.downloadTask?.cancel()
            self.downloadTask = nil
            self.rangeTasks.keys.forEach { $0.cancel() }
            self.rangeTasks.removeAll()
            self.session.invalidateAndCancel()
            self.closeHandles()
            self.pendingRequests.forEach { $0.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)) }
            self.pendingRequests.removeAll()
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !isCancelled else { return false }

        if let dataRequest = loadingRequest.dataRequest, !isComplete, contentLength != nil,
           dataRequest.requestedOffset > downloadedBytes + ChatAudioStreamLoader.rangeRequestDistance {
            startRangeRequest(for: loadingRequest, offset: dataRequest.requestedOffset)
            return true
        }

        pendingRequests.append(loadingRequest)

        if downloadTask == nil, !isComplete {
            startDownload()
        }

        processPendingRequests()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingRequests.removeAll { $0 === loadingRequest }

        for (task, entry) in rangeTasks where entry.request === loadingRequest {
            task.cancel()
            rangeTasks.removeValue(forKey: task)
        }
    }

    // MARK: - Download

    private func makeRequest(range: String?) -> URLRequest {
        var request = URLRequest(url: remoteURL)
        request.setValue(NCAppBranding.userAgent(), forHTTPHeaderField: "User-Agent")

        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        return request
    }

    private func startDownload() {
        cache.prepareDirectory(forAccountId: accountId)

        let partialURL = cache.partialFileURL(forCacheKey: cacheKey, accountId: accountId)
        let existingSize = ((try? FileManager.default.attributesOfItem(atPath: partialURL.path))?[.size] as? NSNumber)?.int64Value ?? 0

        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }

        downloadError = nil
        downloadedBytes = existingSize
        readURL = partialURL

        // A partial file from an earlier attempt is continued instead of downloaded again
        let task = session.dataTask(with: makeRequest(range: existingSize > 0 ? "bytes=\(existingSize)-" : nil))
        downloadTask = task
        task.resume()
    }

    private func startRangeRequest(for loadingRequest: AVAssetResourceLoadingRequest, offset: Int64) {
        guard let dataRequest = loadingRequest.dataRequest else { return }

        let range: String
        if dataRequest.requestsAllDataToEndOfResource {
            range = "bytes=\(offset)-"
        } else {
            range = "bytes=\(offset)-\(offset + Int64(dataRequest.requestedLength) - 1)"
        }

        let task = session.dataTask(with: makeRequest(range: range))
        rangeTasks[task] = (loadingRequest, offset)
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let error = NSError(domain: ChatAudioStreamLoader.errorDomain, code: httpResponse.statusCode)
            fail(task: dataTask, with: error)
            completionHandler(.cancel)
            return
        }

        if contentType == nil, let mimeType = httpResponse.mimeType, mimeType != "application/octet-stream" {
            contentType = UTType(mimeType: mimeType)?.identifier
        }

        if let entry = rangeTasks[dataTask] {
            // A server that ignores the range would send the file from the start
            if httpResponse.statusCode != 206 {
                rangeTasks.removeValue(forKey: dataTask)
                pendingRequests.append(entry.request)
                completionHandler(.cancel)
                processPendingRequests()
                return
            }

            completionHandler(.allow)
            return
        }

        if httpResponse.statusCode == 206, let total = ChatAudioStreamLoader.totalLength(fromContentRange: httpResponse.value(forHTTPHeaderField: "Content-Range")) {
            contentLength = total
        } else {
            // The server sent the whole file, so an earlier partial download is useless
            downloadedBytes = 0
            try? FileManager.default.removeItem(at: cache.partialFileURL(forCacheKey: cacheKey, accountId: accountId))
            FileManager.default.createFile(atPath: cache.partialFileURL(forCacheKey: cacheKey, accountId: accountId).path, contents: nil)
            closeHandles()

            if httpResponse.expectedContentLength > 0 {
                contentLength = httpResponse.expectedContentLength
            }
        }

        let partialURL = cache.partialFileURL(forCacheKey: cacheKey, accountId: accountId)
        writeHandle = try? FileHandle(forWritingTo: partialURL)
        _ = try? writeHandle?.seekToEnd()

        completionHandler(.allow)
        processPendingRequests()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let entry = rangeTasks[dataTask] {
            entry.request.dataRequest?.respond(with: data)
            rangeTasks[dataTask] = (entry.request, entry.offset + Int64(data.count))
            return
        }

        guard let writeHandle else { return }

        do {
            try writeHandle.write(contentsOf: data)
            downloadedBytes += Int64(data.count)
        } catch {
            dataTask.cancel()
            return
        }

        processPendingRequests()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let dataTask = task as? URLSessionDataTask, let entry = rangeTasks.removeValue(forKey: dataTask) {
            if let error {
                if (error as NSError).code != NSURLErrorCancelled {
                    entry.request.finishLoading(with: error)
                }
            } else {
                entry.request.finishLoading()
            }
            return
        }

        guard task == downloadTask else { return }

        downloadTask = nil
        try? writeHandle?.close()
        writeHandle = nil

        if let error {
            guard (error as NSError).code != NSURLErrorCancelled || !isCancelled else { return }

            // The partial file stays, so a retry continues where this download stopped
            downloadError = error
            pendingRequests.forEach { $0.finishLoading(with: error) }
            pendingRequests.removeAll()
            return
        }

        if let contentLength, downloadedBytes < contentLength {
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
            downloadError = error
            pendingRequests.forEach { $0.finishLoading(with: error) }
            pendingRequests.removeAll()
            return
        }

        contentLength = downloadedBytes
        isComplete = true

        try? readHandle?.close()
        readHandle = nil

        if let completeURL = cache.completeDownload(forCacheKey: cacheKey, accountId: accountId) {
            readURL = completeURL

            DispatchQueue.main.async {
                self.onDownloadComplete?(completeURL)
            }
        }

        processPendingRequests()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Certificates the user accepted for the account are accepted here as well
        if let serverTrust = challenge.protectionSpace.serverTrust, CCCertificate.sharedManager().checkTrustedChallenge(challenge) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Responding

    private func processPendingRequests() {
        pendingRequests.removeAll { request in
            if let infoRequest = request.contentInformationRequest {
                guard let contentLength else { return false }

                infoRequest.contentLength = contentLength
                infoRequest.contentType = contentType ?? fallbackContentType ?? UTType.audio.identifier
                infoRequest.isByteRangeAccessSupported = true
            }

            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return true
            }

            if respond(to: dataRequest) {
                request.finishLoading()
                return true
            }

            return false
        }
    }

    /// - Returns: whether the data request got everything it asked for.
    private func respond(to dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
        let start = dataRequest.currentOffset
        let requestedEnd: Int64

        if dataRequest.requestsAllDataToEndOfResource {
            guard let contentLength else { return false }
            requestedEnd = contentLength
        } else {
            requestedEnd = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        }

        var offset = start

        while offset < min(requestedEnd, downloadedBytes) {
            let length = Int(min(Int64(ChatAudioStreamLoader.maxResponseChunk), min(requestedEnd, downloadedBytes) - offset))

            guard let data = readData(at: offset, length: length), !data.isEmpty else { break }

            dataRequest.respond(with: data)
            offset += Int64(data.count)
        }

        return offset >= requestedEnd
    }

    private func readData(at offset: Int64, length: Int) -> Data? {
        if readHandle == nil, let readURL {
            readHandle = try? FileHandle(forReadingFrom: readURL)
        }

        guard let readHandle else { return nil }

        do {
            try readHandle.seek(toOffset: UInt64(offset))
            return try readHandle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    private func fail(task: URLSessionDataTask, with error: Error) {
        if let entry = rangeTasks.removeValue(forKey: task) {
            entry.request.finishLoading(with: error)
            return
        }

        downloadError = error
        pendingRequests.forEach { $0.finishLoading(with: error) }
        pendingRequests.removeAll()
    }

    private func closeHandles() {
        try? writeHandle?.close()
        writeHandle = nil
        try? readHandle?.close()
        readHandle = nil
    }

    static func totalLength(fromContentRange contentRange: String?) -> Int64? {
        // "bytes 100-199/1234"
        guard let contentRange, let total = contentRange.split(separator: "/").last else { return nil }

        return Int64(total.trimmingCharacters(in: .whitespaces))
    }
}

extension ChatAudioError {

    /// Maps an error of an `AVPlayerItem` or of the stream loader to what is shown to the user.
    static func from(_ error: Error?) -> ChatAudioError {
        var current = error as NSError?

        while let nsError = current {
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorFileDoesNotExist, NSURLErrorNoPermissionsToReadFile:
                    return .unavailable
                default:
                    return .network
                }
            }

            if nsError.domain == ChatAudioStreamLoader.errorDomain {
                return [401, 403, 404, 410].contains(nsError.code) ? .unavailable : .unknown
            }

            // AVErrorFileFormatNotRecognized, AVErrorFailedToParse, AVErrorDecoderNotFound, AVErrorDecodeFailed
            if nsError.domain == AVFoundationErrorDomain, [-11828, -11829, -11833, -11821].contains(nsError.code) {
                return .unsupported
            }

            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return .unknown
    }
}

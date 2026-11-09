import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Downloads a song once and feeds AVPlayer from the downloaded bytes as they arrive, so playback starts
/// right away without a second, separate stream. When the download finishes, the file is handed to the cache.
final class DownloadingLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private static let scheme = "jellyplayer-cache"

    private let remoteURL: URL
    private let headers: [String: String]
    private let onComplete: @Sendable (Data, String) -> Void
    private let queue = DispatchQueue(label: "pw.napps.JellyPlayer.loader")

    // Only touched on `queue`.
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var finished = false
    private var totalLength: Int64 = -1
    private var mimeType = ""
    private var retries = 0
    private var pending: [AVAssetResourceLoadingRequest] = []

    private let progressLock = NSLock()
    private var downloadedFraction: Double = 0
    /// How much of the song has been downloaded, from 0 to 1. Safe to read from any thread.
    var progress: Double {
        progressLock.lock(); defer { progressLock.unlock() }
        return downloadedFraction
    }

    private func setProgress(_ value: Double) {
        progressLock.lock(); downloadedFraction = value; progressLock.unlock()
    }

    init(remoteURL: URL, headers: [String: String], onComplete: @escaping @Sendable (Data, String) -> Void) {
        self.remoteURL = remoteURL
        self.headers = headers
        self.onComplete = onComplete
        super.init()
    }

    /// An asset whose bytes come from this loader.
    func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func cancel() {
        queue.async { [self] in
            task?.cancel()
            session?.invalidateAndCancel()
            session = nil
            pending.removeAll()
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if task == nil { startDownload() }
        pending.append(loadingRequest)
        processPending()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }

    // MARK: Download

    /// Starts (or, after a dropped connection, resumes) the download from the bytes already received.
    private func startDownload() {
        if session == nil {
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        }
        var request = URLRequest(url: remoteURL)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if !data.isEmpty { request.setValue("bytes=\(data.count)-", forHTTPHeaderField: "Range") }
        let task = session!.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        if http.statusCode == 200 {
            // Full file (first request, or a server that ignored the resume range): start over.
            data.removeAll(keepingCapacity: true)
            totalLength = http.expectedContentLength
            if totalLength > 0 { data.reserveCapacity(Int(totalLength)) }
        } else if http.statusCode != 206 {
            completionHandler(.cancel)
            fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
            return
        }
        if self.response == nil || http.statusCode == 200 {
            self.response = http
            mimeType = http.mimeType ?? ""
        }
        completionHandler(.allow)
        processPending()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        if totalLength > 0 { setProgress(min(1, Double(data.count) / Double(totalLength))) }
        processPending()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            // Keep the pieces we have and resume from there, like a torrent client would.
            if retries < 5, !data.isEmpty || response == nil {
                retries += 1
                queue.asyncAfter(deadline: .now() + Double(retries)) { [self] in
                    if self.session != nil { startDownload() }
                }
            } else {
                fail(error)
            }
            return
        }
        guard response != nil, totalLength <= 0 || Int64(data.count) >= totalLength else {
            // Connection ended early without an error: resume.
            if retries < 5 { retries += 1; startDownload() } else { fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)) }
            return
        }
        finished = true
        setProgress(1)
        session.finishTasksAndInvalidate()
        processPending()
        onComplete(data, mimeType)
    }

    private func fail(_ error: Error) {
        pending.forEach { $0.finishLoading(with: error) }
        pending.removeAll()
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: Serving bytes

    private func processPending() {
        pending.removeAll { fill($0) }
    }

    /// Answers as much of the request as has downloaded. Returns true once the request is complete.
    private func fill(_ request: AVAssetResourceLoadingRequest) -> Bool {
        guard response != nil else { return false }
        let available = Int64(data.count)

        if let info = request.contentInformationRequest {
            let length = totalLength > 0 ? totalLength : (finished ? available : -1)
            guard length > 0 else { return false } // size unknown until the download ends
            info.contentType = UTType(mimeType: mimeType)?.identifier ?? UTType.mp3.identifier
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let start = dataRequest.currentOffset
        let requestedEnd = dataRequest.requestsAllDataToEndOfResource
            ? Int64.max
            : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        if start < available {
            let end = min(available, requestedEnd)
            dataRequest.respond(with: data.subdata(in: Int(start)..<Int(end)))
        }

        let done = dataRequest.currentOffset >= requestedEnd || (finished && dataRequest.currentOffset >= available)
        if done { request.finishLoading() }
        return done
    }
}

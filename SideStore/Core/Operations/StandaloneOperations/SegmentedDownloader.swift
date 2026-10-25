//
//  SegmentedDownloader.swift
//  SideStore
//
//  Downloads one file over several HTTP Range requests so a slow mirror can be saturated.
//

import Foundation

/// Foundation-only downloader, deliberately independent of the app types so it can be exercised
/// on its own. Callers must fall back to a single request when `Failure.rangeNotSupported` is
/// thrown.
final class SegmentedDownloader: @unchecked Sendable
{
    struct Configuration: Sendable
    {
        /// Hard cap, not a target: small files use fewer connections.
        var maximumConnections = 32
        /// A file smaller than two segments is left to the single-connection downloader.
        var minimumSegmentSize: Int64 = 1_048_576
        var requestTimeout: TimeInterval = 20
        var resourceTimeout: TimeInterval = 180
    }

    enum Failure: Error
    {
        case rangeNotSupported
        case invalidResponse(statusCode: Int)
        case unexpectedSize(expected: Int64, received: Int64)
        case cancelled
    }

    private let url: URL
    private let destinationURL: URL
    private let configuration: Configuration
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var coordinator: Coordinator?

    init(url: URL,
         destinationURL: URL,
         configuration: Configuration = Configuration(),
         progress: (@Sendable (Int64, Int64) -> Void)? = nil)
    {
        self.url = url
        self.destinationURL = destinationURL
        self.configuration = configuration
        self.progress = progress
    }

    func download() async throws
    {
        let totalSize = try await self.probe()
        let connectionCount = min(Int(self.configuration.maximumConnections), Int(totalSize / self.configuration.minimumSegmentSize))
        guard connectionCount > 1 else { throw Failure.rangeNotSupported }

        let coordinator = Coordinator(
            url: self.url,
            destinationURL: self.destinationURL,
            totalSize: totalSize,
            connectionCount: connectionCount,
            configuration: self.configuration,
            progress: self.progress
        )
        self.lock.withLock { self.coordinator = coordinator }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.start { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    func cancel()
    {
        self.lock.withLock { self.coordinator }?.cancel()
    }

    /// A HEAD request is enough for the mirrors that advertise ranges. A host that refuses HEAD
    /// (or does not advertise byte ranges) simply gets the single-connection path.
    private func probe() async throws -> Int64
    {
        var request = URLRequest(url: self.url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = self.configuration.requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.rangeNotSupported
        }
        if let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased(), acceptRanges != "bytes" {
            throw Failure.rangeNotSupported
        }
        guard let totalSize = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), totalSize > 0 else {
            throw Failure.rangeNotSupported
        }
        return totalSize
    }
}

private final class Coordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable
{
    private struct Segment
    {
        let start: Int64
        let end: Int64
        var received: Int64 = 0
    }

    private let url: URL
    private let destinationURL: URL
    private let totalSize: Int64
    private let connectionCount: Int
    private let configuration: SegmentedDownloader.Configuration
    private let progressHandler: (@Sendable (Int64, Int64) -> Void)?

    private let queue: OperationQueue
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var segments: [Int: Segment] = [:]
    private var remainingSegments = 0
    private var totalReceived: Int64 = 0
    private var lastProgressAt: CFAbsoluteTime = 0
    private var completion: ((Result<URL, Error>) -> Void)?
    private var isFinished = false

    init(url: URL,
         destinationURL: URL,
         totalSize: Int64,
         connectionCount: Int,
         configuration: SegmentedDownloader.Configuration,
         progress: (@Sendable (Int64, Int64) -> Void)?)
    {
        self.url = url
        self.destinationURL = destinationURL
        self.totalSize = totalSize
        self.connectionCount = connectionCount
        self.configuration = configuration
        self.progressHandler = progress
        self.queue = OperationQueue()
        self.queue.maxConcurrentOperationCount = 1
        self.queue.qualityOfService = .userInitiated
        super.init()
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void)
    {
        self.completion = completion

        do
        {
            try? FileManager.default.removeItem(at: self.destinationURL)
            guard FileManager.default.createFile(atPath: self.destinationURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: self.destinationURL)
            try handle.truncate(atOffset: UInt64(self.totalSize))
            self.fileHandle = handle
        }
        catch
        {
            self.finish(.failure(error))
            return
        }

        self.progressHandler?(0, self.totalSize)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = self.configuration.requestTimeout
        configuration.timeoutIntervalForResource = self.configuration.resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // URLSession defaults to six connections per host; the whole point here is to exceed that.
        configuration.httpMaximumConnectionsPerHost = self.connectionCount

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: self.queue)
        self.session = session

        var tasks: [URLSessionDataTask] = []
        for index in 0..<self.connectionCount
        {
            let start = self.totalSize * Int64(index) / Int64(self.connectionCount)
            let end = self.totalSize * Int64(index + 1) / Int64(self.connectionCount) - 1
            guard end >= start else { continue }

            var request = URLRequest(url: self.url)
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            request.timeoutInterval = self.configuration.requestTimeout

            let task = session.dataTask(with: request)
            self.segments[task.taskIdentifier] = Segment(start: start, end: end)
            tasks.append(task)
        }

        self.remainingSegments = tasks.count
        tasks.forEach { $0.resume() }
    }

    func cancel()
    {
        self.queue.addOperation { [weak self] in
            guard let self, !self.isFinished else { return }
            self.finish(.failure(SegmentedDownloader.Failure.cancelled))
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    {
        guard let http = response as? HTTPURLResponse else {
            self.finish(.failure(SegmentedDownloader.Failure.invalidResponse(statusCode: -1)))
            completionHandler(.cancel)
            return
        }

        if http.statusCode == 200
        {
            // The host ignored the Range header; the caller has to use one connection.
            self.finish(.failure(SegmentedDownloader.Failure.rangeNotSupported))
            completionHandler(.cancel)
            return
        }

        guard http.statusCode == 206 else {
            self.finish(.failure(SegmentedDownloader.Failure.invalidResponse(statusCode: http.statusCode)))
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
    {
        guard var segment = self.segments[dataTask.taskIdentifier], let handle = self.fileHandle else { return }

        do
        {
            try handle.seek(toOffset: UInt64(segment.start + segment.received))
            try handle.write(contentsOf: data)
            segment.received += Int64(data.count)
            self.segments[dataTask.taskIdentifier] = segment
            self.totalReceived += Int64(data.count)
            self.reportProgress()
        }
        catch
        {
            self.finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        guard let segment = self.segments[task.taskIdentifier] else { return }

        if let error
        {
            self.finish(.failure(error))
            return
        }

        let expected = segment.end - segment.start + 1
        guard segment.received == expected else {
            self.finish(.failure(SegmentedDownloader.Failure.unexpectedSize(expected: expected, received: segment.received)))
            return
        }

        self.segments[task.taskIdentifier] = nil
        self.remainingSegments -= 1

        if self.remainingSegments == 0
        {
            self.progressHandler?(self.totalReceived, self.totalSize)
            self.finish(.success(self.destinationURL))
        }
    }

    // MARK: - Private

    private func reportProgress()
    {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - self.lastProgressAt >= 0.15 else { return }
        self.lastProgressAt = now
        self.progressHandler?(self.totalReceived, self.totalSize)
    }

    private func finish(_ result: Result<URL, Error>)
    {
        guard !self.isFinished else { return }
        self.isFinished = true

        self.session?.invalidateAndCancel()
        self.session = nil
        try? self.fileHandle?.close()
        self.fileHandle = nil

        if case .failure = result
        {
            try? FileManager.default.removeItem(at: self.destinationURL)
        }

        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

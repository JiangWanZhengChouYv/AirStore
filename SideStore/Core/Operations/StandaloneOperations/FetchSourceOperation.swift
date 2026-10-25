//
//  FetchSourceOperation.swift
//  AltStore
//
//  Created by Riley Testut on 7/30/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
import SemanticVersion

final class FetchSourceOperation: BaseStandaloneOperation<StandaloneOperationContext, Source>, @unchecked Sendable {
    let sourceURL: URL
    
    // Non-nil when updating an existing source.
    @Managed
    private var source: Source?
    
    private let session: URLSession
    private weak var dataTask: URLSessionDataTask?

    
    private lazy var dateFormatter: ISO8601DateFormatter = {
        let dateFormatter = ISO8601DateFormatter()
        return dateFormatter
    }()
    
    init(sourceURL: URL, context: StandaloneOperationContext) throws {
        self.sourceURL = sourceURL
        self.session = URLSession.shared
        try super.init(context: context)
    }
    
    init(source: Source, context: StandaloneOperationContext) throws {
        self.sourceURL = source.sourceURL
        self.session = URLSession.shared
        try super.init(context: context)
        context.dbBackgroundContext.performAndWait {
            self.source = context.dbBackgroundContext.object(with: source.objectID) as? Source
        }
    }
    
    override func cancel() {
        super.cancel()
        
        self.dataTask?.cancel()
    }
    
    override func execute(parentProgress: Progress?) async throws -> Source {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[FetchSourceOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[FetchSourceOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let dbContext = self.context.dbBackgroundContext
        
        if let source = self.source {
            // Check if source is blocked before fetching it.
            let sourceObjectID = source.objectID
            try dbContext.performAndWait {
                try self.verifyExistingSource(sourceObjectID)
            }
        }
        
        let (data, response) = try await self.fetchSourceData(mirroring: self.sourceURL)
        
        let childContext = DatabaseManager.shared.persistentContainer.newBackgroundContext(parent: dbContext)
        childContext.mergePolicy = NSOverwriteMergePolicy
        
        let identifier = try await childContext.perform {
            let identifier = try self.performDecodeAndSave(data: data, response: response, childContext: childContext)
            try childContext.save()
            return identifier
        }
        
        let fetchedSource = try dbContext.performAndWait {
            if let source = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), identifier), in: dbContext) {
                return source
            } else {
                throw OperationError.noSources
            }
        }
        self.setProgress(100)
        return fetchedSource
    }
    
    /// Fetch the source through the best route for the URL: jsDelivr for raw GitHub files, gh-proxy
    /// when the CDN cannot serve it, the origin as the last resort.
    ///
    /// The URL kept in CoreData stays exactly what the user subscribed to, because `Source.identifier`
    /// is derived from it -- rewriting it here instead of there is what stops everyone from ending up
    /// with a second "AirStore Official" after this ships. A miss only costs one extra round trip and
    /// never a failed fetch.
    private func fetchSourceData(mirroring url: URL) async throws -> (Data, URLResponse)
    {
        var lastError: Error?

        for candidate in url.downloadCandidates
        {
            do
            {
                let (data, response) = try await self.fetchSourceData(with: self.request(for: candidate))
                guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
                    // A 404 from a mirror still comes back as a response with a body, so without this
                    // check the fallback would never run and the decode would fail on error text.
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw OperationError.invalidResponse(reason: "\(candidate.host ?? "server") answered HTTP \(code)")
                }

                if candidate != url
                {
                    self.debugLog("[FetchSourceOperation] Fetched \(url.absoluteString) via \(candidate.host ?? candidate.absoluteString).")
                }
                return (data, response)
            }
            catch let error as URLError where error.code == .cancelled
            {
                throw error
            }
            catch
            {
                lastError = error
                self.debugLog("[FetchSourceOperation] \(candidate.host ?? candidate.absoluteString) could not serve \(url.absoluteString): \(error.localizedDescription)")
            }
        }

        throw lastError ?? OperationError.invalidResponse(reason: "No route could fetch \(url.absoluteString)")
    }

    private func request(for url: URL) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData     // don't use local caching
        request.timeoutInterval = AppConstants.Sources.fetchTimeout
        return request
    }

    private func fetchSourceData(with request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let dataTask = self.session.dataTask(with: request) { (data, response, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: OperationError.invalidResponse(reason: "\(URLError(.badServerResponse).localizedDescription): Server returned no data or response."))
                }
            }
            dataTask.resume()
            self.dataTask = dataTask
        }
    }
    
    private func verifyExistingSource(_ sourceObjectID: NSManagedObjectID) throws {
        let source = self.context.dbBackgroundContext.object(with: sourceObjectID) as! Source
        try self.verifySourceNotBlocked(source, response: nil)
    }
    
    private func performDecodeAndSave(data: Data, response: URLResponse, childContext: NSManagedObjectContext) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ (decoder) -> Date in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            
            // Full ISO8601 Format.
            self.dateFormatter.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
            if let date = self.dateFormatter.date(from: text) {
                return date
            }
            
            // Just date portion of ISO8601.
            self.dateFormatter.formatOptions = [.withFullDate]
            if let date = self.dateFormatter.date(from: text) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date is in invalid format.")
        })
        
        decoder.managedObjectContext = childContext
        decoder.sourceURL = self.sourceURL
        
        decoder.allowsJSON5 = true
        
        let source: Source
        
        do {
            source = try decoder.decode(Source.self, from: data)
        } catch let error as DecodingError {
            let debugDescription: String
            let codingPath: [CodingKey]
            switch error {
            case .typeMismatch(let type, let context):
                debugDescription = "Type mismatch for type \(type). \(context.debugDescription)"
                codingPath = context.codingPath
            case .valueNotFound(let type, let context):
                debugDescription = "Value of type \(type) not found. \(context.debugDescription)"
                codingPath = context.codingPath
            case .keyNotFound(let key, let context):
                debugDescription = "Key '\(key.stringValue)' not found. \(context.debugDescription)"
                codingPath = context.codingPath + [key]
            case .dataCorrupted(let context):
                debugDescription = "Data corrupted. \(context.debugDescription)"
                codingPath = context.codingPath
            @unknown default:
                debugDescription = error.localizedDescription
                codingPath = []
            }
            
            let pathDescription = codingPath.map { $0.intValue?.description ?? $0.stringValue }.joined(separator: " > ")
            let detailedMessage = "Decoding failed: \(debugDescription) at path: \(pathDescription)"
            
            throw NSError(domain: "io.sidestore.SideStore.DecodingError", code: 0, userInfo: [
                NSLocalizedDescriptionKey: detailedMessage,
                NSDebugDescriptionErrorKey: detailedMessage
            ])
        }
        
        let identifier = source.identifier
        
        try self.verify(source, response: response)
        
        return identifier
    }
    
    private func verify(_ source: Source, response: URLResponse) throws {
        try self.verifySourceNotBlocked(source, response: response)
        
        var bundleIDs = Set<String>()
        var duplicateApps = [StoreApp]()
        
        for app in source.apps {
            if bundleIDs.contains(app.bundleIdentifier) {
                duplicateApps.append(app)
                continue
            }
            bundleIDs.insert(app.bundleIdentifier)
            
            var versions = Set<String>()
            var duplicateVersions = [AppVersion]()
            for version in app.versions {
                if versions.contains(version.versionID) {
                    duplicateVersions.append(version)
                    continue
                }
                versions.insert(version.versionID)
            }
            
            for version in duplicateVersions {
                debugLog("[FetchSourceOperation]: Warning: Skipping duplicate version '\(version.version)' for app '\(app.name)' (\(app.bundleIdentifier)).")
                version.managedObjectContext?.delete(version)
            }
            
            for permission in app.permissions where permission.type == .privacy {
                // Privacy permissions MUST have a usage description.
                guard permission.usageDescription != nil else { throw SourceError.missingPermissionUsageDescription(for: permission.permission, app: app, source: source) }
            }
            
            for screenshot in app.screenshots(for: .ipad) {
                // All iPad screenshots MUST have an explicit size.
                guard screenshot.size != nil else { throw SourceError.missingScreenshotSize(for: screenshot, source: source) }
            }
            
            #if MARKETPLACE
            guard app.marketplaceID != nil else { throw SourceError.marketplaceRequired(source: source) }
            #else
            guard app.marketplaceID == nil else { throw SourceError.marketplaceNotSupported(source: source) }
            #endif
        }
        
        for app in duplicateApps {
            debugLog("[FetchSourceOperation]: Warning: Skipping duplicate app '\(app.name)' (\(app.bundleIdentifier)) in source '\(source.name)'.")
            app.managedObjectContext?.delete(app)
        }
        
        let incomingSourceID = source.identifier
        if let previousSourceID = self.$source.identifier,
           incomingSourceID != previousSourceID {
//            if let version = BuildInfo().marketing_version,
//               SemanticVersion(version)! <= SemanticVersion("0.6.1")!
//            {
//                // delete the source, so that incoming will be saved.
//                self.source?.managedObjectContext?.delete(self.source!)
//            }
//            else
//            {
                throw SourceError.changedID(source.identifier, previousID: self.$source.identifier ?? "nil", source: source)
//            }
        }
    }
    
    private func verifySourceNotBlocked(_ source: Source, response: URLResponse?) throws {
        guard let blockedSources = UserDefaults.standard.blockedSources else { return }
        
        for blockedSource in blockedSources {
            guard
                source.identifier != blockedSource.identifier,
                source.sourceURL.absoluteString.lowercased() != blockedSource.sourceURL?.absoluteString.lowercased()
            else { throw SourceError.blocked(source, bundleIDs: blockedSource.bundleIDs, existingSource: self.source) }
            
            if let responseURL = response?.url {
                // responseURL may differ from source.sourceURL (e.g. due to redirects), so double-check it's also not blocked.
                guard responseURL.absoluteString.lowercased() != blockedSource.sourceURL?.absoluteString.lowercased() else {
                    throw SourceError.blocked(source, bundleIDs: blockedSource.bundleIDs, existingSource: self.source)
                }
            }
        }
    }
}

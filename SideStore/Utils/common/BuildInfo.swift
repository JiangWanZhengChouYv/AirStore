//
//  BuildInfo.swift
//  SideStore
//
//  Created by Magesh K on 23/03/25.
//  Copyright © 2025 SideStore. All rights reserved.
//

import Foundation

public class BuildInfo{
    private static let marketingVersionTag        = "CFBundleShortVersionString"
    private static let currentProjectVersionTag  = kCFBundleVersionKey as String
    
    private static let xcodeVersionTag  = "DTXcode"
    private static let xcodeRevisionTag = "DTXcodeBuild"

    let bundle: Bundle
    
    public init(){
        bundle = Bundle.main
    }
    
    enum BundleError: Swift.Error {
        case invalidURL
    }

    public init(url: URL) throws {
        guard let bundle = Bundle(url: url) else {
            throw BundleError.invalidURL
        }
        self.bundle = bundle
    }

    public lazy var projectVersion: String? = {
        let version  = bundle.object(forInfoDictionaryKey: Self.currentProjectVersionTag) as? String
        return version
    }()

    public lazy var marketingVersion: String? = {
        let version  = bundle.object(forInfoDictionaryKey: Self.marketingVersionTag) as? String
        return version
    }()

    public lazy var xcode: String? = {
        let xcode  = bundle.object(forInfoDictionaryKey: Self.xcodeVersionTag) as? String
        return xcode
    }()

    public lazy var xcodeRevision: String? = {
        let revision  = bundle.object(forInfoDictionaryKey: Self.xcodeRevisionTag) as? String
        return revision
    }()
}

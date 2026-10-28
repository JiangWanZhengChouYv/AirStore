//
//  ReleaseTrack11To17_1MigrationPolicy.swift
//  AltStore
//
//  Created by Magesh K on 15/03/25.
//  Copyright © 2025 SideStore. All rights reserved.
//

// swiftlint:disable type_name -- Core Data addresses this policy by its literal name inside the
// mapping model's xcmapping.xml, and the `_1` in that name is what the rule rejects. Renaming it
// would not fail the build; it would make migrations from those versions silently skip the policy.
import CoreData

@objc(ReleaseTrack11To17_1MigrationPolicy)
class ReleaseTrack11To17_1MigrationPolicy: ReleaseTrack17To17_1MigrationPolicy {
    
    override func createDestinationInstances(forSource sInstance: NSManagedObject, in mapping: NSEntityMapping, manager: NSMigrationManager) throws {
        try super.createDestinationInstances(forSource: sInstance, in: mapping, manager: manager)
    }
    
    
    override func createRelationships(
        forDestination dInstance: NSManagedObject,
        in mapping: NSEntityMapping,
        manager: NSMigrationManager
    ) throws {
        try super.createRelationships(forDestination: dInstance, in: mapping, manager: manager)
    }
}

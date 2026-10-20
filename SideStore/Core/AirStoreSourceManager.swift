//
//  AirStoreSourceManager.swift
//  SideStore
//

import CoreData
import Foundation

/// Keeps AirStore's own releases subscribed.
///
/// The source the app pulls its update feed from is upstream SideStore, and that source lists
/// SideStore as an updatable app pointing at upstream's build. Because AirStore keeps the same
/// bundle id, installing that update replaces AirStore with upstream and the sign-in fix goes with
/// it. Subscribing to our source alongside keeps AirStore's version in the comparison, but only
/// while it is the higher of the two.
@objc final class AirStoreSourceManager: NSObject
{
    @objc public static let shared = AirStoreSourceManager()

    static let sourceURL = URL(string: "https://raw.githubusercontent.com/JiangWanZhengChouYv/AirStore/develop/source/airstore-source.json")!

    private override init() {}

    @objc public static func subscribeIfNeeded()
    {
        // A background context, not viewContext: the first version of this ran in didFinishLaunching,
        // before DatabaseManager.start() had opened the store, and asking for viewContext there makes
        // CoreData load the store out of turn.
        DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            guard let identifier = try? Source.sourceID(from: sourceURL) else { return }
            guard Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), identifier), in: context) == nil
            else {
                return
            }

            let source = Source.make(name: "AirStore Official", groupID: identifier, sourceURL: sourceURL, context: context)
            try? context.save()
            debugLog("[AirStoreSourceManager] Subscribed to the AirStore source at \(sourceURL.absoluteString). Found \(source.identifier).")
        }
    }
}

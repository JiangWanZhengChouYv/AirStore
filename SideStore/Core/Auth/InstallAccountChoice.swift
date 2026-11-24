//
//  InstallAccountChoice.swift
//  AirStore
//
//  Which Apple ID an install will be signed with, and what to offer the user.
//
//  Refresh never asks: an installed app's App ID and provisioning profile belong to the team that
//  created them, so only the owning account can sign it again (see
//  `AppOperation.isBoundToInstalledApp`). A *first* install is the one place the choice is real.
//

import Foundation
import CoreData
import SideSign

public struct InstallAccountChoice {
    public let scope: AuthAccountScope
    /// Shown in the sheet, so two free accounts can be told apart.
    public let appleID: String
    public let teamName: String

    public init(scope: AuthAccountScope, appleID: String, teamName: String) {
        self.scope = scope
        self.appleID = appleID
        self.teamName = teamName
    }

    /// The line to put on a button. The team name is dropped when it adds nothing.
    public var displayName: String {
        self.appleID == self.teamName ? self.appleID : "\(self.appleID) · \(self.teamName)"
    }
}

public enum InstallAccountChoices {

    /// Every signed-in account that could sign a new app, active one first.
    ///
    /// Accounts without stored credentials are skipped: a row that always fails is worse than no row.
    public static func available(in context: NSManagedObjectContext) -> [InstallAccountChoice] {
        let request = Account.fetchRequest() as NSFetchRequest<Account>
        let accounts = (try? context.fetch(request)) ?? []
        guard !accounts.isEmpty else { return [] }

        let appleIDs = Dictionary(
            accounts.map { ($0.identifier, $0.appleID) },
            uniquingKeysWith: { first, _ in first }
        )
        // Also the migration point for credentials an upgraded install still keeps in the unscoped
        // slots -- they have to be in a namespace before anything is offered as a choice.
        let usable = Set(Keychain.shared.accountsWithCredentials(
            from: accounts.map(\.identifier),
            appleIDsByIdentifier: appleIDs
        ))

        let activeIdentifier = DatabaseManager.shared.activeAccount(in: context)?.identifier

        // Active account first: it is what the user acts as everywhere else, so it should also be
        // the row their thumb lands on.
        let sorted = accounts.sorted { lhs, rhs in
            if lhs.identifier == activeIdentifier { return true }
            if rhs.identifier == activeIdentifier { return false }
            return lhs.appleID.localizedCaseInsensitiveCompare(rhs.appleID) == .orderedAscending
        }

        return sorted.compactMap { account in
            guard usable.contains(account.identifier) else { return nil }
            // Prefer the team the account is currently on, so the choice matches what Settings shows.
            guard let team = account.teams.first(where: { $0.isActiveTeam }) ?? account.teams.first else { return nil }
            return InstallAccountChoice(
                scope: AuthAccountScope(accountIdentifier: account.identifier, teamIdentifier: team.identifier),
                appleID: account.appleID,
                teamName: team.name
            )
        }
    }
}

extension MyAppsViewController {

    /// The Apple ID that installed an app which is already on the device. Reinstalling and updating
    /// have to keep it: the App ID and provisioning profile in the bundle belong to that team, so a
    /// different account could only fail or re-sign the app with the wrong certificate. Only a first
    /// install gets to choose.
    ///
    /// Lives here rather than in MyAppsViewController, which is at its line-count limit.
    func installedAccount(for storeApp: StoreApp) -> InstallAccountChoice? {
        guard let installedApp = storeApp.installedApp else { return nil }
        return self.installAccountChoice(for: installedApp)
    }

    func installAccountChoice(for installedApp: InstalledApp) -> InstallAccountChoice? {
        guard let team = installedApp.team,
              let identifier = team.account?.identifier
        else { return nil }
        return InstallAccountChoice(
            scope: AuthAccountScope(accountIdentifier: identifier, teamIdentifier: team.identifier),
            appleID: team.account?.appleID ?? identifier,
            teamName: team.name
        )
    }
}

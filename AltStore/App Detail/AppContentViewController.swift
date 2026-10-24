//
//  AppContentViewController.swift
//  AltStore
//
//  Created by Riley Testut on 7/22/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import SwiftUI

import Nuke

extension AppContentViewController
{
    private enum Row: Int, CaseIterable
    {
        case subtitle
        case screenshots
        case description
        case versionDescription
        case permissions
    }
}

final class AppContentViewController: UITableViewController
{
    var app: StoreApp!

    /// Called when the user picks a build from another channel. `AppViewController` owns the
    /// install/update progress UI, so it performs the actual work.
    var didSelectVersion: ((AppVersion) -> Void)?

    private var versionsHostingController: UIHostingController<AppVersionsCard>?

//     private lazy var screenshotsDataSource = self.makeScreenshotsDataSource()
    private lazy var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter
    }()
    
    private lazy var byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        return formatter
    }()
    
    @IBOutlet private var subtitleLabel: UILabel!
//    @IBOutlet private var descriptionTextView: CollapsingTextView!
    @IBOutlet private var descriptionTextView: CollapsingMarkdownView!
//    @IBOutlet private var versionDescriptionTextView: CollapsingTextView!
    @IBOutlet private var versionDescriptionTextView: CollapsingMarkdownView!
    @IBOutlet private var versionLabel: UILabel!
    @IBOutlet private var versionDateLabel: UILabel!
    @IBOutlet private var sizeLabel: UILabel!
    
    @IBOutlet private(set) var appScreenshotsViewController: AppScreenshotsViewController!
    @IBOutlet private var appScreenshotsHeightConstraint: NSLayoutConstraint!
    
    @IBOutlet private(set) var appDetailCollectionViewController: AppDetailCollectionViewController!
    @IBOutlet private var appDetailCollectionViewHeightConstraint: NSLayoutConstraint!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.tableView.contentInset.bottom = 20
        
        self.subtitleLabel.text = self.app.subtitle
        let desc = self.app.localizedDescription
        self.descriptionTextView.text = desc
        
        if let version = self.app.latestAvailableVersion {
            self.versionDescriptionTextView.text = version.localizedDescription ?? "nil"
            self.versionLabel.text = String(format: NSLocalizedString("Version %@", comment: ""), version.localizedVersion)
            self.versionDateLabel.text = Date().relativeDateString(since: version.date)
            self.sizeLabel.text = ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file)
        } else {
            self.versionDescriptionTextView.text = "nil"
            self.versionLabel.text = nil
            self.versionDateLabel.text = nil
            self.sizeLabel.text = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
        }
        
        self.descriptionTextView.maximumNumberOfLines = 5
        self.versionDescriptionTextView.maximumNumberOfLines = 5
        
        self.descriptionTextView.toggleButton.addTarget(self, action: #selector(AppContentViewController.toggleCollapsingSection(_:)), for: .primaryActionTriggered)
        self.versionDescriptionTextView.toggleButton.addTarget(self, action: #selector(AppContentViewController.toggleCollapsingSection(_:)), for: .primaryActionTriggered)

        self.refreshVersionList()
    }
    
    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()
        
        var needsTableViewUpdate = false
        
        let screenshotsHeight = self.appScreenshotsViewController.collectionView.contentSize.height
        if self.appScreenshotsHeightConstraint.constant != screenshotsHeight && screenshotsHeight > 0
        {
            self.appScreenshotsHeightConstraint.constant = screenshotsHeight
            needsTableViewUpdate = true
        }
        
        let permissionsHeight = self.appDetailCollectionViewController.collectionView.contentSize.height
        if self.appDetailCollectionViewHeightConstraint.constant != permissionsHeight && permissionsHeight > 0
        {
            self.appDetailCollectionViewHeightConstraint.constant = permissionsHeight
            needsTableViewUpdate = true
        }
        
        if needsTableViewUpdate
        {
            UIView.performWithoutAnimation {
                // Update row height without animation.
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            }
        }

        self.layoutVersionsFooter()
    }

    func refreshVersionList()
    {
        let entries = self.makeVersionEntries()
        guard !entries.isEmpty else
        {
            self.versionsHostingController?.willMove(toParent: nil)
            self.versionsHostingController?.view.removeFromSuperview()
            self.versionsHostingController?.removeFromParent()
            self.versionsHostingController = nil
            self.tableView.tableFooterView = nil
            return
        }

        let card = AppVersionsCard(
            entries: entries,
            tintColor: Color(uiColor: self.app.tintColor ?? .altPrimary),
            onSelect: { [weak self] version in self?.didSelectVersion?(version) }
        )

        if let hostingController = self.versionsHostingController
        {
            hostingController.rootView = card
        }
        else
        {
            let hostingController = UIHostingController(rootView: card)
            hostingController.view.backgroundColor = .clear
            self.addChild(hostingController)
            hostingController.didMove(toParent: self)
            self.versionsHostingController = hostingController
            self.tableView.tableFooterView = hostingController.view
        }

        self.layoutVersionsFooter()
    }

    private func makeVersionEntries() -> [AppVersionsCard.Entry]
    {
        let installedApp = self.app.installedApp
        let currentVersionID = self.app.latestAvailableVersion?.versionID

        var seenVersionIDs = Set<String>()
        var entries: [(channel: ReleaseTrackType, version: AppVersion)] = []

        for track in self.app.releaseTracks ?? []
        {
            // Source refreshes delete and re-create these objects while the page is open, and this
            // runs from a managed-object-changed notification.
            guard !track.isDeleted, track.managedObjectContext?.deletedObjects.contains(track) == false else { continue }

            let supportedVersions = (track.releases ?? []).filter { version in
                !version.isDeleted
                    && version.managedObjectContext?.deletedObjects.contains(version) == false
                    && version.isSupported
            }

            // One row per channel. The develop channel points every build at the same rolling
            // release asset, so an older row would download the newest build under an older label.
            guard let newestVersion = supportedVersions.max(by: { $0.date < $1.date }) else { continue }

            // The version at the top of the page is already one tap away.
            guard newestVersion.versionID != currentVersionID else { continue }
            guard seenVersionIDs.insert(newestVersion.versionID).inserted else { continue }
            entries.append((track.type, newestVersion))
        }

        entries.sort { $0.version.date > $1.version.date }

        return entries.map { entry in
            AppVersionsCard.Entry(
                version: entry.version,
                channel: entry.channel,
                isInstalled: installedApp?.matches(entry.version) ?? false
            )
        }
    }

    private func layoutVersionsFooter()
    {
        guard let hostingController = self.versionsHostingController,
              let footerView = self.tableView.tableFooterView else { return }

        let width = self.tableView.bounds.width > 0 ? self.tableView.bounds.width : self.view.bounds.width
        guard width > 0 else { return }

        let size = self.fittingSize(for: hostingController, width: width)
        let height = ceil(size.height)
        guard abs(footerView.frame.height - height) > 0.5 || abs(footerView.frame.width - width) > 0.5 else { return }

        UIView.performWithoutAnimation {
            footerView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            // Re-assigning the footer is what makes the table pick up the new height.
            self.tableView.tableFooterView = footerView
        }
    }

    private func fittingSize(for hostingController: UIHostingController<AppVersionsCard>, width: CGFloat) -> CGSize
    {
        let targetSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        if #available(iOS 16.0, *)
        {
            return hostingController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        else
        {
            hostingController.view.frame.size.width = width
            return hostingController.view.systemLayoutSizeFitting(
                targetSize,
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
        }
    }
}

private extension AppContentViewController
{
    @IBSegueAction
    func makeAppScreenshotsViewController(_ coder: NSCoder, sender: Any?) -> UIViewController?
    {
        let appScreenshotsViewController = AppScreenshotsViewController(app: self.app, coder: coder)
        self.appScreenshotsViewController = appScreenshotsViewController
        return appScreenshotsViewController
    }
    
    func makePermissionsDataSource() -> ArrayCollectionViewDataSource<AppPermission>
    {        
        let dataSource = ArrayCollectionViewDataSource(items: Array(self.app.permissions))
        dataSource.cellConfigurationHandler = { (cell, permission, indexPath) in
            let cell = cell as! PermissionCollectionViewCell
            // cell.button.setImage(permission.type.icon, for: .normal)
            // cell.button.tintColor = .label
            // cell.textLabel.text = permission.type.localizedShortName ?? permission.type.localizedName
            
            let icon = UIImage(systemName: permission.symbolName ?? "lock")
            cell.button.setImage(icon, for: .normal)
            
            cell.textLabel.text = permission.localizedDisplayName
        }
        
        return dataSource
    }
    
    @IBSegueAction
    func makeAppDetailCollectionViewController(_ coder: NSCoder, sender: Any?) -> UIViewController?
    {
        let appDetailViewController = AppDetailCollectionViewController(app: self.app, coder: coder)
        self.appDetailCollectionViewController = appDetailViewController
        return appDetailViewController
    }
}

private extension AppContentViewController
{
    @objc func toggleCollapsingSection(_ sender: UIButton)
    {
        let indexPath: IndexPath
        
        switch sender
        {
        case self.descriptionTextView.toggleButton:
            indexPath = IndexPath(row: Row.description.rawValue, section: 0)
            
        case self.versionDescriptionTextView.toggleButton:
            indexPath = IndexPath(row: Row.versionDescription.rawValue, section: 0)

        default: return
        }
        
        // Disable animations to prevent some potentially strange ones.
        UIView.performWithoutAnimation {
            self.tableView.reloadRows(at: [indexPath], with: .none)
        }
    }
}

private struct AppVersionsCard: View
{
    struct Entry: Identifiable
    {
        let version: AppVersion
        let channel: ReleaseTrackType
        let isInstalled: Bool

        var id: String {
            "\(self.channel.rawValue)|\(self.version.versionID)"
        }
    }

    let entries: [Entry]
    let tintColor: Color
    let onSelect: (AppVersion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Other Versions")
                    .font(.system(size: 22, weight: .bold))
                Text("Install a specific build from another channel.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(self.entries.enumerated()), id: \.element.id) { index, entry in
                    self.row(for: entry)
                    if index < self.entries.count - 1
                    {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private func row(for entry: Entry) -> some View {
        SwiftUI.Button(action: { self.onSelect(entry.version) }) {
            HStack(spacing: 12) {
                Image(systemName: self.symbolName(for: entry.channel))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(self.tintColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.version.localizedVersion)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(verbatim: "\(self.channelName(for: entry.channel)) · \(Date().relativeDateString(since: entry.version.date))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                if entry.isInstalled
                {
                    Text("Installed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                else
                {
                    Text("Install")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(self.tintColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.isInstalled)
    }

    private func channelName(for channel: ReleaseTrackType) -> String {
        switch channel
        {
        case .stable: return NSLocalizedString("Stable", comment: "")
        case .nightly: return NSLocalizedString("Beta", comment: "")
        case .develop: return NSLocalizedString("Develop", comment: "")
        case .alpha: return NSLocalizedString("Alpha", comment: "")
        case .local: return NSLocalizedString("Local", comment: "")
        case .unknown: return NSLocalizedString("Other", comment: "")
        }
    }

    private func symbolName(for channel: ReleaseTrackType) -> String {
        switch channel
        {
        case .stable: return "checkmark.seal.fill"
        case .nightly: return "moon.stars.fill"
        case .develop: return "hammer.fill"
        case .alpha: return "flask.fill"
        case .local: return "desktopcomputer"
        case .unknown: return "shippingbox.fill"
        }
    }
}

extension AppContentViewController
{
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath)
    {
        cell.tintColor = self.app.tintColor
    }
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat
    {
        switch Row.allCases[indexPath.row]
        {
        case .screenshots:
            guard !self.app.allScreenshots.isEmpty else { return 0.0 }
            return UITableView.automaticDimension
            
        case .permissions:
            guard !self.app.permissions.isEmpty else { return 0.0 }
            return UITableView.automaticDimension
            
        default:
            return super.tableView(tableView, heightForRowAt: indexPath)
        }
    }
}

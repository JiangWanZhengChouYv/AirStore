//
//  InstallAppDialog.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

public enum AppImportSourceMode: String, CaseIterable, Identifiable, Sendable {
    case prompt = "prompt"
    case files  = "files"
    case url    = "url"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .prompt:
            return "Prompt User"
        case .files:
            #if !os(tvOS)
            return "Files App"
            #else
            return "Web Upload"
            #endif
        case .url:
            return "URL"
        }
    }
}

@MainActor
public enum InstallAppDialog {
    
    public static func presentSourceSelection(
        from presentingVC: UIViewController,
        barButtonItem: UIBarButtonItem? = nil,
        mode: AppImportSourceMode = UserDefaults.standard.appImportSourceMode,
        onChooseFiles: @escaping () -> Void,
        onConfirm: @escaping (URL) -> Void
    ) {
        switch mode {
        case .prompt:
            #if !os(tvOS)
            let alertController = UIAlertController(
                title: NSLocalizedString("Install App", comment: ""),
                message: nil,
                preferredStyle: .actionSheet
            )
            if let popover = alertController.popoverPresentationController {
                popover.barButtonItem = barButtonItem
            }
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Choose from Files", comment: ""), style: .default) { _ in
                onChooseFiles()
            })
            #else
            let alertController = UIAlertController(
                title: NSLocalizedString("Install App", comment: ""),
                message: NSLocalizedString("Choose an installation method:", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Upload via Web", comment: ""), style: .default) { _ in
                onChooseFiles()
            })
            #endif
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Install from URL", comment: ""), style: .default) { _ in
                self.presentURLInputDialog(from: presentingVC, onConfirm: onConfirm)
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
            
            presentingVC.present(alertController, animated: true)

        case .files:
            onChooseFiles()

        case .url:
            self.presentURLInputDialog(from: presentingVC, onConfirm: onConfirm)
        }
    }
    
    private static func presentURLInputDialog(
        from presentingVC: UIViewController,
        onConfirm: @escaping (URL) -> Void
    ) {
        let alert = UIAlertController(
            title: NSLocalizedString("Install from URL", comment: ""),
            message: NSLocalizedString("Enter the URL of the .ipa file to install.", comment: ""),
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/app.ipa"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
        }
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default) { _ in
            guard let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https") else {
                let errorAlert = UIAlertController(
                    title: NSLocalizedString("Invalid URL", comment: ""),
                    message: NSLocalizedString("Please enter a valid HTTP or HTTPS URL.", comment: ""),
                    preferredStyle: .alert
                )
                errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                presentingVC.present(errorAlert, animated: true)
                return
            }
            
            // The URL is only a source here; the dialog still asks how to install it, so the
            // account choice is discarded at this stage and asked again by the caller that
            // actually installs.
            self.present(ipaURL: url, from: presentingVC) { _ in
                onConfirm(url)
            }
        })
        
        presentingVC.present(alert, animated: true)
    }
    
    public static func present(
        ipaURL: URL,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping (InstallAccountChoice?) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let presenter = presentingViewController ?? UIApplication.shared.topViewController()
        let appName = ipaURL.isFileURL
            ? ipaURL.deletingPathExtension().lastPathComponent
            : (ipaURL.deletingPathExtension().lastPathComponent.isEmpty
                ? ipaURL.absoluteString
                : ipaURL.deletingPathExtension().lastPathComponent)
        let accounts = InstallAccountChoices.available(in: DatabaseManager.shared.viewContext)

        // An imported .ipa is the other way apps get installed here, and it gets the same choice:
        // run it inside AirBox, or install it on the system -- plus which Apple ID signs it.
        if UserDefaults.standard.isContainerModeEnabled, let presenter
        {
            self.presentInstallSheet(
                appName: appName,
                accounts: accounts,
                airBox: (title: NSLocalizedString("Run in AirBox", comment: ""),
                         detail: NSLocalizedString("Runs without installing on the system, so it uses no App ID.", comment: ""),
                         action: {
                             ContainerInstallAction.run(ipaAt: ipaURL, from: presenter)
                         }),
                from: presenter,
                onInstall: onConfirm,
                onCancel: onCancel
            )
            return
        }

        self.presentInstallSheet(
            appName: appName,
            accounts: accounts,
            airBox: nil,
            from: presenter,
            onInstall: onConfirm,
            onCancel: onCancel
        )
    }
    
    /// Asks how to install a store app, and returns the Apple ID to sign it with.
    ///
    /// Both answers come from **one** sheet. "Install" and "Run in AirBox" are answers to "how am I
    /// installing this", and with more than one signed-in account the Apple ID is part of the same
    /// answer -- asking in sequence made the second alert arrive while the first was still
    /// dismissing, and iOS drops that without a word.
    ///
    /// `onConfirm` receives `nil` for the Apple ID when there was nothing to choose (zero or one
    /// usable account), which the pipeline reads as "the active account".
    public static func present(
        storeApp: StoreApp,
        version: AppVersion? = nil,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping (InstallAccountChoice?) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let presenter = presentingViewController ?? UIApplication.shared.topViewController()
        let chosenVersion = version ?? storeApp.latestAvailableVersion
        let accounts = InstallAccountChoices.available(in: DatabaseManager.shared.viewContext)

        // Container mode changes what installing means, so its question leads. The Apple ID is still
        // asked in the same sheet when it is a real choice.
        if UserDefaults.standard.isContainerModeEnabled,
           let chosenVersion,
           let presenter
        {
            self.presentInstallSheet(
                appName: storeApp.name,
                accounts: accounts,
                airBox: (title: NSLocalizedString("Run in AirBox", comment: ""),
                         detail: NSLocalizedString("Runs without installing on the system, so it uses no App ID.", comment: ""),
                         action: {
                             ContainerInstallAction.run(version: chosenVersion, appName: storeApp.name, from: presenter)
                         }),
                from: presenter,
                onInstall: onConfirm,
                onCancel: onCancel
            )
            return
        }

        self.presentInstallSheet(
            appName: storeApp.name,
            accounts: accounts,
            airBox: nil,
            from: presenter,
            onInstall: onConfirm,
            onCancel: onCancel
        )
    }

    /// The one sheet every install starts from.
    ///
    /// Its buttons are the Apple IDs when there is more than one, and a single plain "Install" when
    /// there is not -- the account is the decision, so it belongs in the button the user presses,
    /// not in a second question after it.
    private static func presentInstallSheet(
        appName: String,
        accounts: [InstallAccountChoice],
        airBox: (title: String, detail: String, action: () -> Void)?,
        from presentingViewController: UIViewController?,
        onInstall: @escaping (InstallAccountChoice?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let rootVC = presentingViewController ?? UIApplication.shared.topViewController()
        guard let presentingVC = rootVC else {
            onCancel()
            return
        }

        // Nothing to decide: honour "ask before installing" and start. A sheet with one button is a
        // speed bump, and the same is true when confirmations are switched off.
        if accounts.count <= 1 && airBox == nil
        {
            guard UserDefaults.standard.isInstallConfirmationEnabled else {
                onInstall(accounts.first)
                return
            }

            let alert = UIAlertController(
                title: NSLocalizedString("Install App", comment: ""),
                message: String(format: NSLocalizedString("Do you want to continue? This will install \"%@\".", comment: ""), appName),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
                onInstall(accounts.first)
            })
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                onCancel()
            })
            presentingVC.present(alert, animated: true)
            return
        }

        let message: String
        if accounts.count > 1
        {
            message = NSLocalizedString("Each Apple ID keeps its own apps, App IDs and certificate. Only the account you pick can refresh this app later.", comment: "")
        }
        else
        {
            message = String(format: NSLocalizedString("This will install \"%@\".", comment: ""), appName)
        }

        let alertController = UIAlertController(
            title: accounts.count > 1
                ? String(format: NSLocalizedString("Install \"%@\" with which Apple ID?", comment: ""), appName)
                : NSLocalizedString("Install App", comment: ""),
            message: message,
            preferredStyle: .actionSheet
        )

        if accounts.count > 1
        {
            for account in accounts
            {
                alertController.addAction(UIAlertAction(title: account.displayName, style: .default) { _ in
                    onInstall(account)
                })
            }
        }
        else
        {
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
                onInstall(accounts.first)
            })
        }

        if let airBox
        {
            alertController.addAction(UIAlertAction(title: airBox.title, style: .default) { _ in
                // The next step is often another alert (installing AirBox first), and presenting one
                // while this sheet is still dismissing gets it dropped without a word.
                DispatchQueue.main.async {
                    airBox.action()
                }
            })
        }

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            onCancel()
        })

        if let popoverController = alertController.popoverPresentationController
        {
            popoverController.sourceView = presentingVC.view
            popoverController.sourceRect = presentingVC.view.bounds
        }
        presentingVC.present(alertController, animated: true)
    }

    public static func present(
        installedApp: InstalledApp,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let message = String(format: NSLocalizedString("Do you want to continue? This will reinstall \"%@\".", comment: ""), installedApp.name)
        self.presentConfirmation(
            message: message,
            from: presentingViewController,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }
    
    private static func presentConfirmation(
        message: String,
        from presentingViewController: UIViewController?,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard UserDefaults.standard.isInstallConfirmationEnabled else {
            onConfirm()
            return
        }
        
        let rootVC = presentingViewController ?? UIApplication.shared.topViewController()
        guard let presentingVC = rootVC else {
            onCancel()
            return
        }
        
        let alert = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
            onConfirm()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            onCancel()
        })
        
        presentingVC.present(alert, animated: true)
    }
}

//
//  AirBoxInstaller.swift
//  AirStore
//
//  Installs AirBox from the same develop release the running store came from. The package is
//  downloaded first and handed over as a local file: the install pipeline reads the bundle id out of
//  the package, and for a remote URL it only has the file name to go by.
//

import UIKit

@MainActor
enum AirBoxInstaller
{
    static var isInstalled: Bool
    {
        let context = DatabaseManager.shared.persistentContainer.viewContext
        let request = InstalledApp.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), ContainerInstaller.airBoxBundleIdentifier)
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    /// AirBox is published next to the store under the same build stamp, so the address is derived
    /// from the running build rather than configured anywhere.
    static var packageURL: URL?
    {
        let version = Bundle.Info.activeBundleShortVersion
        guard version.contains("-develop-") else { return nil }
        return URL(string: AppConstants.URLs.airStoreGitHub.absoluteString + "/releases/download/develop-latest/AirBox-\(version).ipa")
    }

    /// Confirms, downloads and installs, then reports whether AirBox is now on the device.
    static func confirmAndInstall(from presentingViewController: UIViewController,
                                  progress: Progress? = nil,
                                  completion: @MainActor @escaping (Bool) -> Void)
    {
        guard self.packageURL != nil else
        {
            self.presentUnavailableAlert(from: presentingViewController, completion: completion)
            return
        }

        let alert = UIAlertController(
            title: NSLocalizedString("Install AirBox?", comment: ""),
            message: NSLocalizedString("AirBox is installed like any other app, so it takes one App ID and one of the three active app slots. Apps it runs use neither.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
            self.install(from: presentingViewController, progress: progress, completion: completion)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            completion(false)
        })
        presentingViewController.present(alert, animated: true)
    }

    static func install(from presentingViewController: UIViewController,
                        progress: Progress? = nil,
                        completion: @MainActor @escaping (Bool) -> Void)
    {
        Task { @MainActor in
            do
            {
                let packageURL = try await ContainerInstaller.shared.downloadAirBox(progress: progress)
                progress?.completedUnitCount = 70
                AppManager.shared.install(.url(packageURL), presentingViewController: presentingViewController) { result in
                    // The pipeline has copied what it needs; the package in the temporary directory is
                    // ours to clean up either way.
                    try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent())

                    switch result
                    {
                    case .success:
                        Task { @MainActor in
                            progress?.completedUnitCount = progress?.totalUnitCount ?? 100
                            completion(true)
                        }
                    case .failure(let error) where error is CancellationError:
                        Task { @MainActor in completion(false) }
                    case .failure(let error):
                        Task { @MainActor in
                            let toastView = ToastView(error: error)
                            toastView.opensErrorLog = true
                            toastView.show(in: presentingViewController)
                            completion(false)
                        }
                    }
                }
            }
            catch
            {
                let toastView = ToastView(error: error)
                toastView.opensErrorLog = true
                toastView.show(in: presentingViewController)
                completion(false)
            }
        }
    }

    private static func presentUnavailableAlert(from presentingViewController: UIViewController, completion: @MainActor @escaping (Bool) -> Void)
    {
        let alert = UIAlertController(
            title: NSLocalizedString("AirBox Not Available", comment: ""),
            message: NSLocalizedString("AirBox is published with develop builds of AirStore. Update AirStore to a develop build to install it from here.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
            completion(false)
        })
        presentingViewController.present(alert, animated: true)
    }
}

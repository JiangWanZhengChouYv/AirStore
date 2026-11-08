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
        return InstalledApp.all(in: context).contains { ContainerInstaller.isAirBox($0) }
    }

    /// AirBox is published next to the store under the same build stamp, so the address is derived
    /// from the running build rather than configured anywhere.
    static var packageURL: URL?
    {
        let version = Bundle.Info.activeBundleShortVersion
        guard version.contains("-develop-") else { return nil }
        return URL(string: AppConstants.URLs.airStoreGitHub.absoluteString + "/releases/download/develop-latest/AirBox-\(version).ipa")
    }

    /// Any build can install AirBox, not only a develop one: a local build or a stable has no
    /// companion named after its version, so it asks the develop feed, which already lists AirBox
    /// with a download URL. The version-named package is still preferred when it exists.
    static func resolvePackageURL() async -> URL?
    {
        if let direct = self.packageURL { return direct }

        for feed in [AppConstants.URLs.airStoreDevelopFeed, AppConstants.URLs.airStoreDevelopFeedCDN]
        {
            guard let (data, response) = try? await URLSession.shared.data(from: feed),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = root["apps"] as? [[String: Any]] else { continue }

            for app in apps
            {
                guard let identifier = app["bundleIdentifier"] as? String, identifier.hasSuffix(".AirBox"),
                      let rawURL = app["downloadURL"] as? String,
                      let url = URL(string: rawURL) else { continue }
                return url
            }
        }
        return nil
    }

    /// Confirms, downloads and installs, then reports whether AirBox is now on the device.
    static func confirmAndInstall(from presentingViewController: UIViewController,
                                  progress: Progress? = nil,
                                  completion: @MainActor @escaping (Bool) -> Void)
    {
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
        self.present(alert, from: presentingViewController)
    }

    /// A view controller that is still dismissing something cannot present, and UIKit drops the
    /// request silently -- which reads as "nothing happened". Wait for it instead of giving up.
    private static func present(_ alert: UIAlertController, from viewController: UIViewController, attempts: Int = 6)
    {
        guard viewController.presentedViewController == nil else
        {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.present(alert, from: viewController, attempts: attempts - 1)
            }
            return
        }
        viewController.present(alert, animated: true)
    }

    static func install(from presentingViewController: UIViewController,
                        progress: Progress? = nil,
                        completion: @MainActor @escaping (Bool) -> Void)
    {
        Task { @MainActor in
            guard let remoteURL = await self.resolvePackageURL() else
            {
                self.presentUnavailableAlert(from: presentingViewController, completion: completion)
                return
            }

            do
            {
                let packageURL = try await ContainerInstaller.shared.downloadAirBox(from: remoteURL, progress: progress)
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
            message: NSLocalizedString("AirBox could not be found. Check your connection and try again, or install it later from Settings > Advanced > Container.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
            completion(false)
        })
        self.present(alert, from: presentingViewController)
    }
}

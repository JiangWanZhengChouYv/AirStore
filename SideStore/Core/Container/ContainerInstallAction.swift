//
//  ContainerInstallAction.swift
//  AirStore
//
//  One way to say "run this app in AirBox", called from every install entry point. AirBox is
//  installed first when it is missing, and the work shows up as a card in the download HUD so a tap
//  in a list is as visible as one on the app page.
//

import UIKit

@MainActor
enum ContainerInstallAction
{
    static func run(version: AppVersion, appName: String, from presentingViewController: UIViewController, airBoxReady: Bool = false)
    {
        guard airBoxReady || AirBoxInstaller.isInstalled else
        {
            AirBoxInstaller.confirmAndInstall(from: presentingViewController) { installed in
                guard installed else { return }
                // The install pipeline reports success before the new row has necessarily reached this
                // context, so the retry is told to trust the result instead of asking the database again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.run(version: version, appName: appName, from: presentingViewController, airBoxReady: true)
                }
            }
            return
        }

        let cardID = "container-\(UUID().uuidString)"
        let progress = Progress(totalUnitCount: 100)
        DownloadProgressHUD.shared.beginOperation(id: cardID,
                                                  title: NSLocalizedString("Adding to AirBox…", comment: ""),
                                                  subtitle: appName)

        let monitor = Task { @MainActor in
            while !Task.isCancelled
            {
                let fraction = Double(progress.completedUnitCount) / Double(max(progress.totalUnitCount, 1))
                DownloadProgressHUD.shared.updateOperation(id: cardID, fraction: fraction)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        Task { @MainActor in
            do
            {
                _ = try await ContainerInstaller.shared.addToAirBox(version, progress: progress)
            }
            catch
            {
                let toastView = ToastView(error: error)
                toastView.opensErrorLog = true
                toastView.show(in: presentingViewController)
            }

            monitor.cancel()
            DownloadProgressHUD.shared.end(id: cardID)
        }
    }
}

//
//  DownloadProgressHUD.swift
//  AltStore
//

@preconcurrency import UIKit

/// A thin progress card pinned under the status bar for the whole app, not just the screen that
/// started the download.
///
/// The install pipeline already reports byte-level progress, but it only ever reached the cell or
/// button that kicked it off -- switching tabs made a 28 MB download look like nothing was
/// happening. This sits in the key window instead, so it survives tab changes and navigation.
@MainActor
final class DownloadProgressHUD
{
    static let shared = DownloadProgressHUD()

    private var container: UIView?
    private var titleLabel: UILabel?
    private var percentLabel: UILabel?
    private var bar: UIProgressView?
    private var currentName: String?

    private init() {}

    func begin(appName: String)
    {
        if self.currentName == appName, self.container != nil { return }

        self.currentName = appName
        self.installIfNeeded()
        self.titleLabel?.text = String(format: NSLocalizedString("Downloading %@…", comment: ""), appName)
        self.setFraction(0)
    }

    func update(fraction: Double, appName: String?)
    {
        if let appName, appName != self.currentName
        {
            self.currentName = appName
            self.titleLabel?.text = String(format: NSLocalizedString("Downloading %@…", comment: ""), appName)
        }

        // Retried here as well as at the start: the first update can arrive before a window exists,
        // and the install flow presents its own full-screen progress layer afterwards, so the card
        // has to be pulled back to the front on every tick or it ends up underneath it.
        self.installIfNeeded()
        guard self.container != nil else { return }
        self.setFraction(fraction)
    }

    func end()
    {
        self.currentName = nil
        self.container?.removeFromSuperview()
        self.container = nil
        self.titleLabel = nil
        self.percentLabel = nil
        self.bar = nil
    }

    private func setFraction(_ fraction: Double)
    {
        let clamped = min(max(fraction, 0), 1)
        self.bar?.setProgress(Float(clamped), animated: true)
        self.percentLabel?.text = "\(Int(clamped * 100))%"
    }

    private func installIfNeeded()
    {
        if let container = self.container, let superview = container.superview
        {
            superview.bringSubviewToFront(container)
            return
        }

        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }
            .first
        guard let window else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.altPrimary.withAlphaComponent(0.95)
        container.layer.cornerRadius = 14
        container.layer.masksToBounds = true
        container.isUserInteractionEnabled = false
        container.alpha = 0

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .preferredFont(forTextStyle: .footnote)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle

        let percent = UILabel()
        percent.translatesAutoresizingMaskIntoConstraints = false
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percent.textColor = .white
        percent.textAlignment = .right
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let bar = UIProgressView(progressViewStyle: .bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        bar.progressTintColor = .white
        bar.layer.cornerRadius = 1.5
        bar.layer.masksToBounds = true

        container.addSubview(title)
        container.addSubview(percent)
        container.addSubview(bar)
        window.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: window.layoutMarginsGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: window.layoutMarginsGuide.trailingAnchor),

            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            percent.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            percent.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            percent.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        self.container = container
        self.titleLabel = title
        self.percentLabel = percent
        self.bar = bar

        UIView.animate(withDuration: 0.2) { container.alpha = 1 }
    }
}

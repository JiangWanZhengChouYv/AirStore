//
//  DownloadProgressHUD.swift
//  AltStore
//

@preconcurrency import UIKit

/// Progress cards pinned under the status bar for the whole app, not just the screen that started
/// the download.
///
/// The install pipeline reports byte-level progress, but it only ever reached the cell or button that
/// kicked it off -- switching tabs made a 28 MB download look like nothing was happening. These live
/// in the key window instead, one card per download, so two installs at once are two cards rather
/// than one that keeps jumping between them.
///
/// Speed and size are always on the card; the mirror in use and the full URL are one tap away, which
/// is the pair of facts that actually explain a download that crawls.
@MainActor
final class DownloadProgressHUD
{
    static let shared = DownloadProgressHUD()

    private final class Card
    {
        let container = UIView()
        let title = UILabel()
        let percent = UILabel()
        let subtitle = UILabel()
        let details = UILabel()
        let bar = UIProgressView(progressViewStyle: .bar)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

        var isExpanded = false
        var isOperation = false
        var lastBytes: Int64 = 0
        var lastTime: CFTimeInterval = 0
        var mirror: String?
        var url: URL?
    }

    private var stack: UIStackView?
    private var cards: [String: Card] = [:]

    private init() {}

    func begin(id: String, appName: String, url: URL)
    {
        if let existing = self.cards[id]
        {
            existing.url = url
            existing.title.text = String(format: NSLocalizedString("Downloading %@…", comment: ""), appName)
            return
        }

        let card = Card()
        card.url = url
        card.lastTime = CACurrentMediaTime()
        card.title.text = String(format: NSLocalizedString("Downloading %@…", comment: ""), appName)
        card.percent.text = "0%"
        card.container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleExpanded(_:))))
        self.configure(card)
        self.cards[id] = card

        self.installIfNeeded()
        self.stack?.addArrangedSubview(card.container)
        card.container.alpha = 0
        UIView.animate(withDuration: 0.2) { card.container.alpha = 1 }
    }

    func beginOperation(id: String, title: String, subtitle: String)
    {
        if let existing = self.cards[id]
        {
            existing.title.text = title
            existing.subtitle.text = subtitle
            existing.bar.setProgress(0, animated: false)
            existing.percent.text = "0%"
            return
        }

        let card = Card()
        card.isOperation = true
        card.title.text = title
        card.percent.text = "0%"
        card.subtitle.text = subtitle
        self.configure(card)
        card.chevron.isHidden = true
        card.details.isHidden = true
        self.cards[id] = card

        self.installIfNeeded()
        self.stack?.addArrangedSubview(card.container)
        card.container.alpha = 0
        UIView.animate(withDuration: 0.2) { card.container.alpha = 1 }
    }

    func updateOperation(id: String, fraction: Double, subtitle: String? = nil)
    {
        guard let card = self.cards[id], card.isOperation else { return }
        let clamped = min(max(fraction, 0), 1)
        card.bar.setProgress(Float(clamped), animated: true)
        card.percent.text = "\(Int(clamped * 100))%"
        if let subtitle { card.subtitle.text = subtitle }
    }

    /// Which mirror is serving this attempt, so the details can name it instead of guessing.
    func setMirror(_ host: String, for id: String)
    {
        guard let card = self.cards[id] else { return }
        card.mirror = host
        self.refreshDetails(card)
    }

    func update(id: String, bytes: Int64, total: Int64)
    {
        guard let card = self.cards[id] else { return }

        let now = CACurrentMediaTime()
        let elapsed = now - card.lastTime
        var speed: Double = 0
        if elapsed > 0.2
        {
            speed = Double(bytes - card.lastBytes) / elapsed
            card.lastBytes = bytes
            card.lastTime = now
        }

        if total > 0
        {
            let fraction = min(max(Double(bytes) / Double(total), 0), 1)
            card.bar.setProgress(Float(fraction), animated: true)
            card.percent.text = "\(Int(fraction * 100))%"
        }
        else
        {
            card.percent.text = "…"
        }

        let speedText = speed > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
            : "—"
        let arrived = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let expected = total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "?"
        card.subtitle.text = "\(speedText) · \(arrived) / \(expected)"
    }

    func end(id: String)
    {
        guard let card = self.cards.removeValue(forKey: id) else { return }

        UIView.animate(withDuration: 0.2) {
            card.container.alpha = 0
        } completion: { _ in
            card.container.removeFromSuperview()
        }
    }

    func endAll()
    {
        for id in Array(self.cards.keys) { self.end(id: id) }
    }

    @objc private func toggleExpanded(_ gesture: UITapGestureRecognizer)
    {
        guard let view = gesture.view,
              let card = self.cards.values.first(where: { $0.container === view }) else { return }

        card.isExpanded.toggle()
        self.refreshDetails(card)
        UIView.animate(withDuration: 0.2) {
            card.chevron.transform = card.isExpanded
                ? CGAffineTransform(rotationAngle: .pi)
                : .identity
            self.stack?.superview?.layoutIfNeeded()
        }
    }

    /// Collapsing by emptying the text rather than hiding the label keeps one required bottom
    /// constraint in the layout: an empty label is zero-height, a hidden one still reports its size.
    private func refreshDetails(_ card: Card)
    {
        guard card.isExpanded else
        {
            card.details.text = nil
            return
        }

        let source = card.mirror.map { "\(NSLocalizedString("Source", comment: "")): \($0)" } ?? ""
        let url = card.url?.absoluteString ?? ""
        card.details.text = [source, url].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func installIfNeeded()
    {
        guard self.stack?.superview == nil else { return }

        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }
            .first
        guard let window else { return }

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 6
        // Two installs at once are two cards; let them scroll rather than cover the whole screen.
        stack.distribution = .fill

        window.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: window.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.layoutMarginsGuide.trailingAnchor)
        ])
        self.stack = stack

        // Cards created before the window existed still need a home.
        for card in self.cards.values where card.container.superview == nil
        {
            stack.addArrangedSubview(card.container)
        }
    }

    private func configure(_ card: Card)
    {
        card.container.translatesAutoresizingMaskIntoConstraints = false
        card.container.backgroundColor = UIColor.altPrimary.withAlphaComponent(0.95)
        card.container.layer.cornerRadius = 16
        card.container.layer.masksToBounds = true

        card.title.translatesAutoresizingMaskIntoConstraints = false
        card.title.font = .preferredFont(forTextStyle: .footnote)
        card.title.textColor = .white
        card.title.lineBreakMode = .byTruncatingMiddle

        card.percent.translatesAutoresizingMaskIntoConstraints = false
        card.percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        card.percent.textColor = .white
        card.percent.textAlignment = .right
        card.percent.setContentHuggingPriority(.required, for: .horizontal)

        card.bar.translatesAutoresizingMaskIntoConstraints = false
        card.bar.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        card.bar.progressTintColor = .white
        card.bar.layer.cornerRadius = 2
        card.bar.layer.masksToBounds = true
        // UIProgressView has no height property; scaling it is the usual way to make the line read at
        // a glance instead of looking like a hairline.
        card.bar.transform = CGAffineTransform(scaleX: 1, y: 2)

        card.subtitle.translatesAutoresizingMaskIntoConstraints = false
        card.subtitle.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        card.subtitle.textColor = UIColor.white.withAlphaComponent(0.85)

        card.details.translatesAutoresizingMaskIntoConstraints = false
        card.details.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        card.details.textColor = UIColor.white.withAlphaComponent(0.75)
        card.details.numberOfLines = 0

        card.chevron.translatesAutoresizingMaskIntoConstraints = false
        card.chevron.tintColor = UIColor.white.withAlphaComponent(0.6)
        card.chevron.contentMode = .scaleAspectFit

        [card.title, card.percent, card.bar, card.subtitle, card.details, card.chevron].forEach(card.container.addSubview)

        NSLayoutConstraint.activate([
            card.title.topAnchor.constraint(equalTo: card.container.topAnchor, constant: 8),
            card.title.leadingAnchor.constraint(equalTo: card.container.leadingAnchor, constant: 12),

            card.percent.centerYAnchor.constraint(equalTo: card.title.centerYAnchor),
            card.percent.leadingAnchor.constraint(equalTo: card.title.trailingAnchor, constant: 8),
            card.percent.trailingAnchor.constraint(equalTo: card.container.trailingAnchor, constant: -12),

            card.bar.topAnchor.constraint(equalTo: card.title.bottomAnchor, constant: 6),
            card.bar.leadingAnchor.constraint(equalTo: card.container.leadingAnchor, constant: 12),
            card.bar.trailingAnchor.constraint(equalTo: card.container.trailingAnchor, constant: -12),

            card.subtitle.topAnchor.constraint(equalTo: card.bar.bottomAnchor, constant: 6),
            card.subtitle.leadingAnchor.constraint(equalTo: card.container.leadingAnchor, constant: 12),
            card.subtitle.trailingAnchor.constraint(equalTo: card.chevron.leadingAnchor, constant: -6),

            card.chevron.trailingAnchor.constraint(equalTo: card.container.trailingAnchor, constant: -12),
            card.chevron.centerYAnchor.constraint(equalTo: card.subtitle.centerYAnchor),
            card.chevron.widthAnchor.constraint(equalToConstant: 12),

            card.details.topAnchor.constraint(equalTo: card.subtitle.bottomAnchor, constant: 4),
            card.details.leadingAnchor.constraint(equalTo: card.container.leadingAnchor, constant: 12),
            card.details.trailingAnchor.constraint(equalTo: card.container.trailingAnchor, constant: -12),
            card.details.bottomAnchor.constraint(equalTo: card.container.bottomAnchor, constant: -10)
        ])
    }
}

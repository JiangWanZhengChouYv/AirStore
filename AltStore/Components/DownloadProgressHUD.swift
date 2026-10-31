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
        let effect = UIVisualEffectView()
        let fill = UIView()
        let title = UILabel()
        let percent = UILabel()
        let subtitle = UILabel()
        let details = UILabel()
        let bar = UIProgressView(progressViewStyle: .bar)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

        var fillWidth: NSLayoutConstraint?
        var isGlass = false
        var isExpanded = false
        var isOperation = false
        var lastBytes: Int64 = 0
        var lastTime: CFTimeInterval = 0
        var mirror: String?
        var url: URL?
    }

    private var stack: UIStackView?
    private var cards: [String: Card] = [:]

    /// True while any card is on screen, i.e. while an install is mid-flight and must not be
    /// interrupted -- the theme manager asks before restarting the app to show a new colour.
    var hasActiveCards: Bool { !self.cards.isEmpty }

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
        self.setProgress(card, clamped)
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
            self.setProgress(card, CGFloat(fraction))
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
        card.container.layer.cornerRadius = 16
        card.container.layer.masksToBounds = true

        // On iOS 26 the card is glass and the theme colour moves into a fill that grows with the
        // download; on every earlier release the card stays the solid colour it has always been, and
        // a fill painted over a solid background of the same colour would show nothing at all.
        let onGlass: Bool
        if #available(iOS 26.0, *)
        {
            let glass = UIGlassEffect()
            // A download card is a tap target for the mirror and URL lines, so the glass lifts under
            // a finger. Operation cards only report, so they must not look pressable.
            glass.isInteractive = !card.isOperation
            card.effect.effect = glass
            card.container.backgroundColor = nil
            card.isGlass = true
            onGlass = true

            card.effect.translatesAutoresizingMaskIntoConstraints = false
            card.container.addSubview(card.effect)

            card.fill.translatesAutoresizingMaskIntoConstraints = false
            // The theme colour is whatever the user dragged the picker to, so it goes through the same
            // brightness clamp the rest of the app uses rather than being trusted to read on glass.
            card.fill.backgroundColor = UIColor.altPrimary.adjustedForDisplay.withAlphaComponent(0.6)
            card.effect.contentView.addSubview(card.fill)
        }
        else
        {
            card.container.backgroundColor = UIColor.altPrimary.withAlphaComponent(0.95)
            onGlass = false
        }

        card.title.translatesAutoresizingMaskIntoConstraints = false
        card.title.font = .preferredFont(forTextStyle: .footnote)
        card.title.textColor = onGlass ? .label : .white
        card.title.lineBreakMode = .byTruncatingMiddle

        card.percent.translatesAutoresizingMaskIntoConstraints = false
        card.percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        card.percent.textColor = onGlass ? .label : .white
        card.percent.textAlignment = .right
        card.percent.setContentHuggingPriority(.required, for: .horizontal)

        card.bar.translatesAutoresizingMaskIntoConstraints = false
        card.bar.trackTintColor = onGlass ? UIColor.tertiaryLabel : UIColor.white.withAlphaComponent(0.3)
        card.bar.progressTintColor = onGlass ? UIColor.altPrimary.adjustedForDisplay : .white
        card.bar.layer.cornerRadius = 2
        card.bar.layer.masksToBounds = true
        // UIProgressView has no height property; scaling it is the usual way to make the line read at
        // a glance instead of looking like a hairline.
        card.bar.transform = CGAffineTransform(scaleX: 1, y: 2)

        card.subtitle.translatesAutoresizingMaskIntoConstraints = false
        card.subtitle.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        card.subtitle.textColor = onGlass ? .secondaryLabel : UIColor.white.withAlphaComponent(0.85)

        card.details.translatesAutoresizingMaskIntoConstraints = false
        card.details.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        card.details.textColor = onGlass ? .tertiaryLabel : UIColor.white.withAlphaComponent(0.75)
        card.details.numberOfLines = 0

        card.chevron.translatesAutoresizingMaskIntoConstraints = false
        card.chevron.tintColor = onGlass ? .secondaryLabel : UIColor.white.withAlphaComponent(0.6)
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

        if card.isGlass
        {
            let fillWidth = card.fill.widthAnchor.constraint(equalToConstant: 0)
            card.fillWidth = fillWidth

            NSLayoutConstraint.activate([
                card.effect.topAnchor.constraint(equalTo: card.container.topAnchor),
                card.effect.leadingAnchor.constraint(equalTo: card.container.leadingAnchor),
                card.effect.trailingAnchor.constraint(equalTo: card.container.trailingAnchor),
                card.effect.bottomAnchor.constraint(equalTo: card.container.bottomAnchor),

                card.fill.topAnchor.constraint(equalTo: card.effect.contentView.topAnchor),
                card.fill.leadingAnchor.constraint(equalTo: card.effect.contentView.leadingAnchor),
                card.fill.bottomAnchor.constraint(equalTo: card.effect.contentView.bottomAnchor),
                fillWidth
            ])
        }
    }

    /// The glass card fills itself with the theme colour from the left as the download arrives, so the
    /// card is the meter rather than carrying one. A width constant rather than a proportional
    /// constraint: an Auto Layout multiplier cannot be zero, and it cannot be edited once made.
    ///
    /// Every progress callback lands here with its own fraction, so this is continuous; the animation
    /// only keeps the steps between callbacks from reading as steps. Laid out on the glass view alone
    /// so the labels around it are not dragged through a layout pass three times a second.
    private func setProgress(_ card: Card, _ fraction: CGFloat)
    {
        guard card.isGlass else { return }
        card.fillWidth?.constant = card.effect.contentView.bounds.width * min(max(fraction, 0), 1)

        UIView.animate(withDuration: 0.28, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            card.effect.contentView.layoutIfNeeded()
        }
    }
}

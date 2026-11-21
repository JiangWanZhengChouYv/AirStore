//
//  AccountVerificationRow.swift
//  SideStore
//
//  Created by Magesh K on 13/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import CoreData
import SideSign

final class AccountVerificationRow: InsetGroupTableViewCell {
    static let reuseIdentifier = "AccountVerificationRow"
    static let preferredHeight: CGFloat = 60.0
    
    enum Status: Equatable {
        case completed
        case checking
        case actionRequired(certMissing: Bool, deviceUnregistered: Bool)
    }
    
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let iconImageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    
    init(reuseIdentifier: String? = AccountVerificationRow.reuseIdentifier) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        self.setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupViews()
    }
    
    private func setupViews() {
        self.style = .bottom
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.backgroundConfiguration = .clear()
        self.tintColor = UIColor.white.withAlphaComponent(0.6)
        self.layoutMargins = UIEdgeInsets(top: 8, left: 30, bottom: 8, right: 30)
        
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        self.subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        self.subtitleLabel.numberOfLines = 2
        
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = false
        self.iconImageView.contentMode = .scaleAspectFit
        
        self.spinner.translatesAutoresizingMaskIntoConstraints = false
        self.spinner.color = .white
        self.spinner.hidesWhenStopped = true
        
        let textStack = UIStackView(arrangedSubviews: [self.titleLabel, self.subtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        let rightContainer = UIView()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(self.iconImageView)
        rightContainer.addSubview(self.spinner)
        
        let mainStack = UIStackView(arrangedSubviews: [textStack, rightContainer])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .center
        mainStack.distribution = .fill
        
        self.contentView.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 30),
            mainStack.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -30),
            mainStack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 8),
            mainStack.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -8),
            
            rightContainer.widthAnchor.constraint(equalToConstant: 24),
            rightContainer.heightAnchor.constraint(equalToConstant: 24),
            
            self.iconImageView.centerXAnchor.constraint(equalTo: rightContainer.centerXAnchor),
            self.iconImageView.centerYAnchor.constraint(equalTo: rightContainer.centerYAnchor),
            self.iconImageView.widthAnchor.constraint(equalToConstant: 22),
            self.iconImageView.heightAnchor.constraint(equalToConstant: 22),
            
            self.spinner.centerXAnchor.constraint(equalTo: rightContainer.centerXAnchor),
            self.spinner.centerYAnchor.constraint(equalTo: rightContainer.centerYAnchor)
        ])
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        self.style = .bottom
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.backgroundConfiguration = .clear()
    }
    
    func configure(with status: Status) {
        self.style = .bottom
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.backgroundConfiguration = .clear()
        switch status {
        case .completed:
            self.titleLabel.text = nil
            self.subtitleLabel.text = nil
            self.iconImageView.image = nil
            self.iconImageView.isHidden = true
            self.spinner.stopAnimating()
            self.accessoryType = .none
            self.isSelectable = false
            
        case .checking:
            self.titleLabel.text = NSLocalizedString("Account Verification", comment: "")
            self.titleLabel.textColor = .white
            self.subtitleLabel.text = NSLocalizedString("Verifying account status...", comment: "")
            self.subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
            self.iconImageView.image = nil
            self.iconImageView.isHidden = true
            self.spinner.startAnimating()
            self.accessoryType = .none
            self.isSelectable = false
            
        case .actionRequired(let certMissing, let deviceUnregistered):
            self.titleLabel.text = NSLocalizedString("Action Required", comment: "")
            self.titleLabel.textColor = .systemOrange
            
            let subtitle: String
            if certMissing && deviceUnregistered {
                subtitle = NSLocalizedString("Signing certificate & device registration pending", comment: "")
            } else if certMissing {
                subtitle = NSLocalizedString("Active signing certificate pending", comment: "")
            } else {
                subtitle = NSLocalizedString("Device registration pending", comment: "")
            }
            self.subtitleLabel.text = subtitle
            self.subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            self.iconImageView.image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: symbolConfig)?
                .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
            self.iconImageView.isHidden = false
            self.spinner.stopAnimating()
            self.accessoryType = .none
            self.isSelectable = true
        }
    }
}

extension AccountVerificationRow {

    /// The state of one signed-in account, or of all of them.
    ///
    /// With several Apple IDs each has its own team, its own device registration and its own
    /// certificate, so a single global answer is wrong by construction: it used to report
    /// "completed" for an account that had never been checked, because another account had
    /// registered the device.
    struct AccountReport: Equatable {
        let accountIdentifier: String
        let appleID: String
        let teamIdentifier: String
        let status: Status

        var isSatisfied: Bool { self.status == .completed }
    }

    /// Check one account. `team` identifies the Developer team; the certificate is read from that
    /// account's own keychain slot, never from whichever account happens to be active.
    static func verifyStatus(for team: ALTTeam, accountIdentifier: String? = nil) async -> Status {
        let certMissing = self.signingCertificateMissing(for: team, accountIdentifier: accountIdentifier)

        if UserDefaults.standard.isDeviceRegistered(forTeam: team.identifier) {
            return certMissing
                ? .actionRequired(certMissing: true, deviceUnregistered: false)
                : .completed
        }

        // Each check is a live Apple portal call, and Apple throttles a burst of them with an HTML
        // 503 that then blocks sign-in for half an hour. A failed attempt is not free, so a check
        // that has already failed for this team in the last few minutes is not repeated -- opening
        // Settings twice must not cost two requests.
        if let lastFailure = UserDefaults.standard.lastDeviceCheckFailure(forTeam: team.identifier),
           Date().timeIntervalSince(lastFailure) < Self.failedCheckCooldown {
            verboseLog("[AccountVerificationRow] Skipping the device check for \(team.identifier): the last one failed \(Int(Date().timeIntervalSince(lastFailure)))s ago.")
            return .actionRequired(certMissing: certMissing, deviceUnregistered: true)
        }

        do {
            let devices = try await DeveloperPortalProxy.shared.fetchDevices(for: team, types: .all)
            let udid = try await fetchUDID()
            let isMatch = devices.contains { $0.identifier.caseInsensitiveCompare(udid) == .orderedSame }

            if isMatch {
                UserDefaults.standard.setDeviceRegistered(true, forTeam: team.identifier)
                return certMissing
                    ? .actionRequired(certMissing: true, deviceUnregistered: false)
                    : .completed
            }
            // Already registered on a *different* team only; this one still needs it.
            return .actionRequired(certMissing: certMissing, deviceUnregistered: true)
        } catch {
            verboseLog("[AccountVerificationRow] verifyStatus error fetching devices for team \(team.identifier): \(error)")
            UserDefaults.standard.setLastDeviceCheckFailure(Date(), forTeam: team.identifier)
            // A failed check is not "registered": saying so would hide the account behind a green
            // tick. Report the certificate half truthfully and let the device half stay pending.
            return .actionRequired(certMissing: certMissing, deviceUnregistered: true)
        }
    }

    /// How long a failed device check is left alone. Long enough that opening Settings repeatedly
    /// cannot build a burst, short enough that a genuinely fixed network is picked up on the next try.
    private static let failedCheckCooldown: TimeInterval = 10 * 60

    /// Whether this account has a usable signing certificate. `accountIdentifier` is the account
    /// the certificate belongs to; nil means the active one.
    private static func signingCertificateMissing(for team: ALTTeam, accountIdentifier: String?) -> Bool {
        if let accountIdentifier,
           CertificateManager.shared.certificate(forAccount: accountIdentifier) != nil {
            return false
        }
        let active = CertificateManager.shared.activeCertificate
            ?? (try? CertificateManager.shared.loadActiveCertificate())
        guard let active else { return true }
        return !hasCertificate(active.certificate, forTeam: team.identifier)
    }

    /// A custom certificate whose subject names a different team is still usable -- the app signs
    /// with whatever certificate is in the keychain. What is *not* usable is another account's
    /// certificate, and that is what this checks: the active certificate has to either name this
    /// team or be an imported custom one.
    private static func hasCertificate(_ certificate: ALTCertificate, forTeam teamIdentifier: String) -> Bool {
        if let der = certificate.data {
            let details = parseCertificate(derData: der)
            if details.subject.contains(teamIdentifier) || details.issuer.contains(teamIdentifier) {
                return true
            }
            // A certificate that names no team is a deliberately imported custom one -- the same rule
            // CertificateProvisioningFlow uses to bypass the portal.
            return true
        }
        // No DER payload to inspect: fall back to "this account holds a certificate at all".
        return CertificateManager.shared.isCertificateLocallyCached(serialNumber: certificate.serialNumber)
    }

    /// Every signed-in account's status, in the order the switcher lists them.
    static func verifyAllAccounts() async -> [AccountReport] {
        let context = DatabaseManager.shared.viewContext
        let request = Account.fetchRequest() as NSFetchRequest<Account>
        let accounts = ((try? context.fetch(request)) ?? [])

        let appleIDs = Dictionary(
            accounts.map { ($0.identifier, $0.appleID) },
            uniquingKeysWith: { first, _ in first }
        )
        let usable = Set(Keychain.shared.accountsWithCredentials(
            from: accounts.map(\.identifier),
            appleIDsByIdentifier: appleIDs
        ))
        let activeIdentifier = DatabaseManager.shared.activeAccount(in: context)?.identifier

        let sorted = accounts
            .filter { usable.contains($0.identifier) }
            .sorted { lhs, rhs in
                if lhs.identifier == activeIdentifier { return true }
                if rhs.identifier == activeIdentifier { return false }
                return lhs.appleID.localizedCaseInsensitiveCompare(rhs.appleID) == .orderedAscending
            }

        var reports: [AccountReport] = []
        for account in sorted {
            guard let dbTeam = account.teams.first(where: { $0.isActiveTeam }) ?? account.teams.first else { continue }
            let team = ALTTeam(identifier: dbTeam.identifier, name: dbTeam.name, type: dbTeam.type)
            // The portal call has to run as this account, not as the active one.
            let scope = AuthAccountScope(accountIdentifier: account.identifier, teamIdentifier: dbTeam.identifier)
            let status = await AuthAccountContext.$scope.withValue(scope) {
                await self.verifyStatus(for: team, accountIdentifier: account.identifier)
            }
            reports.append(AccountReport(
                accountIdentifier: account.identifier,
                appleID: account.appleID,
                teamIdentifier: dbTeam.identifier,
                status: status
            ))
        }
        return reports
    }

    /// Fold several accounts into the one row the settings home has room for.
    static func combinedStatus(of reports: [AccountReport]) -> Status {
        guard !reports.isEmpty else { return .completed }
        if reports.contains(where: { $0.status == .checking }) { return .checking }

        let pending = reports.filter { !$0.isSatisfied }
        guard !pending.isEmpty else { return .completed }

        // The row has two booleans, so report whether *any* account is missing each half.
        var certMissing = false
        var deviceUnregistered = false
        for report in pending {
            guard case .actionRequired(let cert, let device) = report.status else { continue }
            certMissing = certMissing || cert
            deviceUnregistered = deviceUnregistered || device
        }
        return .actionRequired(certMissing: certMissing, deviceUnregistered: deviceUnregistered)
    }
    
    /// Fix what this account is missing.
    ///
    /// `accountIdentifier` scopes the work to that Apple ID: device registration and certificate
    /// provisioning both talk to Apple with the session `AuthAccountContext` selects, and the
    /// certificate is written into that account's own keychain slot. Passing nil means the active
    /// account, which is what the single-account case wants.
    static func resolvePendingActions(for status: Status,
                                     team: ALTTeam,
                                     accountIdentifier: String? = nil,
                                     presentingViewController: UIViewController) async {
        guard case .actionRequired(let certMissing, let deviceUnregistered) = status else { return }

        let scope = accountIdentifier.map {
            AuthAccountScope(accountIdentifier: $0, teamIdentifier: team.identifier)
        }
        await AuthAccountContext.$scope.withValue(scope) {
            await self.performPendingActions(
                certMissing: certMissing,
                deviceUnregistered: deviceUnregistered,
                team: team,
                accountIdentifier: accountIdentifier,
                presentingViewController: presentingViewController
            )
        }
    }

    private static func performPendingActions(certMissing: Bool,
                                              deviceUnregistered: Bool,
                                              team: ALTTeam,
                                              accountIdentifier: String?,
                                              presentingViewController: UIViewController) async {
        
        var pendingItems: [String] = []
        if deviceUnregistered {
            pendingItems.append(NSLocalizedString("Register Device", comment: ""))
        }
        if certMissing {
            pendingItems.append(NSLocalizedString("Provision Signing Certificate", comment: ""))
        }
        
        guard !pendingItems.isEmpty else { return }
        
        let count = pendingItems.count
        let title = count == 1
            ? NSLocalizedString("1 Pending Action", comment: "")
            : String(format: NSLocalizedString("%d Pending Actions", comment: ""), count)
        
        let bulletList = pendingItems.map { "• \($0)" }.joined(separator: "\n")
        let message = NSLocalizedString("The following action(s) from sign-in are required to complete account setup:\n\n\(bulletList)", comment: "")
        
        let confirmed = await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default) { _ in
                continuation.resume(returning: true)
            })
            presentingViewController.present(alert, animated: true)
        }
        
        guard confirmed else { return }
        
        let initialDescription = deviceUnregistered
            ? NSLocalizedString("Registering device…", comment: "")
            : NSLocalizedString("Provisioning signing certificate…", comment: "")
            
        let progressAlert = UIAlertController(
            title: NSLocalizedString("Setting Up Account", comment: ""),
            message: "\(initialDescription)\n\n\n",
            preferredStyle: .alert
        )
        
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        progressAlert.view.addSubview(spinner)
        
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: progressAlert.view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: progressAlert.view.bottomAnchor, constant: -20)
        ])
        
        await withCheckedContinuation { continuation in
            presentingViewController.present(progressAlert, animated: true) {
                continuation.resume()
            }
        }
        
        func executeStep(description: String, operation: () async throws -> Void) async throws {
            progressAlert.message = "\(description)\n\n\n"
            let startTime = Date()
            try await operation()
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 0.5 {
                try? await Task.sleep(nanoseconds: UInt64((0.5 - elapsed) * 1_000_000_000))
            }
        }
        
        let handler = SignInFlowHandler(presentingViewController: presentingViewController)
        handler.showsDoItLater = true
        
        do {
            if deviceUnregistered {
                try await executeStep(description: NSLocalizedString("Registering device…", comment: "")) {
                    let deviceFlow = DeviceRegistrationFlow(handler: handler)
                    _ = try await deviceFlow.registerCurrentDevice(for: team)
                }
            }
            
            if certMissing {
                try await executeStep(description: NSLocalizedString("Provisioning signing certificate…", comment: "")) {
                    let certFlow = CertificateProvisioningFlow(handler: handler)
                    let certificate = try await certFlow.resolveCertificate(for: team)
                    // Provisioning writes the active slot; a pending action for a non-active account
                    // has to end up in that account's own slot instead.
                    if let accountIdentifier, let certificate {
                        CertificateManager.shared.setCertificate(certificate, forAccount: accountIdentifier)
                    }
                }
            }
        } catch {
            verboseLog("[AccountVerificationRow] resolvePendingActions error: \(error)")
        }
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            progressAlert.dismiss(animated: true) { () in
                continuation.resume()
            }
        }
        
        let registered = accountIdentifier.map { _ in
            UserDefaults.standard.isDeviceRegistered(forTeam: team.identifier)
        } ?? UserDefaults.standard.isDeviceRegistered

        // `certificate(for:)` takes an optional scope and `certificate(forAccount:)` takes a String,
        // so the account case has to be spelled out rather than funnelled through one expression.
        let accountCertificate = accountIdentifier.flatMap {
            CertificateManager.shared.certificate(forAccount: $0)?.certificate
        }
        let scopedCertificate = CertificateManager.shared.certificate(for: scopeFor(accountIdentifier, team: team))
        if registered, let activeCert = accountCertificate ?? scopedCertificate
        {
            let resignFlow = CodeSignValidationFlow(handler: handler)
            _ = try? await resignFlow.validateAndResignIfNeeded(
                team: team,
                certificate: activeCert
            )
        }
        
        await handler.complete()
    }

    private static func scopeFor(_ accountIdentifier: String?, team: ALTTeam) -> AuthAccountScope? {
        accountIdentifier.map { AuthAccountScope(accountIdentifier: $0, teamIdentifier: team.identifier) }
    }
}

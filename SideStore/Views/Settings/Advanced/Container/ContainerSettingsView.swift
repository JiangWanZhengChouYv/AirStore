//
//  ContainerSettingsView.swift
//  AirStore
//
//  The gate in front of container mode. Installing apps into AirBox means one process can read every
//  guest's data and keychain, which is a different trust model from installing them, so the switch
//  stays off until the warning has been read and its sentence typed out in full.
//

import SwiftUI

private let containerEnglishPhrase = "I understand the above content"
private let containerChinesePhrase = "我已阅读以上说明"

struct ContainerSettingsView: View
{
    @State private var isEnabled = UserDefaults.standard.isContainerModeEnabled
    @State private var isConfirming = false
    @State private var airBoxInstalled = false

    var body: some View
    {
        ScrollView
        {
            VStack(alignment: .leading, spacing: 24)
            {
                self.containerSection
                self.warningSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .navigationTitle("Container")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { self.airBoxInstalled = Self.isAirBoxInstalled() }
        .sheet(isPresented: self.$isConfirming)
        {
            ContainerConfirmationView
            {
                self.isEnabled = true
                UserDefaults.standard.isContainerModeEnabled = true
            }
        }
    }
}

private extension ContainerSettingsView
{
    var containerSection: some View
    {
        VStack(alignment: .leading, spacing: 8)
        {
            Text("CONTAINER")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.6))
                .padding(.horizontal, 4)

            VStack(spacing: 0)
            {
                HStack(spacing: 12)
                {
                    VStack(alignment: .leading, spacing: 4)
                    {
                        Text("Container Mode")
                            .font(.system(size: 16))
                            .foregroundColor(.white)

                        Text("Run apps inside AirBox instead of installing them.")
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Toggle("", isOn: self.containerBinding)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .background(Color.white.opacity(0.15))
                    .padding(.horizontal, 16)

                HStack
                {
                    Text("AirBox")
                        .font(.system(size: 16))
                        .foregroundColor(.white)

                    Spacer()

                    Text(self.airBoxInstalled ? NSLocalizedString("Installed", comment: "") : NSLocalizedString("Not installed", comment: ""))
                        .font(.system(size: 14))
                        .foregroundColor(self.airBoxInstalled ? Color.white.opacity(0.6) : .orange)
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.15)))

            Text(self.airBoxInstalled
                 ? NSLocalizedString("Container mode is optional. Apps installed this way do not use an App ID and do not appear on the Home Screen.", comment: "")
                 : NSLocalizedString("Install AirBox from AirStore first. Apps can only be added to a mode that has somewhere to run them.", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    var warningSection: some View
    {
        VStack(alignment: .leading, spacing: 8)
        {
            Text("BEFORE YOU ENABLE IT")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.6))
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12)
            {
                // AirBox is the trust boundary: everything running in it is the same process, and the
                // side effect users are least likely to expect is keychain access, so it is named.
                Text("AirBox can read the data and keychain items of every app running inside it. Only add apps you trust.")
                Text("These apps do not use App IDs, so the 3-app and 10-App-ID limits do not apply.")
                Text("This feature does not collect any information.")
            }
            .font(.system(size: 14))
            .foregroundColor(Color.white.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.15)))
        }
    }

    var containerBinding: Binding<Bool>
    {
        Binding(get: { self.isEnabled }, set: { wantsOn in
            if wantsOn
            {
                // Off until the sentence is typed; the sheet is the only way to turn this on.
                if !self.isEnabled { self.isConfirming = true }
            }
            else
            {
                self.isEnabled = false
                UserDefaults.standard.isContainerModeEnabled = false
            }
        })
    }

    @MainActor
    static func isAirBoxInstalled() -> Bool
    {
        let context = DatabaseManager.shared.persistentContainer.viewContext
        let request = InstalledApp.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), ContainerInstaller.airBoxBundleIdentifier)
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    }
}

private struct ContainerConfirmationView: View
{
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    let onConfirm: () -> Void

    private var matches: Bool
    {
        let trimmed = self.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == containerEnglishPhrase || trimmed == containerChinesePhrase
    }

    var body: some View
    {
        NavigationStack
        {
            ScrollView
            {
                VStack(alignment: .leading, spacing: 16)
                {
                    Text("Enable Container Mode?")
                        .font(.title3.bold())

                    Text("AirBox can read the data and keychain items of every app running inside it. Only add apps you trust. This feature does not collect any information.")
                        .font(.system(size: 15))

                    Text("Type the sentence below in full to continue.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    TextField(containerEnglishPhrase, text: self.$typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))

                    Text(verbatim: "\(containerEnglishPhrase)\n\(containerChinesePhrase)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("Container")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar
            {
                ToolbarItem(placement: .cancellationAction)
                {
                    Button("Cancel") { self.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction)
                {
                    Button("Enable") {
                        self.onConfirm()
                        self.dismiss()
                    }
                    .disabled(!self.matches)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

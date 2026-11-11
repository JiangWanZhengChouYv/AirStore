# Agent Guidelines for AirStore

A file for [guiding AI coding agents](https://agents.md/). Read this before changing code.

## What this project is

AirStore is a fork of [SideStore](https://github.com/SideStore/SideStore), which is itself a fork of
AltStore. It sideloads and refreshes iOS apps on-device with a personal Apple ID, using a local VPN
loopback (`em_proxy` + `minimuxer`) instead of a computer. There is **no AltServer** and no desktop
component required to refresh apps.

The goal is stated as **"be the better SideStore"** — the fork a user stays on, not a temporary patch
for one Apple error. Work happens in three main streams, all first-class:

1. **`-80045` / Anisette** — Apple ID sign-in on iOS 26.4+. Apple tightened GrandSlam Anisette
   restrictions and public Anisette servers are largely blocked. Start in
   `SideStore/Core/Anisette/`, then follow `AltStore/Settings/AnisetteManager.swift`,
   `AltStore/Settings/AnisetteServerList.swift`, and `SideStore/Core/Auth/`, where the error surfaces.
2. **AirBox** — run apps inside a container so the number of apps a user keeps is not decided by a free
   account's App ID slots. This is a re-skin of LiveContainer: `AirBox/`,
   `SideStore/Core/Container/`, vendored engine in `Dependencies/LiveContainer`.
3. **On-device quality** — high-memory and JIT entitlements, incremental updates (patch instead of full
   package), pairing/certificate import & export, and Simplified Chinese localization.

Everything else is inherited upstream behavior. Keep each change focused on one thing; one person
reads every diff.

## Maintainer and contribution constraints

AirStore is maintained by **one person in their spare time**. Review capacity is the scarcest
resource. Treat the rules below as enforced.

### Declare AI usage
- State in the PR/issue whether AI helped find, test, or implement the change, and how.
- The human submitting must be able to explain the change without leaning on generated text.
- A false or evasive declaration is grounds for refusing the contribution.

### No automated posting on GitHub
Agents **must not** use GitHub APIs, CLIs, or the web UI to open/update PRs, create/edit/close
issues or discussions, or post comments anywhere. The maintainer triages by hand. Drafting is fine;
a person submits.

### Working with the maintainer
- **Verify comprehension** of the problem and the relevant code before proposing changes.
- **Point at the code** for the stream (`-80045` → Anisette/Auth, AirBox → Container/AirBox).
- **Keep diffs small and single-purpose**; verify the human can explain the solution.
- All contributions are subject to [CERTIFICATE-OF-ORIGIN.md](CERTIFICATE-OF-ORIGIN.md).

Violations may lead to restrictions up to a permanent ban.

## Current state (0.9.1, November 2026)

- **Bundle identity**: `com.JiangWanZhengChouYv.AirStore` (Release), app group
  `group.com.JiangWanZhengChouYv.AirStore`, AirBox `com.JiangWanZhengChouYv.AirStore.AirBox`.
  `ORG_IDENTIFIER = com.JiangWanZhengChouYv` and `BASE_BUNDLE_ID = $(ORG_IDENTIFIER).AirStore` in
  `Build.xcconfig`. The 0.9.0 release changed this from SideStore's identifiers; that migration is
  done and **must not be repeated or "cleaned up"** — it decides which signed profile an install uses.
- **Deployment target**: iOS **17.4**. Liquid Glass styling is iOS 26+, with material fallbacks for
  17.4–25.
- **Version**: `MARKETING_VERSION = 0.9.1` on develop; stable is 0.9.0 until the next release.
- **Swift version**: targets build in **Swift 5 mode** (`-swift-version 5`); do not introduce Swift 6
  strict-concurrency-only patterns without checking the target settings.
- The product is still built as **`SideStore.app`** and packaged into **`AirStore.ipa`**; the
  user-facing name is `CFBundleDisplayName = AirStore`. `PRODUCT_NAME` in `Build.xcconfig` does not
  win — every target sets `PRODUCT_NAME = "$(TARGET_NAME)"`.

## Keep this file current

This is a living document, not a one-time summary. Any change that alters behavior, structure,
state, workflows, or AI-facing rules must update AGENTS.md **in the same commit**:

- new or changed feature/flow → update "Current state" or the relevant stream;
- new invariant, gotcha, build or CI rule → put it where the next agent will look for it;
- finished phase or removed workaround → delete the stale sentence instead of keeping history here.

If a change makes a statement in this file false, fixing that statement is part of the change, not a
follow-up.

## Working alongside other agents

More than one agent may be working in this repository at a time. At the start of a task, check
whether AGENTS.md changed since you last read it (`git log --oneline -- AGENTS.md`, or its
modification time). If it did, **re-read the changed sections before touching code**: another agent
may have added a rule, renamed a path, or recorded a decision that makes your planned edit wrong.

When a file you need has changed underneath you, re-read it instead of writing from memory, and do
not revert or overwrite work you did not create. If two changes genuinely conflict, stop and surface
the conflict rather than picking a winner silently.

## Targets, folders, schemes

- `AltStore/` — main app: tab bar, Browse, My Apps, Settings storyboards/controllers, app detail,
  App IDs, install/refresh UI.
- `SideStore/` — SideStore-specific logic and SwiftUI screens: boot flow (`AppBootManager.swift`),
  maintenance (`MaintenanceManager.swift`), deep links, pairing, Anisette, container integration,
  onboarding, and the SwiftUI subpages pushed from the classic settings list.
- `AirBox/` — AirBox app target (LiveContainer re-skin), with `LiveProcess/` extension.
- `SideBackup/` — helper launcher + backup engine used by self-updates.
- `AltWidget/` — widgets.
- `Shared/` — shared utilities, extensions, error types.
- `Dependencies/` — submodules/local Swift Packages (`minimuxer`, `SideSign`, `CodeSignKit`,
  `LiveContainer`). Do not modify unless the task is explicitly a dependency update.
- `Helper/` — Tauri 2 desktop companion (React + Rust). Installs AirStore over USB/Network and places
  the pairing file. Not in the Xcode workspace; CI builds it separately. `src-tauri/src/update.rs`
  holds the device linkage: `installed_airstore` reads `CFBundleShortVersionString` through the
  installation proxy, `latest_airstore_release` reads the stable/develop tracks from the same feed the
  app subscribes to, and `check_helper_update` reads the rolling `helper-latest` prerelease. Keep
  those three as the only source of version truth in the Helper.
- `source/airstore-source.json` — the **hand-authored** source feed (stable truth).
- `scripts/ci/` — versioning, deltas, feed generation, release assets.
- Schemes: `SideStore` (full), `SideStore - Release` (store only), `AirBox`, `SideBackup`,
  `AltWidgetExtension`.

## Build, test, verify

Requires macOS + Xcode 26 SDK (CI uses `macos-26`). No CocoaPods — **never** add a `Podfile` or run
`pod install`.

```sh
git clone https://github.com/JiangWanZhengChouYv/AirStore.git --recurse-submodules
cp CodeSigning.xcconfig.sample CodeSigning.xcconfig   # then set DEVELOPMENT_TEAM
```

Useful commands:

```sh
make build-airstore XCODEBUILD_JOBS=8   # archive the store target (CI's scheme)
make build-airbox   XCODEBUILD_JOBS=8   # archive AirBox
make build fakesign ipa                 # local stable-style IPA
```

Local build notes:
- The store target is large; 7–10 minutes is normal, not a hang. Run heavy builds with
  `taskpolicy -b nice -n 10` and a jobs cap so the machine stays usable.
- XCBuild occasionally links `SideBackup` before SwiftPM package objects exist (`CodeSignKit.o`,
  `CryptoExtras.o` missing). Retry once; if it persists, clear the project's DerivedData. It is a
  build-order race, not a code error.
- Prefer CI for full verification; a local archive must reach `ARCHIVE SUCCEEDED` before pushing when
  the change is risky.
- `AirBox.ipa` (or other build artifacts) at the repo root must never be committed.

Style:
- Swift: 4 spaces, UTF-8, LF (`.editorconfig`); SwiftLint errors must be zero (warnings are tolerated,
  but do not add new long-line/type-length violations casually).
- Use Swift Concurrency (`async`/`await`, `Task`) over GCD/completion handlers in new code.
- Do not reformat unrelated lines. Keep comments sparse and about *why*, not *what*.

## CI and releases (what actually happens)

- `.github/workflows/develop.yml` is a fishbone:
  `prepare` (Ubuntu) → **in parallel** `build-airstore` (macOS), `build-airbox` (macOS),
  `build-helper` (macOS), `build-helper-windows` (Windows) → `publish` (Ubuntu) +
  `publish-helper` (Ubuntu) → `notify` (Discord). Typical wall time is **~9 minutes**; the AirStore
  build is the critical path (~7.5–9 min). Helper builds finish in 1.5–4 min and do not extend it.
- The develop feed is generated from `source/airstore-source.json` and committed to the
  **`develop-source`** branch. The app's built-in feed points there. Do not hand-edit generated feeds.
- Delta updates are cut by `scripts/ci/make_patch.py` (ASBU/ASDP2) against recent builds; retention is
  five builds plus their patches.
- The Pages mirror is **parked** (waiting on a Cloudflare domain). Do not reintroduce a git-branch
  mirror. jsDelivr gets a single purge request; the app prefers live proxies.
- The Helper publishes to the rolling prerelease **`helper-latest`** (macOS zip + Windows NSIS
  installer), ad-hoc/unsigned in CI. Local copies are signed with the stable local certificate.
- `stable.yml` builds releases from tags; published releases/tags are never deleted or moved.
- Do not bump `MARKETING_VERSION` on develop to a version lower than the released stable; develop
  versions use `x.y.z-develop-<timestamp>.<run>-<sha>`.

## UI

The app has **one** interface: the UIKit/storyboard UI under `AltStore/`, with individual SwiftUI
screens pushed from it (`SideStore/Views/Onboarding/`, `SideStore/Views/Settings/**`).

- A parallel opt-in SwiftUI shell (`SideStore/Views/NewUI/`, `UIStylePreferences`, the "Interface"
  switch in 高级 → 用户自定义) existed during 2026 and was **removed at the maintainer's request on
  2026-11-11**. Do not reintroduce it, and do not add a second shell or a UI-style switch.
- New work goes into the classic UI. Settings rows live in `AltStore/Settings/SettingsViewController`
  + `Settings.storyboard`, or in the SwiftUI subpages they push.
- `Shared/Extensions/View+GlassSurface.swift` stays: the onboarding flow uses it.
- The onboarding flow keeps its six steps and all auth/pairing/container logic; it is SwiftUI and
  re-skinned in place (`SideStore/Views/Onboarding/OnboardingView.swift`).
- **The sources tab is gone** (maintainer, 2026-11-12). Source management is pushed from Browse
  (`FeaturedViewController` toolbar button → `UIViewController.showSources(sourceURL:)`); the
  `addSource` deep link goes through the same helper. Tab order is news, browse, my apps, settings —
  keep `TabBarController.Tab` and both `Main.storyboard` variants (iOS + tvOS) in that order.
- Next feature priority: Helper ↔ on-device app integration (the Helper must stop being a re-skin),
  including update checking inside the Helper itself.

### SwiftUI gotchas in this repo

- `FetchRequest` is shadowed by a project typealias (`NSFetchRequest`): write
  `@SwiftUI.FetchRequest` and `SwiftUI.FetchRequest(...)`.
- `Button` is shadowed by a project component: write `SwiftUI.Button` in SwiftUI code.
- `BaseEntity`/NSManagedObject does **not** satisfy `Identifiable` here; use `ForEach(..., id: \.objectID)`.
- New files under synchronized folders (`SideStore/`, `AltStore/`, …) are picked up automatically;
  no `.pbxproj` edit is needed for a new Swift file in those folders.

## Critical behavior and invariants

- **Do not broadly refactor signing, installation, or networking.** Install/refresh/sign have many
  iOS-version edge cases (17.4+). Be skeptical of generated code and preserve behavior outside the fix.
- **Pairing**: the Helper/iLoader writes `ALTPairingFile.mobiledevicepairing`,
  `PairingFile_RemoteRP.plist` and `PairingFile_Lockdown.plist` into the app's Documents.
  `PairingFileManager.adoptAvailablePairingFile()` adopts them at boot (prefers Remote Pairing) when
  no protocol has been chosen. Manual pairing uses the separate **idevice_pair** app; do not tell
  users to import a file exported from an existing desktop pairing record (it does not work).
- **Self-updates**: an in-app update reinstalls the app and creates a fresh container. Launch code
  must skip `isFirstLaunch` sign-out and the destructive maintenance passes (1–2) when
  `reconcileSelfReinstallationIfNeeded()` confirms a self-update. The new-UI toggle lives in the App
  Group for the same reason. A true uninstall/reinstall still resets app data — that is iOS behavior,
  not a bug.
- **AirBox guests**: guests are launched by staging a request in the shared group and opening
  `airbox://`; JIT is opt-in per app via the JIT enabler (AirStore appears as StikDebug). The guest
  listing is published into the group `ContainerApps/`; removals use `ContainerDelete/`. Do not
  build a second copy of these mechanisms.
- **Free account limits**: 3 active apps / 10 App IDs. AirBox guests do not consume those slots;
  system-installed apps do.
- **Localization**: every new user-visible string goes through `Localizable.xcstrings` with a
  `zh-Hans` value. English and Chinese READMEs (`README.md`, `README_zh.md`) are maintained together;
  AirBox docs live in `AIRBOX.md`.
- **Never commit** pairing files, certificates, private keys, Anisette data, Apple IDs, passwords, or
  device UDIDs. Do not log credential material.

## Where to start for common work

| Task | Start here |
| --- | --- |
| `-80045` / Anisette | `SideStore/Core/Anisette/`, `AltStore/Settings/AnisetteManager.swift`, `SideStore/Core/Auth/` |
| AirBox engine / guests | `Dependencies/LiveContainer`, `AirBox/`, `SideStore/Core/Container/` |
| Install / refresh / sign | `SideStore/Core/Operations/`, `AltStore/Managing Apps/AppManager.swift` |
| Pairing | `SideStore/Core/Pairing/PairingFileManager.swift`, `SideStore/MaintenanceManager.swift` |
| Deep links | `SideStore/DeepLinks/URLHandler.swift`, `AppDelegate.swift`, `AltStore/TabBarController.swift` |
| Feed / release | `source/airstore-source.json`, `scripts/ci/`, `.github/workflows/` |
| Helper | `Helper/` (Tauri 2; `npm ci && npx tauri build --bundles app --ignore-version-mismatches`) |

## Definition of done for an agent

1. The change is scoped to one problem; unrelated code is untouched.
2. Type/parse checks pass, the relevant target builds (locally or CI), SwiftLint errors stay at zero.
3. New strings have `zh-Hans` entries; user-facing docs match reality (no promises, no stale versions).
4. No secrets, credentials, pairing files, certificates, or build artifacts in the diff.
5. AGENTS.md is updated when the change alters anything this file describes.
6. The human can explain the change without generated text; AI involvement is disclosed in the
   PR/issue text.

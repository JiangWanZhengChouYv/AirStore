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
   `AnisetteServerProbe.swift` HEAD-checks each server for the green/red dots in the settings list;
  `AnisetteProvider` uses its cached results to try dead servers last, and reports every server's
  own error instead of the last one (usually a 503). Rotation is on by default. Each theme also
  ships a small `Theme*.imageset` (a runtime-loadable copy of the appiconset, which `UIImage(named:)`
  cannot load); `ThemeManager.currentAppIconImage` is what SplashView and onboarding must use.
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
- **Per-account credentials, step 1 only** (2026-11-14): the four Apple ID slots in `Keychain`
  (`appleIDEmailAddress` / `Password` / `Adsid` / `XcodeToken`) read from `<key>.<accountIdentifier>`
  when `UserDefaults["AirStoreActiveAccountScope"]` is set and fall back to the unscoped key
  otherwise; a write goes to the scoped slot, and clearing removes both. `adoptCredentials(for:)`
  copies a fresh sign-in into that account's namespace and moves the scope; the unscoped copies stay
  on purpose so an older build still finds them. Nothing switches accounts yet: `AuthManager.session`
  is still one global object, and install/refresh still use the active account rather than
  `InstalledApp.appID → Team.account`.
- **Guide re-verified against the tree at `ce5d69ab`** (2026-11-14): bundle id, iOS 17.4, Swift 5
  mode, `PRODUCT_NAME = "$(TARGET_NAME)"`, four tabs in both `AltStore/iOS/Main.storyboard` and
  `AltStore/tvOS/Main.storyboard`, the six settings group ids (`account`, `appearance`, `refresh`,
  `connection`, `diagnostics`, `about`), `rescue.yml`, and the compilation-cache keys below all match
  the code. The stale "the new-UI toggle lives in the App Group" sentence was removed — no such
  toggle exists any more.

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
- The develop feed is written to the **`develop-source`** branch and served to the app through
  **`https://as.mz0520.de5.net/source/airstore-source.json`** — a Cloudflare Worker deployed from
  `cloudflare/airstore-feed/`. The Worker fetches the branch at request time and answers `no-store`,
  so there is no CDN copy to go stale and no purge step. It also proxies this repository's raw files
  (`/gh/OWNER/REPO@REF/PATH`) and release assets (`/dl/OWNER/REPO/TAG/FILE`) for the app's mirrors.
  Keep the `/source/airstore-source.json` path: `Source.isAirStoreOfficial` uses that suffix to
  migrate rows that still carry the old host. Do not hand-edit generated feeds.
- Redeploying the Worker needs a Cloudflare login: `cd cloudflare/airstore-feed && npx wrangler
  deploy` (the `routes` entry attaches `as.mz0520.de5.net` and creates its DNS record and
  certificate). The Pages mirror remains **parked** — do not reintroduce a git-branch mirror, and do
  not add a CDN purge back. jsDelivr is only a last-resort fallback in `URL+Mirror.swift`.
- Delta updates are cut by `scripts/ci/make_patch.py` (ASBU/ASDP2) against recent builds; retention is
  five builds plus their patches.
- The Helper publishes to the rolling prerelease **`helper-latest`** (macOS zip + Windows NSIS
  installer), ad-hoc/unsigned in CI. Local copies are signed with the stable local certificate.
- `stable.yml` builds releases from tags; published releases/tags are never deleted or moved.
- Do not bump `MARKETING_VERSION` on develop to a version lower than the released stable; develop
  versions use `x.y.z-develop-<timestamp>.<run>-<sha>`.

Runner economy (added 2026-11-13/14, all in `.github/workflows/develop.yml` and
`scripts/ci/changed_parts.py`):

- `prepare` compares the pushed tree against `github.event.before` with
  `git diff --name-only` and runs `changed_parts.py`; its `app` / `airbox` / `helper` outputs gate
  `build-airstore`, `build-airbox`, `build-helper` and `build-helper-windows`. An app-only push spends
  one macOS runner instead of four. An empty or failed file list means "build everything" — ambiguity
  must never leave a stale package on the release.
- A manual run defaults to `app_only: true`, so `workflow_dispatch` rebuilds the store alone.
- Every macOS job uses `runs-on: ${{ vars.MACOS_RUNNER || 'macos-26' }}`; set the repository variable
  to move them to a self-hosted Mac, leave it unset for hosted.
- `publish` runs when `build-airstore` succeeded and `build-airbox` did not fail; a skipped AirBox
  carries its last feed entry forward via `develop_source.py --companion-carry-from`.
- `rescue.yml` (`*/20` cron + `workflow_run` on completed develop runs) runs
  `scripts/ci/rescue_build.py`: it waits if a run for the tip is queued/building, rebuilds when the
  published feed's commit differs from the tree, and re-dispatches only when `Build AirStore` was
  cancelled before its first step. A red build is never retried.
- `build-airstore` / `build-airbox` now enable Xcode 26's compilation cache through `Makefile`
  (`COMPILATION_CACHE_*`, `MODULE_CACHE_DIR`); the cache lives at the DerivedData **root**
  (`DerivedData/CompilationCache.noindex`), not `DerivedData/*/`, and `develop.yml` restores that path
  plus `SourcePackages` and `~/Library/Caches/org.swift.swiftpm` under key `xcode-v2-develop-airstore-`.

## UI

The app has **one** interface: the UIKit/storyboard UI under `AltStore/`, with individual SwiftUI
screens pushed from it (`SideStore/Views/Onboarding/`, `SideStore/Views/Settings/**`).

- A parallel opt-in SwiftUI shell (`SideStore/Views/NewUI/`, `UIStylePreferences`, the "Interface"
  switch in 高级 → 用户自定义) existed during 2026 and was **removed at the maintainer's request on
  2026-11-11**. Do not reintroduce it, and do not add a second shell or a UI-style switch.
  A Phase 5/6 handoff brief from October still mentions `SideStore/Views/NewUI/NewRootView.swift`,
  `SideStore/Core/Preferences/UIStylePreferences.swift` and
  `SideStore/Views/Settings/AppearanceSettingsView.swift` — **none of those files exist**; treat that
  brief as history, not a task list. The settings search / glass rows / theme icons it describes were
  later built into the classic UI (see below).
- New work goes into the classic UI. The settings home is a SwiftUI surface
  (`SideStore/Views/Settings/SettingsHomeView.swift`) hosted by `SettingsViewController`: six groups
  (Account, Appearance, Refresh, Connection, Diagnostics, About), each one large glass pane holding
  many rows. The classic table view stays loaded underneath for its outlets and segues, but is
  covered and non-scrolling — **add a new row in SettingsHomeView, not in Settings.storyboard**.
  `SettingsViewController.performSettingsAction(_:)` is the single entry point for all destinations.
  The home is a subview of the table view, so **every `tableView.reloadData()` must go through
  `reloadClassicTable()`** — the reload re-inserts static cells above the home, which keeps it visible
  (zPosition) but makes every row untappable. `viewDidLayoutSubviews` also re-fronts it.
- **Settings search** (2026-11-13): a pinned glass `TextField` filters rows by title/subtitle
  (case- and diacritic-insensitive) and keeps the matching group as context. The pages behind the
  rows are searched too, through `SideStore/Views/Settings/SettingsSearchCatalog.swift` — a static
  map from a home row id to the string keys inside that page. It does **not** deep-link to a single
  switch: a second-level hit opens the page. When you add a row to one of those pages, add its title
  there or search cannot find it.
- **Row press feedback** is the system's own: the group pane uses
  `glassSurface(in:interactive: true)` (iOS 26 `Glass.regular.interactive()`). Do not re-add
  `scaleEffect` / `brightness` / `simultaneousGesture` press hacks — they either never fired (a
  `ButtonStyle` cannot reach the pane) or stole the scroll gesture. iOS 17.4–25 has no press
  response, which is accepted.
- `Shared/Extensions/View+GlassSurface.swift` stays: the onboarding flow uses it.
- The onboarding flow keeps its six steps and all auth/pairing/container logic; it is SwiftUI and
  re-skinned in place (`SideStore/Views/Onboarding/OnboardingView.swift`).
- **Each theme preset has its own app icon** (maintainer, 2026-11-13). The six `Theme*Icon.appiconset`
  files in `AltStore/Resources/Icons.xcassets/Theme/` are hue-rotated copies of the shipped blue
  icon; `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` registers them automatically, so no
  Info.plist edit. `ThemePreset.alternateIconName` maps a preset to its icon (`nil` = primary blue),
  and `ThemeManager.applyThemeAppIcon` switches it after the picker dismisses, before the relaunch.
  Custom colours that are not presets keep the current icon.
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

- **Boot order — never touch Core Data from `didFinishLaunching`.** The store is opened in a detached
  task in `AltStore/AppDelegate.swift:189-196`: `MaintenanceManager.performDatabaseMigrationIfNeeded()`
  first, then `DatabaseManager.start()`. Reading `persistentContainer.viewContext` (or calling
  `newBackgroundContext()`) **opens the store synchronously at the call site**, before that migration
  has run. The result is the 2026-10-20 crash: the app paints one frame — the floating glass tab bar
  on iOS 26, or the onboarding buttons before it — and dies a moment later, often before the console
  log has a line. (The same symptom on 2026-11-18 turned out to be EBADEXEC, see the next bullet —
  match the symptom to the cause instead of assuming boot order.)
  - Put launch-time database work **inside that detached task, after
    `debugLog("Started DatabaseManager.")`**, on a background context. Where ordering cannot be
    controlled, gate on `DatabaseManager.shared.isStarted` (`SceneDelegate` and `ProfileManager`
    already do).
  - `LaunchViewController` only swaps in the tab bar after `start()` returns, so a crash *after* the
    tab bar is visible is usually a different bug. Check the log before "fixing" the boot order.
  - Getting the stack: read the app's own `Documents/ConsoleLogs/console_*.log` **first**.
    `setupCrashHandler()` writes the exception name, reason and full call stack (and
    SIGABRT/SEGV/BUS/ILL/FPE/TRAP) through `debugLog`, which the console logger captures; export it
    from 设置 → 诊断 → 错误日志. Only then compare against a CI build of the same commit — a past
    investigation wrongly blamed the SDK.
- **No crash report, no log, snapshot flashes — suspect the install, not the code.** On 2026-11-18 the
  app died this way; `xcrun devicectl device process launch --device <UDID> <bundle-id>` answered
  `Launchd job spawn failed (NSPOSIXErrorDomain error 85)`, and errno 85 on Darwin is **EBADEXEC**:
  the binary never ran, so there is nothing for `setupCrashHandler()` or the analytics store to
  record. A control launch of AirBox (same team suffix, same certificate) worked, which ruled out an
  expired profile; an **overwrite install** through the Helper fixed it without touching code.
  Recipe: `devicectl list devices` → `device info apps` (the sideloaded bundle id carries the team
  suffix, e.g. `…AirStore.LJF4F9N5NG`) → `device process launch`, and pull device reports with
  `device copy from --domain-type systemCrashLogs --source .`.
- **Do not broadly refactor signing, installation, or networking.** Install/refresh/sign have many
  iOS-version edge cases (17.4+). Be skeptical of generated code and preserve behavior outside the fix.
- **Pairing**: the Helper/iLoader writes `ALTPairingFile.mobiledevicepairing`,
  `PairingFile_RemoteRP.plist` and `PairingFile_Lockdown.plist` into the app's Documents.
  `PairingFileManager.adoptAvailablePairingFile()` adopts them at boot (prefers Remote Pairing) when
  no protocol has been chosen. Manual pairing uses the separate **idevice_pair** app; do not tell
  users to import a file exported from an existing desktop pairing record (it does not work).
- **Self-updates**: an in-app update reinstalls the app and creates a fresh container. Launch code
  must skip `isFirstLaunch` sign-out and the destructive maintenance passes (1–2) when
  `reconcileSelfReinstallationIfNeeded()` confirms a self-update. A true uninstall/reinstall still
  resets app data — that is iOS behavior, not a bug.
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
| Feed mirror (Cloudflare) | `cloudflare/airstore-feed/` (`as.mz0520.de5.net`, `npx wrangler deploy`) |
| Helper | `Helper/` (Tauri 2; `npm ci && npx tauri build --bundles app --ignore-version-mismatches`) |

## Definition of done for an agent

1. The change is scoped to one problem; unrelated code is untouched.
2. Type/parse checks pass, the relevant target builds (locally or CI), SwiftLint errors stay at zero.
3. New strings have `zh-Hans` entries; user-facing docs match reality (no promises, no stale versions).
4. No secrets, credentials, pairing files, certificates, or build artifacts in the diff.
5. AGENTS.md is updated when the change alters anything this file describes.
6. The human can explain the change without generated text; AI involvement is disclosed in the
   PR/issue text.

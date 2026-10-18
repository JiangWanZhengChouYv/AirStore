# Contributing to AirStore

Thanks for your interest in contributing to AirStore!

AirStore is a fork of [SideStore](https://github.com/SideStore/SideStore), which itself is a fork of
[AltStore](https://github.com/altstoreio/AltStore). Like SideStore, it sideloads and refreshes apps on-device with a
personal Apple ID and needs no AltServer.

This repository exists for one specific reason: **resolve the `-80045` Apple ID authentication error on iOS 26.4 and
above.** Apple tightened its GrandSlam Anisette restrictions, which left users stuck in a login loop because public
Anisette servers are blocked or unstable. AirStore works around this by rewriting the Anisette data request logic and
sending the client headers Apple expects.

Everything else here is inherited from upstream. Other changes are welcome, but they are lower priority and may wait a
long time for review.

## Maintenance reality

AirStore is maintained by one person in their spare time, so review capacity is the bottleneck:

-   Open an issue before starting work that is more than a few lines, so you don't build something that can't be
    reviewed.
-   Keep pull requests small and single-purpose. Changes that spread across signing or networking code cost far more
    review time than focused ones.
-   Bug reports need logs and reproduction steps to be actionable. Search existing issues before opening one.

By contributing to this project, you agree to the Developer's Certificate of Origin found in
[CERTIFICATE-OF-ORIGIN.md](CERTIFICATE-OF-ORIGIN.md). Contributions after the addition of that file are subject to its
policy.

## Other ways to help

If you aren't writing code, these are just as useful:

-   Reproducing `-80045` across iOS builds and reporting which iOS version, Apple ID type, and Anisette server
    configuration you used.
-   Submitting detailed bug reports through [GitHub Issues](https://github.com/JiangWanZhengChouYv/AirStore/issues).
-   Testing pull requests from other contributors and posting the results, including the iOS version and build you
    tested on.

## Requirements

This guide assumes you:

-   are on a Mac
-   have Xcode 15 or newer installed
-   have basic command line knowledge (know how to run commands, cd into a directory)
-   have basic Git knowledge ([GitHub Desktop](https://desktop.github.com) is a great tool for beginners, and greatly
    simplifies working with Git)
-   have basic Swift/iOS development knowledge

## Setup

1.  Fork this repository on GitHub.
2.  Clone the fork **with submodules**. `Dependencies/minimuxer` and `Dependencies/SideSign` are submodules and are
    empty directories without this:

    ```sh
    git clone https://github.com/<your github username>/AirStore.git --recurse-submodules
    ```

    Already cloned without the flag? Run `git submodule update --init --recursive`.

    If you are using GitHub Desktop, refer to
    [this guide](https://docs.github.com/en/desktop/contributing-and-collaborating-using-github-desktop/adding-and-cloning-repositories/cloning-and-forking-repositories-from-github-desktop).

3.  Copy `CodeSigning.xcconfig.sample` to `CodeSigning.xcconfig` and fill in your `DEVELOPMENT_TEAM` and signing
    options.
4.  Open `AltStore.xcodeproj`. Xcode resolves dependencies on its own: `SideSign` and `minimuxer` are local Swift
    Packages, and the remaining libraries (MarkdownKit, KeychainAccess, Nuke, Starscream, SemanticVersion, CodeSignKit)
    are remote Swift Packages.

    There is no CocoaPods in this project. If an older guide tells you to run `pod install`, it is out of date — there
    is no `Podfile`.

Next, make and test your changes. Then commit and push them and open a pull request against `develop`.

## Where the `-80045` work lives

Start with these if you want to help with the Anisette logic:

-   `SideStore/Core/Anisette/` — `AnisetteProvider.swift`, `AnisetteServersManager.swift`,
    `OnDeviceAnisetteManager.swift` and `AnisetteConfigManager.swift`: how Anisette data is obtained, and which
    provider or server supplies it.
-   `AltStore/Settings/AnisetteManager.swift` and `AltStore/Settings/AnisetteServerList.swift`: the settings-side
    entry point and the server list used by the providers above.
-   `SideStore/Views/Settings/Advanced/Anisette/`: the runtime UI for inspecting and changing this.
-   `SideStore/Core/Auth/`: the Apple ID authentication flow where `-80045` surfaces.

App installation, certificate signing, and pairing have tricky edge cases across the supported iOS versions (iOS 15+).
Preserve existing behavior outside the fix you intend to make, and avoid broad refactors in signing or networking code.

## Building an IPA for distribution

From the repository root, after the setup above:

```sh
# stable release build
make build fakesign ipa

# stable debug build
export BUILD_CONFIG=Debug; make build fakesign ipa

# alpha / beta builds
export IS_ALPHA=1; make build fakesign ipa
export IS_BETA=1; make build fakesign ipa

# custom bundle ID suffix
export BUNDLE_ID_SUFFIX=XYZ0123456; make build fakesign ipa
```

When building from Xcode, `BUNDLE_ID_SUFFIX` defaults to the value of `DEVELOPMENT_TEAM`; override it in your
`CodeSigning.xcconfig` if you want something else.

Two things to know while the rename from SideStore is still in progress:

-   The build output is `SideStore.ipa`, because `PRODUCT_NAME`, `ORG_IDENTIFIER` and `BASE_BUNDLE_ID` in
    `Build.xcconfig` are still `SideStore` and `com.SideStore.SideStore`. Only the name in the documentation is
    AirStore so far.
-   The bundle ID used for the device's app group, iCloud container and provisioning follows from those same settings,
    so a `BUNDLE_ID_SUFFIX` change is not cosmetic — it changes which containers the app can reach.

> **Warning**
>
> The binary that is created will contain paths to Xcode's DerivedData and, if you built `minimuxer` on your machine,
> paths to `$HOME/.cargo`. This includes your username. If you want to keep your username private, have GitHub Actions
> build the IPA instead.

## Developing minimuxer alongside AirStore

`minimuxer` and `em_proxy` come from upstream SideStore as a submodule pinned to its `develop` branch. See
[minimuxer's README](https://github.com/SideStore/minimuxer) for development instructions. Keep dependency bumps out of
feature pull requests so each change stays reviewable.

## Using AI in your contribution

Declare in your pull request whether AI helped you find, test, or implement the change, and how. That is the only
requirement, but you must be able to explain the change and your own decisions about it without leaning on generated
text: one human reads every diff.

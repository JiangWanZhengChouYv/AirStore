# AirStore
<p align="center"><img src="assets/airstore-header-1280x640.png" alt="AirStore - on-device sideloading and refresh. No AltServer." width="860"></p>

<p align="center">
  <a href="https://github.com/JiangWanZhengChouYv/AirStore/releases/latest"><img src="https://img.shields.io/github/v/release/JiangWanZhengChouYv/AirStore?label=release&color=blue" alt="Latest release"></a>
  <a href="https://github.com/JiangWanZhengChouYv/AirStore/actions/workflows/swiftlint.yml"><img src="https://img.shields.io/github/actions/workflow/status/JiangWanZhengChouYv/AirStore/swiftlint.yml?label=swiftlint&branch=develop" alt="SwiftLint"></a>
  <a href="https://discord.gg/kN9Rm3kkZ"><img src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
</p>

> [!CAUTION]
> **0.9.0 changes the signing identifier.** The bundle id is now `com.JiangWanZhengChouYv.AirStore`
> (previously `com.SideStore.SideStore`), so this release cannot be installed over an older AirStore
> or SideStore -- they are separate apps. Before switching, export your certificate and pairing file
> (Settings), uninstall the old build, install this one, then import them back. The app group changed
> too, so the old app data is not carried over either way.


**AirStore is a fork of SideStore that does not require an AltServer. It aims to be the better SideStore — the place a user stays, not a temporary fix for one Apple error. It started by resolving the notorious `-80045` authentication error for iOS 26.4 and above, and kept going from there.**

中文说明见 [README_zh.md](README_zh.md)。

## ⚠️ Maintenance Notice & Disclaimer

> **Maintained by a Solo Developer**
> Please note that AirStore is a solo project maintained by an independent developer in my spare time. While I will do my absolute best to fix critical issues (especially the `-80045` error), I may not be able to respond to every issue or review every PR promptly. 
> 
> **Before opening an issue, please:**
> 1. Search existing issues to avoid duplicates.
> 2. Provide detailed logs and reproduction steps.
> 
> Thank you for your patience and understanding! (我一个人肝不过来，求别催，提Issue请带详细日志！)

## 🚀 Why AirStore?

Recently, Apple tightened its GrandSlam Anisette restrictions. This caused countless users to get stuck at the `-80045` login error when trying to sign in with their Apple ID on SideStore, especially on newer iOS versions (26.4+). 

Public Anisette servers are largely blocked or unstable. AirStore gets past this by matching the client headers to the identity of the v3 Anisette server that mints them, and by signing in with that server's own client declaration. Apple ID sign-in is verified working on iOS 27.2 with a free personal account.

## ✨ Features

- **No AltServer Required:** Just like the original SideStore.
- **`-80045` Bypass:** Fixes the Apple server restrictions and login loops on iOS 26.4+.
- **Higher memory ceiling and on-device JIT:** Apps that need more RAM, and JIT for the ones that need it, requested with a free personal account.
- **Incremental updates:** An update fetches a patch against the build you have instead of the whole package.
- **Installs over mobile data:** No Wi-Fi needed to sideload or refresh. Verified on the maintainer's device with a free personal account and Wi-Fi turned off -- the "connect to a network" refusal most guides describe is not a limit here.
- **Pairing and certificate import/export:** Set up a second device, or survive a reinstall, without redoing the whole pairing dance.
- **Simplified Chinese interface.**
- **Lightweight:** Minimal footprint on your device.

Experimental: **AirBox**, a container that runs apps without spending one of a free account's three App ID
slots. On device it now launches guests with the higher memory ceiling; JIT is not available inside the
container yet. Container Mode in onboarding installs AirBox for you.

## 🛠️ Installation

The current stable is [0.9.0](https://github.com/JiangWanZhengChouYv/AirStore/releases/latest).
Download `AirStore.ipa` and install it the way you already install SideStore: iloader, or the
in-app remote pairing flow. This release uses AirStore's own bundle id
(`com.JiangWanZhengChouYv.AirStore`), so it installs as a separate app and does not replace an older
AirStore or SideStore. To move over, export your certificate and pairing file first, uninstall the
old build, install this one, then import them back. The Home Screen label is AirStore.
For the development builds, add the develop source described under Updates below.

Verified on device with a free personal account: sign-in including 2FA (iOS 27.2), installing and
refreshing third-party apps including incremental updates, installing over mobile data with Wi-Fi
off, and on-device JIT for normally installed apps. AirBox now launches guests with the higher memory
ceiling; JIT inside the container is not available yet. Logins still depend on a third-party Anisette
server staying online -- see the self-hosting section if you want that dependency to be yours.

### Updates

The SideStore community source lists SideStore itself, but since 0.9.0 AirStore is a different app,
so that row can no longer overwrite it. AirStore's own updates come from this source
(Settings > Sources > Add Source):

```
https://raw.githubusercontent.com/JiangWanZhengChouYv/AirStore/develop/source/airstore-source.json
```

It carries only AirStore releases. An older AirStore (`com.SideStore.SideStore`) cannot update to
0.9.0 in place -- follow the migration steps under Installation.

## 🖥️ Self-hosting Anisette (the safest option)

**The default stays the public servers** -- nothing below is required. But a public server means your
machine identity and IP are shared with everyone else on it, and public servers do change face without
warning. Running your own removes both: the identity and the IP are yours, and to Apple the traffic looks
like one ordinary AltServer user. Account locks come from repeated wrong passwords and abuse patterns,
not from self-hosting.

```sh
docker run -d --restart always --name anisette-v3 -p 6969:6969 \
  --volume anisette-v3_data:/home/Alcoholic/.config/anisette-v3/lib/ \
  dadoum/anisette-v3-server
```

- **Keep the volume.** It holds the provisioned machine identity; minting a new machine on every restart
  is the behaviour that looks like abuse. Images exist for linux/amd64 and linux/arm64, so a Mac or a
  small VPS both work.
- In AirStore: Settings > Anisette Servers, add `http://<that machine's address>:6969` and select it.
- **Keep it to yourself.** Opening it to other people turns you back into a public server and reconnects
  the shared-identity risk you just cut.

## Building from source

Requires macOS with Xcode 15+. There is no CocoaPods in this project: do not run `pod install`,
and there is no `.xcworkspace` to open.

```sh
git clone https://github.com/JiangWanZhengChouYv/AirStore.git --recurse-submodules
cd AirStore
make build fakesign ipa        # produces AirStore.ipa
make ipa-airbox                # produces AirBox.ipa (built from the LiveContainer project)
```

`fakesign` means the build carries no developer certificate, which is what you want: the app gets
its own identity from your Apple ID at first sign-in. CI builds the same way, so a packaged IPA is
also available from the Actions run for any commit.

## 💬 Feedback & Community

Settings → Send Feedback in the app offers two ways side by side: **Report an Issue on GitHub** and
**Give Feedback on Discord**.

- Issues: <https://github.com/JiangWanZhengChouYv/AirStore/issues> — attach the log, which lives in the
  Files app under **AirStore → ConsoleLogs** (newest `console_….log`). A report without one usually
  cannot be reproduced.
- Discord: <https://discord.gg/kN9Rm3kkZ> — discussion, and where the develop builds announce
  themselves. It is the fastest way to reach me; the issue tracker is still where a fix gets followed
  up.

## 🤝 Contributing

Pull requests are welcome! If you have a fix for the Anisette logic, feel free to submit a PR. However, please understand that review times may be slow due to solo maintenance.

## ⚖️ Credits & License

- Based on [SideStore](https://github.com/SideStore/SideStore)
- Based on [AltStore](https://github.com/altstoreio/AltStore)
- Licensed under the same license as the original project.

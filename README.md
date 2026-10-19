# AirStore

**AirStore is a fork of SideStore that does not require an AltServer. Our primary goal is to resolve the notorious `-80045` authentication error for iOS 26.4 and above.**

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
- **Lightweight:** Minimal footprint on your device.

## 🛠️ Installation

The current build is the [0.8.0 pre-release](https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/0.8.0).
Download `SideStore-0.8.0.ipa` and install it the way you already install SideStore: iloader, or the
in-app remote pairing flow. AirStore keeps SideStore's bundle id on purpose, so installing it
replaces an existing SideStore rather than sitting beside it. The Home Screen label is AirStore.

Read the release notes before installing. Sign-in is the only path that has been re-tested, and
logins depend on a third-party Anisette server staying online.

## Building from source

Requires macOS with Xcode 15+. There is no CocoaPods in this project: do not run `pod install`,
and there is no `.xcworkspace` to open.

```sh
git clone https://github.com/JiangWanZhengChouYv/AirStore.git --recurse-submodules
cd AirStore
make build fakesign ipa        # produces SideStore.ipa
```

`fakesign` means the build carries no developer certificate, which is what you want: the app gets
its own identity from your Apple ID at first sign-in. CI builds the same way, so a packaged IPA is
also available from the Actions run for any commit.

## 🤝 Contributing

Pull requests are welcome! If you have a fix for the Anisette logic, feel free to submit a PR. However, please understand that review times may be slow due to solo maintenance.

## ⚖️ Credits & License

- Based on [SideStore](https://github.com/SideStore/SideStore)
- Based on [AltStore](https://github.com/altstoreio/AltStore)
- Licensed under the same license as the original project.

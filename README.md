# AirStore

**AirStore is a fork of SideStore that does not require an AltServer. Our primary goal is to resolve the notorious `-80045` authentication error for iOS 26.4 and above.**

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

Public Anisette servers are largely blocked or unstable. AirStore aims to bypass these restrictions by rewriting the Anisette data request logic and spoofing proper client headers to mimic a legitimate environment.

## ✨ Features

- **No AltServer Required:** Just like the original SideStore.
- **`-80045` Bypass:** Fixes the Apple server restrictions and login loops on iOS 26.4+.
- **Lightweight:** Minimal footprint on your device.

## 🛠️ Build & Installation

*(WIP - Work in Progress)*
Currently, this project is in active development. You can build it from source using Xcode.
- Requires macOS, Xcode, and CocoaPods.
- Clone the repo and run `pod install`.
- Open `.xcworkspace` and build.

## 🤝 Contributing

Pull requests are welcome! If you have a fix for the Anisette logic, feel free to submit a PR. However, please understand that review times may be slow due to solo maintenance.

## ⚖️ Credits & License

- Based on [SideStore](https://github.com/SideStore/SideStore)
- Based on [AltStore](https://github.com/altstoreio/AltStore)
- Licensed under the same license as the original project.

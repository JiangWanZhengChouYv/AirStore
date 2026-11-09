# AirStore Helper

A small companion app for [AirStore](https://github.com/JiangWanZhengChouYv/AirStore): plug the iPhone in
(or put it on the same network), sign in with your Apple ID once, and it signs and installs AirStore for you.
It can also install other IPAs directly and place a pairing file into AirStore's Documents.

The interface is a re-skin of [iLoader](https://github.com/nab138/iloader) (MIT); the code is reused with
attribution, the name and logo are not. This is not an official iLoader release and is not affiliated with
its author.

## Quick start

Download from the [AirStore Helper release](https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/helper-latest):

| Platform | File |
| --- | --- |
| macOS on Apple silicon | `AirStoreHelper-macos.zip` -- unzip and drag to Applications |
| Windows 10/11 x64 | `AirStoreHelper-windows-x64-setup.exe` |

1. Install the app and open it.
2. Connect the iPhone over USB, or put it on the same local network. On Windows, install
   [iTunes](https://apple.co/ms) first -- Apple Mobile Device Support is what lets the Helper see the phone.
3. Pick the device, sign in with your Apple ID, and press install. The Helper downloads AirStore
   (stable, or Develop for the current develop build), signs it, installs it, and writes the pairing
   file into AirStore's Documents.
4. Open AirStore. It adopts that pairing file on launch, so the pairing prompt should not appear.

Packages on that release are rebuilt from `develop` and replaced whenever it moves. The Mac app is
ad-hoc signed (right-click > Open the first time) and the Windows installer is unsigned, so SmartScreen
asks for confirmation. Neither is notarized.

## Build

The source lives in AirStore's `Helper/` directory. It is a normal Tauri 2 project, built with Node and Rust,
and is not part of the Xcode workspace.

```sh
cd Helper
npm install
npx tauri icon src/airstore.png   # regenerate the icon set if you replace the logo
npx tauri build --bundles app --ignore-version-mismatches
# produces AirStore Helper.app under src-tauri/target/release/bundle/macos
```

On Windows, bundle with NSIS instead:

```sh
npx tauri build --bundles nsis --ignore-version-mismatches
```

The develop CI builds both platforms (macOS on a Mac runner, Windows on `windows-latest`) and publishes
them to the rolling `helper-latest` prerelease. CI signs the Mac build ad-hoc because no runner holds
this Mac's signing certificate; the copy installed here is signed locally with the stable
"AirStore Helper Local" identity so the keychain stops asking on every update.

## Notes

- Signing uses your own Apple ID; credentials stay in the OS keychain (Keychain on macOS, Credential
  Manager on Windows).
- Install offers the latest stable AirStore and, through the Develop button, the current develop build.
- Pairing: the pairing screen generates the file and this app places it in AirStore's Documents.
  AirStore adopts that file on its next launch when no protocol has been chosen yet.

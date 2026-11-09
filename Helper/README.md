# AirStore Helper

A small companion app for [AirStore](https://github.com/JiangWanZhengChouYv/AirStore): plug the iPhone in
(or put it on the same network), sign in with your Apple ID once, and it signs and installs AirStore for you.
It can also install other IPAs directly and place a pairing file into AirStore's Documents.

The interface is a re-skin of [iLoader](https://github.com/nab138/iloader) (MIT); the code is reused with
attribution, the name and logo are not. This is not an official iLoader release and is not affiliated with
its author.

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

The develop CI builds the same source as one of its parallel macOS jobs and uploads `AirStoreHelper.zip`.
That artifact is ad-hoc signed, because no runner holds this Mac's signing certificate; the copy that is
installed here is signed locally with the stable "AirStore Helper Local" identity so the keychain stops
asking on every update. Build and sign locally for that copy.

## Notes

- Signing uses your own Apple ID; credentials stay in this Mac's keychain.
- Install offers the latest stable AirStore and, through the Develop button, the current develop build.
- Pairing: iLoader's pairing screen generates the file and this app places it in AirStore's Documents.
  AirStore adopts that file on its next launch when no protocol has been chosen yet.

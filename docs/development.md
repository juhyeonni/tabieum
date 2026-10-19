# Development

How to build, test, sign and release tabieum. The [README](../README.md) has the short version.

You need macOS 15, Swift 6.2 or later, and either Xcode or only the Command Line Tools (`xcode-select --install`). Swift 6.2 is the floor because the pinned `swift-collections` needs it; CI selects Xcode 26.3 for the same reason.

```sh
swift build          # debug build
scripts/test.sh      # run the tests
scripts/bundle.sh    # build build/tabieum.app (release, ad-hoc signed)
open build/tabieum.app
```

A build you make yourself is not downloaded, so macOS does not show the first-launch warning.

- **Tests with only the Command Line Tools:** they ship Swift Testing, but plain `swift test` cannot find `Testing.framework` and `lib_TestingInterop.dylib`. `scripts/test.sh` adds the missing search paths and rpaths; with Xcode it runs plain `swift test`. Always run tests through the script.
- **Keep permissions across rebuilds:** an ad-hoc build gets a new signature every time, so macOS asks again for the permissions and for Keychain access to the AI key. Create a self-signed code-signing certificate once (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing), trust it for code signing, and build with `TABIEUM_SIGN_IDENTITY="<certificate name>" scripts/bundle.sh`. The permissions then survive rebuilds.
- **Debug options:** options that are only for developing and testing the app (the caret overlay, the Vim latency readout) go in the Debug tab of Settings, not in the menu bar item or another tab.
- **Releases:** set `VERSION` in `Config/product.env`, then run `TABIEUM_SIGN_IDENTITY="<certificate name>" scripts/release.sh`. It runs the tests, builds an arm64 and an x86_64 slice, joins them into one universal app, signs it and writes `dist/tabieum-<version>.zip` and its SHA-256. It refuses to run without a certificate.
- **Universal builds:** `scripts/bundle.sh` builds for this Mac only. Set `TABIEUM_ARCHS="arm64 x86_64"` to build both slices. The Command Line Tools cannot build both in one `swift build --arch` call, so the script builds each with `--triple` and joins them with `lipo`.
- The product name, bundle ID, URL scheme, version and release repository live in `Config/product.env`; change them there and nowhere else.

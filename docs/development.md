# Development

How to build, test, sign and release tabieum. The [README](../README.md) has the short version.

You need macOS 15 and either Xcode or only the Command Line Tools (`xcode-select --install`).

```sh
swift build          # debug build
scripts/test.sh      # run the tests
scripts/bundle.sh    # build build/tabieum.app (release, ad-hoc signed)
open build/tabieum.app
```

A build you make yourself is not downloaded, so macOS does not show the first-launch warning.

- **Tests with only the Command Line Tools:** they ship Swift Testing, but plain `swift test` cannot find `Testing.framework` and `lib_TestingInterop.dylib`. `scripts/test.sh` adds the missing search paths and rpaths; with Xcode it runs plain `swift test`. Always run tests through the script.
- **Keep permissions across rebuilds:** an ad-hoc build gets a new signature every time, so macOS asks again for the permissions and for Keychain access to the AI key. Create a self-signed code-signing certificate once (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing), trust it for code signing, and build with `TABIEUM_SIGN_IDENTITY="<certificate name>" scripts/bundle.sh`. The permissions then survive rebuilds.
- **Releases:** set `VERSION` in `Config/product.env`, then run `TABIEUM_SIGN_IDENTITY="<certificate name>" scripts/release.sh`. It runs the tests, builds, signs and writes `dist/tabieum-<version>.zip` and its SHA-256. It refuses to run without a certificate.
- The product name, bundle ID, URL scheme, version and release repository live in `Config/product.env`; change them there and nowhere else.

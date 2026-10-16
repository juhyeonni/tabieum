# NoteKit

A local-first companion app for Apple Notes. No account, no server. See [docs/PROPOSAL.md](docs/PROPOSAL.md) for the plan.

`NoteKit` is a placeholder name. The product name, bundle ID and URL scheme live in `Config/product.env`; change them there and nowhere else.

## Requirements

macOS 15 and either Xcode or only the Command Line Tools (`xcode-select --install`).

## Build, test, bundle

```sh
swift build          # debug build
scripts/test.sh      # run the tests
scripts/bundle.sh    # build build/NoteKit.app (release, ad-hoc signed)
open build/NoteKit.app
```

The app runs as a menu-bar item with no Dock icon.

## Notes

- **Search index:** the app keeps a full-text index of your unlocked notes in `~/Library/Application Support/<bundle id>/index.sqlite`. It holds a plain-text copy of each note's title, folder and Markdown body, outside the Notes container, so any process running as you can read it. Locked notes are never indexed. It is a cache: delete the file and it is rebuilt. Syncing needs Full Disk Access; without it the app keeps running and logs why it cannot sync.
- **Tests with only the Command Line Tools:** they ship Swift Testing, but plain `swift test` cannot find `Testing.framework` and `lib_TestingInterop.dylib`. `scripts/test.sh` adds the missing search paths and rpaths; with Xcode it runs plain `swift test`. Always run tests through the script.
- **Ad-hoc signing:** the bundle is signed ad hoc, not with a Developer ID. macOS may ask again for privacy permissions (Accessibility, Automation) after each rebuild.

## License

MIT

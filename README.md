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

Each ad-hoc build has a new signature, so macOS asks again for Keychain access to the AI API key. To stop that, create a self-signed code-signing certificate once (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing) and build with `NOTEKIT_SIGN_IDENTITY="<certificate name>" scripts/bundle.sh`; then "Always Allow" survives rebuilds.

## Notes

- **Search index:** the app keeps a full-text index of your unlocked notes in `~/Library/Application Support/<bundle id>/index.sqlite`. It holds a plain-text copy of each note's title, folder and Markdown body, outside the Notes container, so any process running as you can read it. Locked notes are never indexed. It is a cache: delete the file and it is rebuilt. Syncing needs Full Disk Access; without it the app keeps running and logs why it cannot sync.
- **AI agents (MCP):** the app's own executable is an MCP server over stdio when started with `--mcp`. It is read-only by default: it opens only the search index, so the client needs no Full Disk Access. Turn on “AI agents (MCP)” in Settings > AI & Search first; while it is off, every tool call returns an error saying so. Results are as fresh as the app's last sync. Tools: `search_notes`, `get_note` and `list_backlinks`. `create_note` shows up only after you also turn on “Let AI agents write to Notes” and choose a target folder. It asks the running app, which writes through Notes itself (Automation permission), so the app has to be open. Notes uses the first line of the body as the note's title, so `title` is optional. The app asks you to approve each note unless you change it to once per session, always or never.
  - Claude Desktop, in `claude_desktop_config.json`:
    ```json
    { "mcpServers": { "notes": { "command": "/path/to/NoteKit.app/Contents/MacOS/NoteKit", "args": ["--mcp"] } } }
    ```
  - Claude Code: `claude mcp add notes -- /path/to/NoteKit.app/Contents/MacOS/NoteKit --mcp`
- **Tests with only the Command Line Tools:** they ship Swift Testing, but plain `swift test` cannot find `Testing.framework` and `lib_TestingInterop.dylib`. `scripts/test.sh` adds the missing search paths and rpaths; with Xcode it runs plain `swift test`. Always run tests through the script.
- **Ad-hoc signing:** the bundle is signed ad hoc, not with a Developer ID. macOS may ask again for privacy permissions (Accessibility, Automation) after each rebuild.

## License

MIT

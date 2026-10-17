# tabieum

A local-first companion for Apple Notes. Search, backlinks, Markdown shortcuts and templates are always on. A Vim mode, a semantic-search index and AI helpers are options you turn on. No account, no server.

tabieum is not affiliated with Apple. Apple Notes is a trademark of Apple Inc.

## What it does

- **Search:** a global shortcut (default ⌃⌥⌘N) opens a panel that searches the notes on this Mac, by keyword and, if you turn it on, by meaning.
- **Backlinks:** the notes that link to the one you have open.
- **Copy as Markdown / Copy Deeplink:** ⌃⌥⌘M and ⌃⌥⌘L, or the small button at the bottom of the editor.
- **Markdown shortcuts:** type Markdown while you write and the matching Notes style is applied. Each one can be turned off in Settings > Editor.
- **Templates and slash commands:** type `/` in a note to insert a template from a folder you choose, apply a style or run a command.
- **Vim mode (optional):** Normal, Insert, Visual and Visual Line modes, operators and motions with counts, text objects, `/` search, `.` repeat, macros and marks, undo and redo. The cursor is a block in Normal and Visual mode and a bar in Insert mode, or always a bar. Inside tables and other blocks it cannot read reliably, Vim keys are limited.
- **AI helpers (optional):** rewrite, summarize, ask about the note, and "Ask my notes" across your notes. You bring the server, the model and the key.
- **AI agents (optional):** tabieum can serve your notes to an agent such as Claude Desktop or Claude Code over MCP, read-only by default.

The app lives in the menu bar and has no Dock icon.

## Install

You need macOS 15 or later.

**Homebrew**

```sh
brew tap juhyeonni/tap
brew install --cask tabieum
```

**By hand:** download `tabieum-<version>.zip` from [Releases](https://github.com/juhyeonni/tabieum/releases), unzip it and move `tabieum.app` to Applications. Each release has a `.sha256` file to check the download.

### The first time you open it

tabieum is signed with its developer's own certificate, not by Apple, so macOS asks you to confirm the first launch. Do one of these:

- Open **System Settings > Privacy & Security**, scroll to the message about tabieum and choose **Open Anyway**.
- Or run `xattr -dr com.apple.quarantine /Applications/tabieum.app` once, then open the app.

The code is public and you can build it yourself (see below) instead of trusting a download.

### Permissions

tabieum asks for three permissions in System Settings > Privacy & Security. It shows what is missing and links to each page.

| Permission | What it is for |
|---|---|
| Accessibility | Reads the Notes window and cursor to add keyboard features inside Notes. |
| Full Disk Access | Reads the Notes database, read-only, for search. Nothing is ever written to it. |
| Automation (Notes) | Creates and edits notes through Notes itself. |

If you update with the same signing certificate, the permissions stay. If the certificate ever changes, you will be asked again once.

## Privacy and network

With the default settings tabieum makes no network request. It never checks for updates on its own.

| When | What goes out | Where to |
|---|---|---|
| You choose **Check for Updates…** in the menu | One request for the latest release | `api.github.com` |
| You turn on AI and use it | The text you selected or the note, plus what "Ask my notes" finds | The server you set in Settings > AI Assistant |
| You turn on semantic search | macOS downloads its on-device embedding model once. Your notes do not leave the Mac. | Apple, by macOS |
| You choose the tabieum-e5-small-coreml model for semantic search | The app downloads the model once (about 217 MB, checked against a SHA-256 pinned in the app). No note text is sent. | `huggingface.co` |

- **AI is off until you set it up.** A server that is not on this Mac must be allowed once before any note text is sent to it, and you can revoke that in Settings. The API key is kept in the macOS Keychain.
- **Search index:** tabieum keeps a full-text index of your unlocked notes in `~/Library/Application Support/dev.juhyeonni.tabieum/index.sqlite`. It holds a plain-text copy of each note's title, folder and Markdown body, outside the Notes container, so any process running as you can read it. Locked notes are never indexed. It is a cache: delete the file and it is rebuilt. Syncing needs Full Disk Access; without it the app keeps running and logs why it cannot sync.
- **Settings** are stored in `~/Library/Preferences/dev.juhyeonni.tabieum.plist`.
- Nothing is sent to the developer. There is no account and no crash reporting.

## AI agents (MCP)

The app's own executable is an MCP server over stdio when started with `--mcp`. It is read-only by default: it opens only the search index, so the client needs no Full Disk Access. Turn on "AI agents (MCP)" in Settings > Search & Agents first; while it is off, every tool call returns an error saying so. Results are as fresh as the app's last sync. Tools: `search_notes`, `get_note` and `list_backlinks`. `create_note` shows up only after you also turn on “Let AI agents write to Notes” and choose a target folder. It asks the running app, which writes through Notes itself (Automation permission), so the app has to be open. Notes uses the first line of the body as the note's title, so `title` is optional. The app asks you to approve each note unless you change it to once per session, always or never.

- Claude Desktop, in `claude_desktop_config.json`:
  ```json
  { "mcpServers": { "tabieum": { "command": "/Applications/tabieum.app/Contents/MacOS/tabieum", "args": ["--mcp"] } } }
  ```
- Claude Code: `claude mcp add tabieum -- /Applications/tabieum.app/Contents/MacOS/tabieum --mcp`

## Build from source

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

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

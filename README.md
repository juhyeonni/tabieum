# tabieum

Search and keyboard features beside Apple Notes, in a menu-bar app. It runs on your Mac, needs no account and has no server.

tabieum is a separate app that works next to Notes; it is not a plug-in for it. It is not affiliated with Apple. Apple Notes is a trademark of Apple Inc.

[Install](#install) · [Permissions](#permissions) · [Privacy and network](#privacy-and-network) · [AI agents](#ai-agents-mcp)

## What you get

- **Always on:** search by keyword with a global shortcut (default ⌃⌥⌘N), backlinks, copy as Markdown or as a deeplink, Markdown shortcuts, templates and `/` commands.
- **Options you turn on:** a Vim mode, search by meaning, and AI helpers.
- **For agents:** an MCP server, so Claude Desktop, Claude Code and other clients can search your notes.

The app lives in the menu bar and has no Dock icon. [docs/features.md](docs/features.md) describes every feature.

## Install

You need macOS 15 or later.

**Homebrew**

```sh
brew tap juhyeonni/tap
brew install --cask tabieum
```

**By hand:** download `tabieum-<version>.zip` from [Releases](https://github.com/juhyeonni/tabieum/releases), unzip it and move `tabieum.app` to Applications. Each release has a `.sha256` file to check the download.

### The first time you open it

tabieum is signed with its developer's own certificate. Apple has not notarized it, so macOS asks you to confirm the first launch. Do one of these:

- Open **System Settings > Privacy & Security**, scroll to the message about tabieum and choose **Open Anyway**. [Apple describes these steps](https://support.apple.com/en-us/102445).
- Or run `xattr -dr com.apple.quarantine /Applications/tabieum.app` once, then open the app. This is the developer's shortcut, not an Apple instruction.

The code is public and you can build it yourself (see [Build from source](#build-from-source)) instead of trusting a download.

## Permissions

tabieum asks for three permissions in System Settings > Privacy & Security. It shows what is missing and links to each page. None is needed to open the app; each one unlocks the features below.

| Permission | What tabieum uses it for | Without it |
|---|---|---|
| Accessibility | Reads the Notes window and cursor so keyboard features work inside Notes: Vim mode, Markdown shortcuts, the `/` menu and the button at the bottom of the editor. | Those features do not work. The search shortcut and MCP still do. |
| Full Disk Access | Reads the Notes database, read-only, to build the search index and to find the note you copy or link. Nothing is ever written to it. tabieum cannot grant this for you; you switch it on in System Settings. | The index cannot sync, so search and MCP find only what is already indexed. Copy as Markdown and backlinks cannot find the note. |
| Automation (Notes) | Asks Notes which note is open or selected, and reads the notes in your templates folder. | Backlinks, copy and the `/` template list cannot see the current note. |

If you update with the same signing certificate, the permissions stay. If the certificate ever changes, you will be asked again once. To take a permission back, switch it off in the same System Settings page, or run `tccutil reset All dev.juhyeonni.tabieum` to reset all of them.

## Privacy and network

With the default settings tabieum makes no network request. It never checks for updates on its own.

| When | What goes out | Where to |
|---|---|---|
| You choose **Check for Updates…** in the menu | One request for the latest release | `api.github.com` |
| You turn on AI and use it | The text you selected or the note, plus what "Ask my notes" finds | The server you set in Settings > AI Assistant |
| You turn on semantic search | macOS downloads its on-device embedding model once. Your notes do not leave the Mac. | Apple, by macOS |
| You choose the tabieum-e5-small-coreml model for semantic search | The app downloads the model once (about 234 MB, checked against SHA-256 values pinned in the app). No note text is sent. | `huggingface.co` |

Where your data lives:

- **Search index:** `~/Library/Application Support/dev.juhyeonni.tabieum/index.sqlite`. It holds a plain-text copy of each note's title, folder and Markdown body, outside the Notes container, so any process running as you can read it. Locked notes are never indexed. It is a cache: delete the file and it is rebuilt. Syncing needs Full Disk Access; without it the app keeps running and logs why it cannot sync.
- **Settings:** `~/Library/Preferences/dev.juhyeonni.tabieum.plist`.
- **API key:** the macOS Keychain, one item per AI server (service `dev.juhyeonni.tabieum`, account = the server's host).
- **Downloaded model:** under `~/Library/Application Support/dev.juhyeonni.tabieum/models/` (see [Optional download](#optional-download)).

Nothing is sent to the developer. There is no account and no crash reporting.

## Optional download

Searching by meaning has two models. The built-in one comes with macOS. The other is **tabieum-e5-small-coreml**, a Core ML conversion of multilingual-e5-small that runs on your Mac; the credit is in [NOTICE](NOTICE).

- **Off by default.** Turn on semantic search in Settings > Search & Agents, then choose the model under "Embedding model". The app asks before it downloads.
- **Size and source:** about 234 MB (a 217 MB model and a 17 MB tokenizer), from `huggingface.co/juhyeonni/tabieum-e5-small-coreml`. The files are pinned to one commit and checked against a SHA-256 before they are used.
- **No note text is sent.** Only the model is downloaded.
- **Remove it:** delete `~/Library/Application Support/dev.juhyeonni.tabieum/models/`. Choose the built-in model first if you want to keep semantic search working. The app downloads the model again if you choose it later.

The first search by meaning after a pause takes a couple of seconds while the model loads; the search panel shows the word matches first.

## AI helpers

AI helpers rewrite or summarize a note, answer questions about it, and answer "Ask my notes" across your notes. **They are off until you set them up** in Settings > AI Assistant. You bring the server, the model and the key. A server that is not on this Mac must be allowed once before any note text is sent to it, and you can revoke that in Settings. The key is kept in the macOS Keychain.

## AI agents (MCP)

The app's own executable is a read-only MCP server over stdio when started with `--mcp`. It opens only the search index, never Notes, so the client needs no Full Disk Access. Tools: `search_notes`, `get_note` and `list_backlinks`.

1. Open tabieum once so it can build the search index. Until then every tool call says there is no index yet.
2. Turn on **AI agents (MCP)** in Settings > Search & Agents. While it is off, every tool call returns an error saying so. Results are as fresh as the app's last sync.
3. Add the server to your client.
   - **Claude Desktop:** in the menu bar choose Claude > Settings > Developer > Edit Config. The file is `~/Library/Application Support/Claude/claude_desktop_config.json`. Add the server with an absolute path:
     ```json
     { "mcpServers": { "tabieum": { "command": "/Applications/tabieum.app/Contents/MacOS/tabieum", "args": ["--mcp"] } } }
     ```
     Quit Claude Desktop completely and open it again.
   - **Claude Code:** `claude mcp add tabieum -- /Applications/tabieum.app/Contents/MacOS/tabieum --mcp`. Check it with `claude mcp list`.
4. Check that it works: the client lists three tools, `search_notes`, `get_note` and `list_backlinks`. Ask it to search your notes.

If you moved the app out of Applications, use its real path. If Claude Desktop does not show the server, look at `~/Library/Logs/Claude/mcp-server-tabieum.log`.

Note text that the tools return to an agent can contain instructions written by someone else. Treat it as untrusted input. The tools only read; they do not change your notes.

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| Search finds nothing, or misses new notes | The index syncs only with Full Disk Access. Turn it on, then give the app a moment. To start over, delete `index.sqlite` (see [Privacy and network](#privacy-and-network)); it is rebuilt. |
| A permission shows as granted but a feature does nothing | The entry may belong to an earlier signature of the app, for example after a rebuild. Remove tabieum from the list in System Settings, add it again and restart the app. |
| The first search by meaning is slow | The model loads on first use and unloads after a pause. Word matches appear at once and the rest follows. |
| An MCP tool says the option is turned off | Switch on **AI agents (MCP)** in Settings > Search & Agents. |
| An MCP tool says there is no index | Open tabieum and let it sync your notes. |
| The server does not show up in Claude Desktop | Check that the path is absolute and the file is valid JSON, quit Claude Desktop completely and open it again, then read the log named above. |
| The search shortcut does nothing | Another app may use the same keys. Choose a different shortcut in Settings > General. |
| macOS asks again for the Keychain or the permissions | You are running a build that is signed ad hoc. See [docs/development.md](docs/development.md) to sign your own builds with one certificate. |

## Uninstall

1. Quit tabieum from its menu bar icon.
2. Remove the app: `brew uninstall --cask tabieum`, or move `tabieum.app` to the Trash.
3. Delete its data:
   - `~/Library/Application Support/dev.juhyeonni.tabieum/` (the search index and the downloaded model)
   - `~/Library/Preferences/dev.juhyeonni.tabieum.plist`
   - the Keychain items whose service is `dev.juhyeonni.tabieum` (open Keychain Access and search for it)
4. Take back the permissions: `tccutil reset All dev.juhyeonni.tabieum`.

## Build from source

You need macOS 15 and either Xcode or only the Command Line Tools (`xcode-select --install`).

```sh
swift build          # debug build
scripts/test.sh      # run the tests
scripts/bundle.sh    # build build/tabieum.app (release, ad-hoc signed)
```

Always run the tests through `scripts/test.sh`. [docs/development.md](docs/development.md) covers the Command Line Tools setup, signing so that permissions survive rebuilds, and releases.

## Contributing and support

Report bugs and ideas as [GitHub issues](https://github.com/juhyeonni/tabieum/issues). If you send a change, run `scripts/test.sh` first.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

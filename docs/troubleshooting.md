# Troubleshooting

What to do when something does not work, and how to remove Tabieum. The [README](../README.md) covers installing and permissions.

| Problem | Cause and fix |
|---|---|
| Search finds nothing, or misses new notes | The index syncs only with Full Disk Access. Turn it on, then give the app a moment. To start over, delete `~/Library/Application Support/dev.juhyeonni.tabieum/index.sqlite`; it is rebuilt. |
| A permission shows as granted but a feature does nothing | The entry may belong to an earlier signature of the app, for example after a rebuild. Remove Tabieum from the list in System Settings, add it again and restart the app. |
| The first search by meaning is slow | The model loads on first use and unloads after a pause. Word matches appear at once and the rest follows. |
| An MCP tool says the option is turned off | Switch on **AI agents (MCP)** in Settings > Search & Agents. |
| An MCP tool says there is no index | Open Tabieum and let it sync your notes. |
| The server does not show up in Claude Desktop | Check that the path is absolute and the file is valid JSON, quit Claude Desktop completely and open it again, then read `~/Library/Logs/Claude/mcp-server-tabieum.log`. |
| A write tool says Tabieum is not running | The app does the writing. Open Tabieum and try again. |
| A write tool says writing is off or no target folder is chosen | Turn on **Let AI agents write to Notes** in Settings > Search & Agents and choose a target folder. |
| `update_note` says the note changed | Read the note again with `get_note` and retry with its new `modified` value. |
| `update_note` or `delete_note` says no note can be changed | The note is outside the reach you set (the target folder by default), is locked, or does not exist. `update_note` also refuses notes with attachments. |
| The search shortcut does nothing | Another app may use the same keys. Choose a different shortcut in Settings > General. |
| macOS asks again for the Keychain or the permissions | You are running a build that is signed ad hoc. See [development.md](development.md) to sign your own builds with one certificate. |

## Uninstall

1. Quit Tabieum from its menu bar icon.
2. Remove the app: `brew uninstall --cask tabieum`, or move `Tabieum.app` to the Trash.
3. Delete its data:
   - `~/Library/Application Support/dev.juhyeonni.tabieum/` (the search index and the downloaded model)
   - `~/Library/Preferences/dev.juhyeonni.tabieum.plist`
   - the Keychain items whose service is `dev.juhyeonni.tabieum` (open Keychain Access and search for it)
4. Take back the permissions: `tccutil reset All dev.juhyeonni.tabieum`.

# Features

Everything tabieum does. The [README](../README.md) has the short version.

The app lives in the menu bar and has no Dock icon.

## Always on

- **Search:** a global shortcut (default ⌃⌥⌘N) opens a panel that searches the notes on this Mac by keyword. The panel lists the notes that have every word first, then those that have only some. Korean words are also matched by their shorter stems, so a word with an ending still finds its note.
- **Backlinks:** the notes that link to the one you have open.
- **Copy as Markdown / Copy Deeplink:** ⌃⌥⌘M and ⌃⌥⌘L, or the small button at the bottom of the editor.
- **Markdown shortcuts:** type Markdown while you write and the matching Notes style is applied. Each one can be turned off in Settings > Editor.
- **Templates and slash commands:** type `/` in a note to insert a template from a folder you choose, apply a style, run a command, or insert a table with `/table` (3 by 3) or `/table4x2` (columns by rows, up to 10 by 20).

## Options you turn on

- **Vim mode:** Normal, Insert, Visual and Visual Line modes, operators and motions with counts, text objects, `/` search, `.` repeat, macros and marks, undo and redo. The cursor is a block in Normal and Visual mode and a bar in Insert mode, or always a bar. Inside tables and other blocks it cannot read reliably, Vim keys are limited.
- **Search by meaning:** turn on semantic search in Settings > Search & Agents and the index also holds a vector for each part of a note. You can use macOS's built-in model or download the tabieum-e5-small-coreml model (see [Optional download](../README.md#optional-download)). A second switch there, "Also search by meaning in the search panel", adds the notes found only by meaning to the search panel. They are marked "Similar in meaning", come after the notes that match your words, and at most 20 are listed. A match by meaning is a hint and not a guarantee: the model gives no score that tells a real match from a weak one.
- **AI helpers:** rewrite, summarize, ask about the note, and "Ask my notes" across your notes. You bring the server, the model and the key.

## For agents

- **MCP server:** `tabieum --mcp` serves your notes over MCP. It is read-only by default; `create_note`, `update_note` and `delete_note` appear only after you turn on writing for agents. See [AI agents (MCP)](../README.md#ai-agents-mcp).

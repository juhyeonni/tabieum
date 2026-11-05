# Features

Everything tabieum does. The [README](../README.md) has the short version.

The app lives in the menu bar and has no Dock icon.

## Always on

- **Search:** a global shortcut (default ⌃⌥⌘N) opens a panel that searches the notes on this Mac by keyword. The panel lists the notes that have every word first, then those that have only some. Korean words are also matched by their shorter stems, so a word with an ending still finds its note. Two words work inside any query: `in:Work` (or `in:"Work Notes"`) keeps only notes in that folder, and `since:7d` keeps only notes modified in the last 7 days. They filter the first 200 hits, so a match ranked lower is missed. With text in the field, ⌘S asks for a name and saves the query. While the field is empty the panel lists the saved searches: Up and Down select, Return runs one, and ⌘⌫ deletes it.
- **Quick append:** a global shortcut (default ⌃⌥⌘A) opens a one-line input. Enter adds the line at the end of your Inbox note, which is created the first time; Esc closes it. The note's title is set in Settings > General (default "Inbox"). This is your own typing, so it does not depend on the agent writing settings. It needs the Automation permission for Notes.
- **URL scheme:** `tabieum://search?q=<text>` opens the search panel with the text filled in, `tabieum://open?id=<note id>` opens that note, and `tabieum://append?text=<text>` opens the input with the text filled in. Nothing is written until you press Enter, because any app or web page can open a URL. The text is cut at 2000 characters. Unknown or incomplete URLs do nothing.
- **Backlinks:** the notes that link to the one you have open.
- **Copy as Markdown / Copy Deeplink:** ⌃⌥⌘M and ⌃⌥⌘L, or the small button at the bottom of the editor.
- **Today's note:** ⌃⌥⌘D opens the note titled with today's date as `YYYY-MM-DD` (your time zone), or creates it in Notes' default folder the first time that day. If your templates folder has a note named "Daily" (case does not matter), the new note copies it with its first line replaced by the date. It needs the Automation permission for Notes, not Full Disk Access. Change the shortcut in Settings > General.
- **Markdown shortcuts:** type Markdown while you write and the matching Notes style is applied. Each one can be turned off in Settings > Editor.
- **Templates and slash commands:** type `/` in a note to insert a template from a folder you choose, apply a style, run a command, or insert a table with `/table` (3 by 3) or `/table4x2` (columns by rows, up to 10 by 20).

## Options you turn on

- **Vim mode:** Normal, Insert, Visual and Visual Line modes, operators and motions with counts, text objects, `/` search, `.` repeat, macros and marks, undo and redo. The cursor is a block in Normal and Visual mode and a bar in Insert mode, or always a bar. Inside tables and other blocks it cannot read reliably, Vim keys are limited.
- **Format toolbar:** turn it on in Settings > Editor and a small toolbar appears next to the text you select in Notes, with bold, italic, underline, strikethrough, title, bulleted list and checklist. A click applies the style through Notes' own Format menu, so undo works. It does not appear where the selection's position cannot be read, such as in tables.
- **Search by meaning:** turn on semantic search in Settings > Search & Agents and the index also holds a vector for each part of a note. You can use macOS's built-in model or download the tabieum-e5-small-coreml model (see [Optional download](../README.md#optional-download)). A second switch there, "Also search by meaning in the search panel", adds the notes found only by meaning to the search panel. They are marked "Similar in meaning", come after the notes that match your words, and at most 20 are listed. A match by meaning is a hint and not a guarantee: the model gives no score that tells a real match from a weak one.
- **AI helpers:** rewrite, summarize, ask about the note, and "Ask my notes" across your notes. You bring the server, the model and the key.

## For agents

- **Search from the command line:** `tabieum search <words> [--limit n] [--json]` prints matching notes as JSON (the `search_notes` fields) and exits; exit code 1 for a missing index, 2 for a usage error. See [Searching from the command line](../README.md#searching-from-the-command-line).
- **MCP server:** `tabieum --mcp` serves your notes over MCP. It is read-only by default; `create_note`, `update_note` and `delete_note` appear only after you turn on writing for agents. See [AI agents (MCP)](../README.md#ai-agents-mcp).

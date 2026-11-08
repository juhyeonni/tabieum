# Features

Everything Tabieum does. The [README](../README.md) has the short version.

The app lives in the menu bar and has no Dock icon.

## Always on

- **Search:** a global shortcut (default ⌃⌥⌘N) opens a panel that searches the notes on this Mac by keyword. The panel lists the notes that have every word first, then those that have only some. Korean words are also matched by their shorter stems, so a word with an ending still finds its note. Two words work inside any query: `in:Work` (or `in:"Work Notes"`) keeps only notes in that folder, and `since:7d` keeps only notes modified in the last 7 days. They filter the first 200 hits, so a match ranked lower is missed. With text in the field, ⌘S asks for a name and saves the query. While the field is empty the panel lists the saved searches: Up and Down select, Return runs one, and ⌘⌫ deletes it.
- **Quick append:** a global shortcut (default ⌃⌥⌘A) opens a one-line input. Enter adds the line at the end of your Inbox note, which is created the first time; Esc closes it. The note's title is set in Settings > General (default "Inbox"). This is your own typing, so it does not depend on the agent writing settings. It needs the Automation permission for Notes.
- **URL scheme:** `tabieum://search?q=<text>` opens the search panel with the text filled in, `tabieum://open?id=<note id>` opens that note, and `tabieum://append?text=<text>` opens the input with the text filled in. Nothing is written until you press Enter, because any app or web page can open a URL. The text is cut at 2000 characters. Unknown or incomplete URLs do nothing.
- **Backlinks:** the notes that link to the one you have open.
- **Copy as Markdown / Copy Deeplink:** ⌃⌥⌘M and ⌃⌥⌘L, or the small button at the bottom of the editor.
- **Today's note:** ⌃⌥⌘D opens the note titled with today's date as `YYYY-MM-DD` (your time zone), or creates it in Notes' default folder the first time that day. If your templates folder has a note named "Daily" (case does not matter), the new note copies it with its first line replaced by the date. It needs the Automation permission for Notes, not Full Disk Access. Change the shortcut in Settings > General.
- **Markdown shortcuts:** type Markdown while you write and the matching Notes style is applied. Each one can be turned off in Settings > Editor.
- **Templates and slash commands:** type `/` in a note to insert a template from a folder you choose, apply a style, run a command, or insert a table with `/table` (3 by 3) or `/table4x2` (columns by rows, up to 10 by 20). `/today`, `/tomorrow`, `/yesterday` and `/now` insert an ISO date (`2026-10-20`, or `2026-10-20 10:10` for `/now`); add four digits for a time, as in `/tomorrow0930`.

## Options you turn on

- **Vim mode:** Normal, Insert, Visual and Visual Line modes, operators and motions with counts, text objects, `/` search, `.` repeat, macros and marks, undo and redo. The cursor is a block in Normal and Visual mode and a bar in Insert mode, or always a bar. Inside tables and other blocks it cannot read reliably, Vim keys are limited.
- **Format toolbar:** turn it on in Settings > Editor and a small toolbar appears next to the text you select in Notes, with bold, italic, underline, strikethrough, title, bulleted list and checklist. A click applies the style through Notes' own Format menu, so undo works. It does not appear where the selection's position cannot be read, such as in tables.
- **Search by meaning:** turn on semantic search in Settings > Search & Agents and the index also holds a vector for each part of a note. You can use macOS's built-in model or download the tabieum-e5-small-coreml model (see [Model download](#model-download)). A second switch there, "Also search by meaning in the search panel", adds the notes found only by meaning to the search panel. They are marked "Similar in meaning", come after the notes that match your words, and at most 20 are listed. A match by meaning is a hint and not a guarantee: the model gives no score that tells a real match from a weak one.
- **AI helpers:** rewrite, summarize, ask about the note, and "Ask my notes" across your notes (see [AI helpers](#ai-helpers)).

### Model download

Searching by meaning has two models. The built-in one comes with macOS. The other is **tabieum-e5-small-coreml**, a Core ML conversion of multilingual-e5-small that runs on your Mac; the credit is in [NOTICE](../NOTICE).

- **Off by default.** Turn on semantic search in Settings > Search & Agents, then choose the model under "Embedding model". The app asks before it downloads.
- **Size and source:** about 234 MB (a 217 MB model and a 17 MB tokenizer), from `huggingface.co/juhyeonni/tabieum-e5-small-coreml`. The files are pinned to one commit and checked against a SHA-256 before they are used.
- **No note text is sent.** Only the model is downloaded.
- **Remove it:** delete `~/Library/Application Support/dev.juhyeonni.tabieum/models/`. Choose the built-in model first if you want to keep semantic search working. The app downloads the model again if you choose it later.

The model is made for the Neural Engine of Apple silicon. On an Intel Mac the option is hidden and the built-in model is used.

### AI helpers

They are off until you set them up in Settings > AI Assistant. You bring the server, the model and the key; under **API format** choose OpenAI-compatible (Ollama, LM Studio and similar) or Anthropic. A server that is not on this Mac must be allowed once before any note text is sent to it, and you can revoke that in Settings. The key is kept in the macOS Keychain.

## For agents

`Tabieum --mcp` serves your notes over MCP. It is read-only by default, with the tools `search_notes`, `get_note`, `list_backlinks`, `list_recent_notes` and `list_folders`. The [README](../README.md#ai-agents-mcp) shows how to connect a client.

### Letting agents write to Notes

Off by default. Agents can only do what you allow here.

- **Turn it on:** Settings > Search & Agents > **Let AI agents write to Notes**, then choose a **target folder**. Agents cannot pick another folder or create one. Creating notes is allowed to begin with.
- **`create_note`** takes a Markdown `body` and an optional `title`. Notes uses the first line of a note as its title, so start the body with a heading, or pass `title` to have one put in front. It returns the new note's `id`, `title`, `folder` and `modified`, so an agent can edit or delete the note right away. Markdown task items (`- [ ] a`, `- [x] a`) are written as `☐ a` and `☑ a` text lines: Notes' tickable checklists cannot be created from outside the app.
- **`update_note`** replaces the whole body of an existing note, so a checklist made in Notes becomes plain text. It needs the note's `id` and the `modified` value from `get_note`, and it is refused if the note changed since, or has attachments. You switch it on with **Allow edit**.
- **`delete_note`** moves a note to Recently Deleted, where you can restore it. There is no permanent delete. You switch it on with **Allow delete**.
- **Which notes:** **Edit and delete reach** decides which existing notes an agent can change: only the target folder (the default), any note, or only notes created by agents. Locked notes are never touched.
- **Your say:** the app asks you before each write and shows a preview. Under **Consent** you can change that to once per session, always, or never. An option marks notes as created by an AI agent.
- **How it writes:** the running app writes through Notes (Automation permission), so Tabieum must be open. Your client may also ask before it calls a tool; that is separate from Tabieum's own question.

### Searching from the command line

`Tabieum search <words> [--limit n] [--json]` prints the matching notes as JSON and exits, with no app window. It runs word search over the same index, read-only, and does not need the app to be running or Full Disk Access. Results are as fresh as the app's last sync. `--limit` defaults to 10 and is clamped to 1 through 50. `--json` is accepted and changes nothing: JSON is the only format.

```
$ /Applications/Tabieum.app/Contents/MacOS/Tabieum search budget --json
{"results":[{"folder":"Work","id":"...","modified":"2026-11-06T09:00:00Z","snippet":"...","title":"Budget"}]}
```

Each result has the same fields as the MCP `search_notes` tool. Errors are `{"error":"..."}` on standard output.

| Exit code | Meaning |
|---|---|
| 0 | Success, also with no matches (`{"results":[]}`) |
| 1 | The search index is missing or unreadable |
| 2 | Usage error, such as no words |

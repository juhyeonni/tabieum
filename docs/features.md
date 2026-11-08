# Features

Everything tabieum does. The [README](../README.md) has the short version.

The app lives in the menu bar and has no Dock icon.

## Always on

- **Search:** a global shortcut (default ⌃⌥⌘N) opens a panel that searches the notes on this Mac by keyword. The panel lists the notes that have every word first, then those that have only some. Korean words are also matched by their shorter stems, so a word with an ending still finds its note.
- **Backlinks:** the notes that link to the one you have open.
- **Copy as Markdown / Copy Deeplink:** ⌃⌥⌘M and ⌃⌥⌘L, or the small button at the bottom of the editor.
- **Markdown shortcuts:** type Markdown while you write and the matching Notes style is applied. Each one can be turned off in Settings > Editor.
- **Templates and slash commands:** type `/` in a note to insert a template from a folder you choose, apply a style or run a command.

## Options you turn on

- **Vim mode:** Normal, Insert, Visual and Visual Line modes, operators and motions with counts, text objects, `/` search, `.` repeat, macros and marks, undo and redo. The cursor is a block in Normal and Visual mode and a bar in Insert mode, or always a bar. Inside tables and other blocks it cannot read reliably, Vim keys are limited.
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

`tabieum --mcp` serves your notes over MCP. It is read-only by default, with the tools `search_notes`, `get_note` and `list_backlinks`. The [README](../README.md#ai-agents-mcp) shows how to connect a client.

### Letting agents write to Notes

Off by default. Agents can only do what you allow here.

- **Turn it on:** Settings > Search & Agents > **Let AI agents write to Notes**, then choose a **target folder**. Agents cannot pick another folder or create one. Creating notes is allowed to begin with.
- **`create_note`** takes a Markdown `body` and an optional `title`. Notes uses the first line of a note as its title, so start the body with a heading, or pass `title` to have one put in front.
- **`update_note`** replaces the whole body of an existing note. It needs the note's `id` and the `modified` value from `get_note`, and it is refused if the note changed since, or has attachments. You switch it on with **Allow edit**.
- **`delete_note`** moves a note to Recently Deleted, where you can restore it. There is no permanent delete. You switch it on with **Allow delete**.
- **Which notes:** **Edit and delete reach** decides which existing notes an agent can change: only the target folder (the default), any note, or only notes created by agents. Locked notes are never touched.
- **Your say:** the app asks you before each write and shows a preview. Under **Consent** you can change that to once per session, always, or never. An option marks notes as created by an AI agent.
- **How it writes:** the running app writes through Notes (Automation permission), so tabieum must be open. Your client may also ask before it calls a tool; that is separate from tabieum's own question.

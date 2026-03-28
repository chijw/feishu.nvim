# feishu.nvim

Native Neovim frontend for Feishu resources, with `feishu-cli` as the primary backend.

## Goals

- Use `feishu-cli` for general Feishu resources whenever possible.
- Use `feishu-cli` as the primary backend for docs, chat, and bitable operations.
- Use real Neovim buffers and splits instead of an embedded pseudo-TUI.
- Make task and chat workflows usable with normal vim motions, search, macros, and editing.

## Current Features

- `:Feishu`, `<leader>vf`
  - opens a browser-style root buffer
  - root entries are `云文档` and `消息`
  - `云文档` shows a generic docs browser with top-level actions plus the current user's visible docs
  - `云文档` supports browse mode plus `s` search mode
  - opening a bitable delegates to the schema-driven bitable view
  - opening a `docx` / supported `wiki` doc exports it into a local Markdown cache buffer
  - editable `docx` buffers sync back to Feishu asynchronously on `:w`
- `:Feishu auth`, `:Feishu login`
  - `:Feishu login` opens a floating terminal and runs `feishu-cli auth login --manual`
  - by default it relies on `feishu-cli`'s own recommended scope set; override `auth.login_scopes` only when you need a custom list
  - extra auth-login flags can be passed through, for example `:Feishu login --port 14530`
- `:Feishu tasks`, `:Feishu bitable`
  - opens the generic bitable buffer
  - derives primary field / visible columns / editable fields from schema
  - uses a self-link field as a tree automatically when present
  - adaptive columns with `h/l`
  - table cycling with `Shift-Tab`
  - record create/edit/delete/open-link
  - editable form buffer with `i` / `<CR>` field editing
  - option-like fields such as single-select, multi-select, user, checkbox, and link fields open a picker instead of requiring manual text entry
  - `Ctrl-S` save and `Ctrl-C` cancel
- `:Feishu chats`
  - chat list view
  - history preview via `Enter`
  - compose buffer via `i`
  - send via `Ctrl-S`
  - local filter via `s`, clear via `S`

## Install In This Workspace

The local config already wires it through `lazy.nvim`:

- plugin dir: `~/workspace/dev/feishu.nvim`
- lazy spec: `~/.config/nvim/lua/plugins/feishu.lua`

## Notes

- The plugin intentionally shells out to CLIs instead of duplicating HTTP logic in Lua.
- General browsing, chat, and bitable operations now use external `feishu-cli`.
- Bitable URLs can be opened either from direct `/base/...` links or from wiki nodes that resolve to bitable resources.
- Chat listing and history require real `im:*` user scopes on the `feishu-cli` token.
- Search and chat commands rely on `feishu-cli`'s own user-token resolution path, so token refresh stays in the CLI instead of the plugin.
- Optional-user commands still fall back to `~/.feishu-cli/token.json` when the installed `feishu-cli` binary does not yet expose `auth token`.
- Cloud-doc search needs the external `feishu-cli` token to include `search:docs:read`. Without it, browse mode still works but search mode will surface the permission error.
- Wiki-space browsing is best with `wiki:space:retrieve` or `wiki:wiki:readonly`. If they are missing, the docs page now degrades to recent-doc/manual-open mode instead of failing the whole buffer.
- Drive-root browsing needs user scopes such as `drive:drive:readonly` or `space:document:retrieve`. If they are missing, the browser should surface the permission error instead of showing a fake empty drive.

## Resource Support

Strong support:

- `bitable`
  - open into the schema-driven bitable view
  - supports generic read/write/delete for editable field types
- `sheet`
  - opens into a local read-only worksheet preview buffer
  - supports worksheet switching plus horizontal column scrolling
- `slides` / `mindnote` / generic `file`
  - open into a local metadata buffer instead of forcing an immediate browser jump
  - keep `gx` as the escape hatch to the full remote UI
- `chat`
  - list chats, preview history, compose/send text messages
  - multi-line message bodies are normalized into real buffer lines in the preview split
- `wiki` nodes that resolve to `bitable`
  - open into the same generic bitable view

Usable with fallback:

- `docx` / `doc`
  - browser can export/open as a local Markdown cache buffer
  - `docx` supports local editing and async sync-back on save
  - if export fails, fall back to the remote URL
- `wiki` doc nodes
  - browser can export/open as a local Markdown cache buffer
  - wiki nodes that resolve to `docx` support local editing and async sync-back on save
  - wiki containers remain navigable as containers
- `sheet`
  - browser can detect the type
  - browser can open a read-only local preview of the first visible rows/columns

Weak or not yet first-class:

- `slides`
- `mindnote`
- generic uploaded `file`
- binary attachments

Fallback behavior:

- If a resource has a stable Feishu URL but no native buffer implementation yet, the plugin opens that URL externally.
- If a resource can be exported as Markdown, the plugin prefers a local cache buffer before falling back to the browser.
- If a container returns no visible entries from the API, the buffer stays navigable and simply shows `(empty)`.
- If a resource type is unsupported for structured editing, keep the task/doc citation in Feishu and edit the body through the official web UI for now.

# pi.nvim

Neovim UI plugin for [pi coding agent](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent), with a sidebar, chat window, input bar, and right-side changes/diff panel.

## Features

- Session sidebar with pin/delete/rename/switch
- Chat view with live tool-call streaming
- Tool navigation mode (`gt`, then `j/k`) with actions:
  - `o` open file from tool call
  - `d` open diff for edit/write tool calls
- Persistent right-side changes panel and diff viewer
- Multi-line input bar with `@` file completion
- Local command palette (`?` in chat, `<C-p>` in input)

## Requirements

- Neovim `>= 0.9`
- `pi` on `PATH`
  - Install: `npm install -g @mariozechner/pi-coding-agent`
- pi authentication configured (`/login` in pi, or provider API key env vars)

## Setup From Scratch

1. Install pi:

```bash
npm install -g @mariozechner/pi-coding-agent
```

2. Authenticate once:

```bash
pi
```

Then use `/login` (or set provider API keys) and quit.

3. Add plugin in `lazy.nvim`:

```lua
{
  "erkamkavak/pi.nvim",
  cmd = {
    "PiStart",
    "PiStop",
    "PiSessions",
    "PiChanges",
    "PiPrompt",
    "PiStatus",
    "PiChat",
    "PiNewSession",
  },
  keys = {
    { "<leader>ps", function() require("pi").toggle_sessions() end, desc = "pi: toggle sessions" },
    { "<leader>pc", function() require("pi").toggle_changes() end, desc = "pi: toggle changes" },
  },
  opts = {},
}
```

4. Reload plugins, then run:

```vim
:PiSessions
```

## Commands

| Command | Description |
|---|---|
| `:PiStart` | Start pi RPC process |
| `:PiStop` | Stop pi RPC process |
| `:PiSessions` | Toggle sidebar + chat UI |
| `:PiChat` | Focus/open chat window |
| `:PiChanges` | Toggle right changes panel |
| `:PiPrompt <msg>` | Send prompt |
| `:PiStatus` | Show runtime/model/session status |
| `:PiNewSession` | Start a new pi session |

## Default Keymaps

Global:
- `toggle_sessions`: `<leader>ps`
- `chat_command_palette`: `?`
- `chat_command_palette_insert`: `<C-p>`

Sidebar:
- `<CR>` select/switch session
- `P` pin/unpin
- `d` delete session
- `r` rename session
- `q` close pi UI

Chat:
- `i` focus input
- `gt` toggle tool navigation
- `j` next tool call
- `k` previous tool call
- `o` open tool file
- `d` open tool diff in right panel
- `q` close pi UI

## Configuration

```lua
require("pi").setup({
  pi_cmd = "pi",
  sidebar_width = 35,
  changes_width = 50,
  changes_open_by_default = false,
  auto_start = false,
  pinned_file = nil, -- default: stdpath("data") .. "/pi/pinned_sessions.json"
  session_dir = nil, -- default: ~/.pi/agent/sessions/<encoded-cwd>
  chat_max_messages = 150,
  chat_max_chars_per_message = 4000,
  ui_margin_cols = 2,
  ui_margin_rows = 1,
  keymaps = {
    toggle_sessions = "<leader>ps",
    chat_command_palette = "?",
    chat_command_palette_insert = "<C-p>",
    sidebar_select = "<CR>",
    sidebar_toggle_pin = "P",
    sidebar_delete = "d",
    sidebar_rename = "r",
    changes_toggle = "<C-c>",
    chat_tool_nav_toggle = "gt",
    chat_tool_next = "j",
    chat_tool_prev = "k",
    chat_tool_open_file = "o",
    chat_tool_open_diff = "d",
    prompt_send = "<C-j>",
    prompt_abort = "<C-d>",
  },
})
```

## Session Scope

By default, `pi.nvim` reads sessions for the current working directory only:

- `~/.pi/agent/sessions/<encoded-cwd>`

This keeps loading fast and avoids cross-project session noise. Use `session_dir` to override.

## License

MIT

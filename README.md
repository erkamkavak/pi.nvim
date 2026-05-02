# pi.nvim

Neovim plugin for the [pi coding agent](https://github.com/badlogic/pi-mono). Provides a LazyGit-like interface with split panels for session management and change tracking.

## Features

- **Session sidebar** (left) — browse all sessions across all projects, with pinned sessions at the top
- **Changes panel** (right, toggleable) — shows the last conversation turn and files changed
- **Pinned sessions** — pin important sessions to the top of the sidebar (persisted to disk)
- **Session switching** — select a session from the sidebar to switch via pi's RPC protocol
- **Live streaming** — agent responses stream into Neovim buffers in real-time

## Requirements

- Neovim >= 0.9
- [pi](https://github.com/badlogic/pi-mono) installed and available on PATH
- An API key configured (e.g., `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`)

## Installation

### lazy.nvim

```lua
{
    "badlogic/pi-mono/packages/pi-nvim", -- or symlink/copy the directory
    opts = {
        -- See Configuration below
    },
}
```

### packer.nvim

```lua
use {
    "badlogic/pi-mono/packages/pi-nvim",
    config = function()
        require("pi").setup({
            -- your config here
        })
    end,
}
```

## Usage

```lua
require("pi").setup()
```

### Commands

| Command | Description |
|---------|-------------|
| `:PiStart` | Start the pi RPC process |
| `:PiStop` | Stop the pi RPC process |
| `:PiSessions` | Toggle the session sidebar |
| `:PiChanges` | Toggle the last-turn changes panel |
| `:PiPrompt <msg>` | Send a prompt to pi |
| `:PiStatus` | Show pi status (model, session, message count) |
| `:PiNewSession` | Create a new session |

### Keybindings (Sidebar)

| Key | Action |
|-----|--------|
| `<CR>` | Switch to selected session |
| `P` | Toggle pin/unpin session |
| `d` | Delete session |
| `r` | Rename session |
| `<Up>` / `<Down>` | Navigate sessions |

### Keybindings (Global)

Configurable via `keymaps` in setup.

- `toggle_sessions` default: `<leader>ps`
- `chat_command_palette` default: `?` (in pi chat)
- `chat_command_palette_insert` default: `<C-p>` (in pi input)

### Keybindings (Chat Tool Navigation)

| Key | Action |
|-----|--------|
| `gt` | Toggle tool navigation mode |
| `j` | Next tool call (when tool navigation is enabled) |
| `k` | Previous tool call (when tool navigation is enabled) |
| `o` | Open selected tool call file |
| `d` | Open selected tool call diff (edit/write) |

### Slash Commands (Input)

Type `/` in chat input to see command suggestions. Currently handled in the Neovim UI:

- `/model`
- `/new`
- `/resume`
- `/session`
- `/name <value>`
- `/compact [instructions]`
- `/copy`
- `/export [path]`
- `/fork`
- `/quit`
- `/hotkeys`

Unsupported built-in commands are consumed locally and shown as "not implemented yet"
instead of being sent to the assistant.

### Command Palette

Use a LazyGit-style command palette from chat:

- `?` in chat window
- `<C-p>` in chat input

This opens a floating command list with single-key shortcuts (`n`, `r`, `m`, etc.).

## Configuration

```lua
require("pi").setup({
    -- Path to the pi executable
    pi_cmd = "pi",

    -- Width of the sidebar in columns
    sidebar_width = 35,

    -- Width of the changes panel in columns
    changes_width = 50,

    -- Whether the changes panel is open by default
    changes_open_by_default = false,

    -- Auto-start pi on Neovim startup
    auto_start = false,

    -- Optional session directory override
    -- Default: ~/.pi/agent/sessions/<encoded-cwd>
    session_dir = nil,

    -- Chat rendering caps for performance on very large sessions
    chat_max_messages = 150,
    chat_max_chars_per_message = 4000,

    -- Outer margins around the full Pi UI (gives a modal/windowed feel)
    ui_margin_cols = 2,
    ui_margin_rows = 1,

    -- Keybinding overrides
    keymaps = {
        toggle_sessions = "<leader>ps",
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
        chat_command_palette = "?",
        chat_command_palette_insert = "<C-p>",
    },
})
```

## Architecture

```
┌─────────────────┬──────────────────────────┬─────────────────────┐
│  Session Sidebar│  Editor (your code)      │  Changes Panel      │
│                 │                          │  (toggleable)       │
│ 📌 Pinned       │                          │                     │
│ > Fix auth  2m  │  function auth() {...}   │  🔄 Last Turn       │
│   Refactor  1h  │                          │                     │
│                 │                          │  > You: Fix auth    │
│ ── Sessions ──  │                          │                     │
│   New feat  3d  │                          │  Assistant:         │
│   Quick fix 5m  │                          │  I'll look at...    │
│                 │                          │                     │
│                 │                          │  ── Files Changed── │
│                 │                          │  ✎ src/auth.ts      │
└─────────────────┴──────────────────────────┴─────────────────────┘
```

### How it works

1. **pi.nvim spawns `pi --mode rpc`** as a background process using `vim.fn.jobstart()`
2. **Communication** happens via JSON lines on stdin/stdout — the RPC protocol
3. **Session listing** reads session files directly from `~/.pi/agent/sessions/`
4. **Pinned sessions** are stored in `~/.local/share/nvim/pi/pinned_sessions.json`
5. **Changes panel** fetches messages via the `get_messages` RPC command and parses tool calls to detect file modifications

## API

```lua
local pi = require("pi")

-- Start/stop
pi.start()
pi.stop()

-- Toggle panels
pi.toggle_sessions()
pi.toggle_changes()

-- Send prompts
pi.prompt("Fix the auth bug in src/auth.ts")

-- Get status
pi.status()

-- Direct client access
local client = require("pi.client")
client.send({ type = "get_state" }, function(response)
    print(vim.inspect(response))
end)
```

## License

MIT

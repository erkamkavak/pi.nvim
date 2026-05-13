--- @class PiConfig
--- @field pi_cmd string Path to pi command
--- @field sidebar_width number Width of the sidebar in columns
--- @field changes_width number Width of the changes panel in columns
--- @field changes_zoom_step number Columns to add/remove when zooming changes panel
--- @field changes_width_min number Minimum changes panel width
--- @field changes_width_max number Maximum changes panel width
--- @field changes_open_by_default boolean Whether changes panel is open on startup
--- @field diff_highlight table Optional syntax highlighting for change diffs
--- @field auto_start boolean Whether to auto-start pi RPC on startup
--- @field background_idle_timeout_ms number Time before stopping inactive idle session clients
--- @field background_max_idle_clients number Maximum inactive idle clients to keep warm
--- @field client_status_update_interval_ms number Minimum interval between sidebar status refreshes
--- @field keymaps table<string, string> Keybinding overrides
--- @field highlight_groups table<string, string> Highlight group overrides

local M = {}

M.defaults = {
	pi_cmd = "pi",
	sidebar_width = 35,
	changes_width = 50,
	changes_zoom_step = 5,
		changes_width_min = 30,
		changes_width_max = 120,
		changes_open_by_default = false,
		diff_highlight = {
			enabled = true,
			install = "never", -- "never" | "prompt" | "auto"
		},
		auto_start = false,
	background_idle_timeout_ms = 30000,
	background_max_idle_clients = 1,
	client_status_update_interval_ms = 500,
	pinned_file = nil, -- nil = use default location
	session_dir = nil, -- nil = use ~/.pi/agent/sessions/<encoded-cwd>
	chat_max_messages = 150,
	chat_max_chars_per_message = 4000,
	input_height = 1,
	rpc_timeout_ms = 30000,
	ui_margin_cols = 2,
	ui_margin_rows = 1,
	keymaps = {
		-- Global keymaps
		toggle_sessions = "<leader>ps",
		chat_command_palette = "?",
		chat_command_palette_insert = "<C-p>",
		-- Sidebar keymaps
		sidebar_select = "<CR>",
		sidebar_toggle_pin = "P",
		sidebar_delete = "d",
		sidebar_rename = "r",
		-- Changes panel keymaps
		changes_toggle = "<C-c>",
		changes_zoom_in = "=",
		changes_zoom_out = "-",
		changes_zoom_reset = "0",
		changes_diff_popup = "z",
		-- Chat tool navigation/action keymaps
		chat_tool_nav_toggle = "gt",
		chat_tool_next = "j",
		chat_tool_prev = "k",
		chat_tool_open_file = "o",
		chat_tool_open_diff = "d",
		-- General
		prompt_send = "<CR>",
		prompt_follow_up = "<M-CR>",
		prompt_exit_input = "<C-j>",
		prompt_abort = "<C-d>",
	},
	highlight_groups = {
		PiSidebarHeader = "Title",
		PiSidebarPinned = "WarningMsg",
		PiSidebarRunning = "DiagnosticOk",
		PiSidebarIdle = "DiagnosticHint",
		PiSidebarSession = "Normal",
		PiSidebarSelected = "Visual",
		PiSidebarTime = "Comment",
		PiSidebarCount = "Comment",
		PiChangesHeader = "Title",
		PiChangesTool = "Function",
		PiChangesFile = "String",
		PiChangesPrompt = "Normal",
		PiChangesResponse = "Normal",
		PiPromptLine = "CursorLine",
		PiSeparator = "NonText",
		PiHlKeyword = "Statement",
		PiHlIdentifier = "Identifier",
		PiHlType = "Type",
		PiHlVariable = "Identifier",
		PiHlComment = "Comment",
		PiHlPunctuation = "Delimiter",
			PiHlString = "String",
			PiHlNumber = "Number",
			PiUserHeader = "DiagnosticInfo",
			PiAssistantHeader = "DiagnosticOk",
			PiToolCall = "Function",
			PiToolCallSelected = "Visual",
			PiToolResult = "Comment",
		},
	}

--- @type PiConfig
M.options = {}

--- @param opts? table
function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", M.defaults, opts)
end

return M

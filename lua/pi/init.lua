--- pi.nvim - Neovim plugin for the pi coding agent
---
--- Provides a LazyGit-like interface with:
--- - Left sidebar: session list with pinned sessions
--- - Right panel: last turn changes (toggleable)
--- - Bottom: prompt input
---
--- Usage:
---   require("pi").setup({ ... })
---   :PiStart        - Start the pi RPC process
---   :PiStop         - Stop the pi RPC process
---   :PiSessions     - Toggle session sidebar
---   :PiChanges      - Toggle last turn changes panel
---   :PiPrompt <msg> - Send a prompt to pi
---   :PiStatus       - Show pi status
---   :PiThinkingLevel - Select reasoning/thinking level

local config = require("pi.config")
local client = require("pi.client")
local sidebar = require("pi.sidebar")
local changes = require("pi.changes")
local chat = require("pi.chat")

local M = {}

--- @param opts? PiConfig
function M.setup(opts)
	config.setup(opts)

	-- Set up highlight groups
	M._setup_highlights()

	-- Create commands
	M._create_commands()

	-- Optional: auto-start
	if config.options.auto_start then
		M.start()
	end
end

--- Start pi
--- @param cwd? string
function M.start(cwd)
	local ok = client.start({ cwd = cwd })
	if ok then
		vim.notify("pi: started", vim.log.levels.INFO)
	else
		vim.notify("pi: failed to start", vim.log.levels.ERROR)
	end
end

--- Stop pi
function M.stop()
	client.stop()
	vim.notify("pi: stopped", vim.log.levels.INFO)
end

--- Toggle session sidebar (also toggles chat)
--- @param cwd? string
function M.toggle_sessions(cwd)
	if not client.is_running() then
		M.start(cwd)
	end
	if sidebar.is_open and sidebar.is_open() then
		sidebar.close()
		chat.close()
	else
		sidebar.open(cwd)
		chat.open()
	end
end

--- Toggle changes panel
function M.toggle_changes()
	if not client.is_running() then
		M.start()
	end
	changes.toggle()
end

--- Send a prompt to pi
--- @param message? string
function M.prompt(message)
	if not message or message == "" then
		-- Open input prompt
		vim.ui.input({ prompt = "pi> " }, function(input)
			if input and input ~= "" then
				client.prompt(input)
				-- Ensure chat is visible
				if not chat.is_open() then
					chat.open()
				end
			end
		end)
		return
	end

	client.prompt(message)
	if not chat.is_open() then
		chat.open()
	end
end

--- Show pi status
function M.status()
	if client.is_running() then
		client.get_state(function(response)
			vim.schedule(function()
				if response and response.success then
					local state = response.data
					local msg = string.format(
						"pi: running | model: %s/%s | thinking: %s | session: %s | messages: %d",
						state.model and state.model.provider or "?",
						state.model and state.model.id or "?",
						state.thinkingLevel or "off",
						state.sessionName or state.sessionId or "?",
						state.messageCount
					)
					vim.notify(msg, vim.log.levels.INFO)
				else
					vim.notify("pi: running (failed to get state)", vim.log.levels.INFO)
				end
			end)
		end)
	else
		vim.notify("pi: not running", vim.log.levels.WARN)
	end
end

--- Show/select thinking level
function M.thinking_level()
	if not client.is_running() then
		vim.notify("pi: not running", vim.log.levels.WARN)
		return
	end
	client.get_state(function(state_resp)
		vim.schedule(function()
			if not state_resp or not state_resp.success or not state_resp.data then
				vim.notify("pi: failed to get state", vim.log.levels.ERROR)
				return
			end
			local state = state_resp.data
			local model = state.model
			local levels = { "off", "minimal", "low", "medium", "high", "xhigh" }
			local level_labels = {
				off = "No reasoning",
				minimal = "Very brief reasoning (~1k tokens)",
				low = "Light reasoning (~2k tokens)",
				medium = "Moderate reasoning (~8k tokens)",
				high = "Deep reasoning (~16k tokens)",
				xhigh = "Maximum reasoning (~32k tokens)",
			}

			if not model or not model.reasoning then
				vim.notify("pi: current model does not support reasoning", vim.log.levels.WARN)
				return
			end

			local current = state.thinkingLevel or "off"
			vim.ui.select(levels, {
				prompt = "Select thinking level (current: " .. current .. ")",
				format_item = function(item)
					return item .. "  " .. (level_labels[item] or "")
				end,
			}, function(choice)
				if not choice then return end
				client.set_thinking_level(choice, function(response)
					vim.schedule(function()
						if response and response.success then
							vim.notify("pi: thinking level set to " .. choice, vim.log.levels.INFO)
							vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
						else
							vim.notify("pi: " .. (response and response.error or "failed to set thinking level"), vim.log.levels.ERROR)
						end
					end)
				end)
			end)
		end)
	end)
end

--- Set up highlight groups
function M._setup_highlights()
	local groups = config.options.highlight_groups
	local defaults = {
		PiSidebarHeader = "Title",
		PiSidebarPinned = "WarningMsg",
		PiSidebarSession = "Normal",
		PiSidebarSelected = "Visual",
		PiSidebarTime = "Comment",
		PiSidebarCount = "Comment",
		PiChangesHeader = "Title",
		PiChangesTool = "Function",
		PiChangesFile = "String",
		PiChangesPrompt = "Normal",
		PiChangesResponse = "Normal",
		PiSeparator = "NonText",
		PiUserHeader = "DiagnosticInfo",
		PiAssistantHeader = "DiagnosticOk",
		PiToolCall = "Function",
		PiToolCallSelected = "Visual",
		PiToolResult = "Comment",
		-- Markdown highlights
		PiMdHeading = "Title",
		PiMdBold = "Bold",
		PiMdItalic = "Italic",
		PiMdStrikethrough = "Strikethrough",
		PiMdUnderline = "Underlined",
		PiMdCode = "String",
		PiMdLink = "Underlined",
		PiMdLinkUrl = "Comment",
		PiMdCodeBlock = "Special",
		PiMdCodeBlockBorder = "NonText",
		PiMdQuote = "Italic",
		PiMdQuoteBorder = "NonText",
		PiMdHr = "NonText",
		PiMdListBullet = "Identifier",
	}

	for name, link in pairs(vim.tbl_extend("force", defaults, groups)) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

--- Create user commands
function M._create_commands()
	vim.api.nvim_create_user_command("PiStart", function()
		M.start()
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiStop", function()
		M.stop()
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiSessions", function()
		M.toggle_sessions()
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiChanges", function()
		M.toggle_changes()
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiPrompt", function(args)
		M.prompt(args.args)
	end, { nargs = "*" })

	vim.api.nvim_create_user_command("PiStatus", function()
		M.status()
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiCleanupIdle", function()
		client.cleanup_idle(true)
		vim.notify("pi: cleaned up idle background clients", vim.log.levels.INFO)
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiChat", function()
		if not client.is_running() then
			M.start()
		end
		chat.open()
		chat.focus()
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiNewSession", function()
		if client.is_running() then
			client.new_session(function()
				vim.schedule(function()
					vim.notify("pi: new session created", vim.log.levels.INFO)
					vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
				end)
			end)
		end
	end, { nargs = 0 })

	vim.api.nvim_create_user_command("PiThinkingLevel", function()
		M.thinking_level()
	end, { nargs = 0 })

	local toggle_sessions_lhs = config.options.keymaps and config.options.keymaps.toggle_sessions
	if type(toggle_sessions_lhs) == "string" and toggle_sessions_lhs ~= "" then
		vim.keymap.set("n", toggle_sessions_lhs, function()
			M.toggle_sessions()
		end, { noremap = true, silent = true, desc = "pi: toggle sessions" })
	end
end

-- Public API
M.config = config
M.client = client
M.sidebar = sidebar
M.changes = changes
M.chat = chat

return M

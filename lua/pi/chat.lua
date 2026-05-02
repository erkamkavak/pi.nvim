--- Chat Panel - shows the pi conversation in the center with a bottom input bar

local config = require("pi.config")
local client = require("pi.client")
local changes = require("pi.changes")

local M = {}

local chat_buf = nil
local chat_win = nil
local input_buf = nil
local input_win = nil
local hint_buf = nil
local hint_win = nil
local is_open = false
local last_messages = {}
local current_model = ""
local calc_dimensions

-- Streaming state
local streaming_pre_tool_text = ""
local streaming_post_tool_text = ""
local streaming_saw_tool_activity = false
local streaming_tools_by_id = {}
local streaming_tool_order = {}
local is_streaming = false
local last_stream_render = 0
local handlers_registered = false
local chat_ns = vim.api.nvim_create_namespace("pi_chat")
local chat_sel_ns = vim.api.nvim_create_namespace("pi_chat_sel")
local refresh_inflight = false
local refresh_pending = false

-- Tool navigation state
local tool_nav_mode = false
local rendered_tool_entries = {}
local selected_tool_idx = nil
local selected_tool_id = nil
local last_non_pi_win = nil
local palette_buf = nil
local palette_win = nil
local palette_ns = vim.api.nvim_create_namespace("pi_chat_palette")
local palette_items = {}
local palette_selected_idx = 1
local focus_lock_pause_count = 0
local last_pi_focus_win = nil
local focus_lock_group = vim.api.nvim_create_augroup("PiFocusLock", { clear = true })
local focus_lock_autocmd_registered = false

local COMMAND_PALETTE_ITEMS = {
	{ key = "n", command = "/new", description = "Start a new session" },
	{ key = "r", command = "/resume", description = "Resume another session" },
	{ key = "m", command = "/model", description = "Select model" },
	{ key = "s", command = "/session", description = "Show session info" },
	{ key = "N", command = "/name", description = "Set session display name", prompt = "Session name" },
	{ key = "c", command = "/compact", description = "Compact session context" },
	{ key = "f", command = "/fork", description = "Fork from previous message" },
	{ key = "t", command = "/tree", description = "Open tree navigation" },
	{ key = "e", command = "/export", description = "Export session", prompt = "Export path (optional)" },
	{ key = "i", command = "/import", description = "Import session", prompt = "Import JSONL path" },
	{ key = "p", command = "/copy", description = "Copy last assistant message" },
	{ key = "g", command = "/changelog", description = "Show changelog" },
	{ key = "l", command = "/login", description = "Login OAuth provider" },
	{ key = "o", command = "/logout", description = "Logout OAuth provider" },
	{ key = "h", command = "/hotkeys", description = "Show hotkeys" },
	{ key = "q", command = "/quit", description = "Quit pi backend" },
}

local function reset_streaming_state()
	streaming_pre_tool_text = ""
	streaming_post_tool_text = ""
	streaming_saw_tool_activity = false
	streaming_tools_by_id = {}
	streaming_tool_order = {}
	last_stream_render = 0
end

local function is_pi_buffer(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
	local name = vim.api.nvim_buf_get_name(buf) or ""
	if name:sub(1, 5) == "pi://" then return true end
	local ft = vim.api.nvim_buf_get_option(buf, "filetype") or ""
	if ft:sub(1, 3) == "pi-" then return true end
	return false
end

local function is_pi_window(win)
	if not win or not vim.api.nvim_win_is_valid(win) then return false end
	local buf = vim.api.nvim_win_get_buf(win)
	return is_pi_buffer(buf)
end

local function list_pi_windows()
	local wins = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_pi_window(win) then
			table.insert(wins, win)
		end
	end
	table.sort(wins, function(a, b) return a < b end)
	return wins
end

local function get_ui_margins()
	local mx = tonumber(config.options.ui_margin_cols) or 0
	local my = tonumber(config.options.ui_margin_rows) or 0
	return math.max(0, math.floor(mx)), math.max(0, math.floor(my))
end

local function get_chat_content_width()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		local ok, width = pcall(vim.api.nvim_win_get_width, chat_win)
		if ok and width and width > 6 then
			return math.max(width - 2, 20) -- 2 columns left padding in rendered text
		end
	end
	local dim = calc_dimensions()
	return math.max(dim.width - 2, 20)
end

local function sanitize_line_text(text)
	if type(text) ~= "string" then
		text = text == nil and "" or tostring(text)
	end
	-- nvim_buf_set_lines rejects NUL/newline in individual line values.
	local sanitized = text
		:gsub("\x1b%[[%d;]*m", "")
		:gsub("[%z\1-\8\11\12\14-\31\127]", " ")
		:gsub("\r", "")
		:gsub("\n", " ")
	return sanitized
end

local function chat_footer_text()
	return " [i] input  [q] close  [?] commands  [gt] tool-nav  [j/k] tool select  [o] open  [d] diff "
end

local function calc_hint_row(input_row)
	local hint_row = (input_row or 0) + 1
	local max_row = math.max(0, vim.o.lines - 2)
	if hint_row > max_row then
		hint_row = max_row
	end
	return hint_row
end

local function looks_like_garbled_text(text)
	if type(text) ~= "string" or text == "" then return false end

	local repl_count = select(2, text:gsub("�", ""))
	local char_count = math.max(vim.fn.strchars(text), 1)
	if repl_count >= 64 and (repl_count / char_count) >= 0.12 then
		return true
	end

	local triplet_count = select(2, text:gsub("<%x%x><%x%x><%x%x>", ""))
	if triplet_count >= 12 then
		local approx_bytes = triplet_count * 12
		if (approx_bytes / math.max(#text, 1)) >= 0.25 then
			return true
		end
	end

	return false
end

local function normalize_render_text(text)
	if type(text) ~= "string" then return text end
	if looks_like_garbled_text(text) then
		return "[binary or invalid UTF-8 content omitted]"
	end
	return text
end

local function clip_text_length(text)
	if type(text) ~= "string" then return text end
	local max_chars = config.options.chat_max_chars_per_message or 4000
	if max_chars <= 0 then return text end
	if vim.fn.strchars(text) <= max_chars then return text end
	local clipped = vim.fn.strcharpart(text, 0, max_chars)
	return clipped .. "\n...[truncated]"
end

local function extract_command_from_partial_json(partial_json)
	if not partial_json or partial_json == "" then return nil end
	local ok, parsed = pcall(vim.fn.json_decode, partial_json)
	if ok and type(parsed) == "table" and type(parsed.command) == "string" then
		return parsed.command
	end

	local start_idx = partial_json:find([["command"%s*:%s*"]])
	if not start_idx then return nil end
	local value = partial_json:sub(start_idx):match([["command"%s*:%s*"([^"]*)$]])
	if not value then return nil end
	value = value:gsub('\\"', '"'):gsub("\\n", "\n"):gsub("\\\\", "\\")
	return value
end

local function extract_tool_result_text(result)
	if not result then return nil end
	local content = result.content
	if type(content) ~= "table" then return nil end
	local parts = {}
	for _, block in ipairs(content) do
		if block.type == "text" and block.text then
			table.insert(parts, block.text)
		end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, "\n")
end

local function upsert_streaming_tool_call(id, name, input)
	if not id or id == "" then
		id = "tool_" .. tostring(#streaming_tool_order + 1)
	end

	local tc = streaming_tools_by_id[id]
	if not tc then
		tc = {
			id = id,
			name = name or "?",
			input = {},
			partial_json = "",
			command = "",
			file = "",
			result = nil,
			running = false,
			is_partial_result = false,
			is_error = false,
		}
		streaming_tools_by_id[id] = tc
		table.insert(streaming_tool_order, id)
	end

	if name and name ~= "" then
		tc.name = name
	end

	if type(input) == "table" then
		tc.input = input
		tc.file = input.file_path or input.path or input.file or tc.file
		local cmd = input.command
		if type(cmd) == "string" and cmd ~= "" then
			tc.command = cmd
		end
	end

	return tc
end

local function resolve_tool_file_path(entry)
	if not entry then return nil end
	local file = nil
	if type(entry.input) == "table" then
		file = entry.input.file_path
			or entry.input.path
			or entry.input.file
			or entry.input.filename
			or entry.input.filePath
			or entry.input.filepath
	end
	if (not file or file == "") and type(entry.result_text) == "string" then
		file = entry.result_text:match("Successfully wrote %d+ bytes to%s+([^\n\r]+)")
	end
	if not file or file == "" then return nil end
	return vim.fn.fnamemodify(file, ":p")
end

local function is_diff_capable_tool(name)
	local n = type(name) == "string" and name:lower() or ""
	return n == "write" or n == "write_file" or n == "edit"
end

local function resolve_git_base_for_path(path)
	local abs = vim.fn.fnamemodify(path, ":p")
	local dir = vim.fn.fnamemodify(abs, ":h")
	if not dir or dir == "" then return nil end
	local cmd = string.format("git -C %s rev-parse --show-toplevel 2>/dev/null", vim.fn.shellescape(dir))
	local out = vim.fn.systemlist(cmd)
	if vim.v.shell_error == 0 and out and out[1] and out[1] ~= "" then
		return out[1]
	end
	return nil
end

local function get_git_diff_for_file(path)
	if not path or path == "" then
		vim.notify("pi: no file path for this tool call", vim.log.levels.WARN)
		return nil
	end
	local abs = vim.fn.fnamemodify(path, ":p")
	local git_base = resolve_git_base_for_path(abs)
	local lines = nil

	if git_base and git_base ~= "" then
		local cmd_repo = string.format(
			"git -C %s --no-pager diff -- %s",
			vim.fn.shellescape(git_base),
			vim.fn.shellescape(abs)
		)
		lines = vim.fn.systemlist(cmd_repo)
		if vim.v.shell_error ~= 0 then
			lines = nil
		end
	end

	if not lines then
		local cmd = string.format(
			"git -C %s --no-pager diff -- %s",
			vim.fn.shellescape(vim.fn.getcwd()),
			vim.fn.shellescape(abs)
		)
		lines = vim.fn.systemlist(cmd)
		if vim.v.shell_error ~= 0 then
			lines = nil
		end
	end

	if lines and #lines > 0 then
		return table.concat(lines, "\n")
	end

	-- Fallback for untracked/standalone files.
	if vim.fn.filereadable(abs) == 1 then
		local cmd_untracked = string.format(
			"git --no-pager diff --no-index -- /dev/null %s",
			vim.fn.shellescape(abs)
		)
		local added = vim.fn.systemlist(cmd_untracked)
		if added and #added > 0 then
			return table.concat(added, "\n")
		end
	end

	vim.notify("pi: no unstaged diff for " .. abs, vim.log.levels.INFO)
	return nil
end

local function close_pi_ui()
	M.close()
	local ok_sidebar, sidebar = pcall(require, "pi.sidebar")
	if ok_sidebar and sidebar and sidebar.close then
		sidebar.close()
	end
	local ok_changes, changes_mod = pcall(require, "pi.changes")
	if ok_changes and changes_mod and changes_mod.close then
		changes_mod.close()
	end
end

local function feedkeys(keys, mode)
	local term = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(term, mode or "in", true)
end

local focus_editor_window_for_file

local function with_focus_lock_suspended(fn)
	focus_lock_pause_count = focus_lock_pause_count + 1
	local ok, res = pcall(fn)
	focus_lock_pause_count = math.max(0, focus_lock_pause_count - 1)
	if not ok then
		error(res)
	end
	return res
end

local function preferred_pi_focus_window()
	if palette_win and vim.api.nvim_win_is_valid(palette_win) then
		return palette_win
	end
	if last_pi_focus_win and vim.api.nvim_win_is_valid(last_pi_focus_win) and is_pi_window(last_pi_focus_win) then
		return last_pi_focus_win
	end
	if input_win and vim.api.nvim_win_is_valid(input_win) then
		return input_win
	end
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		return chat_win
	end
	local wins = list_pi_windows()
	return wins[1]
end

local function ensure_focus_lock_autocmd()
	if focus_lock_autocmd_registered then return end
	focus_lock_autocmd_registered = true
	vim.api.nvim_create_autocmd("WinEnter", {
		group = focus_lock_group,
		callback = function()
			if focus_lock_pause_count > 0 then return end
			local pi_wins = list_pi_windows()
			if #pi_wins == 0 then return end

			local cur = vim.api.nvim_get_current_win()
			if is_pi_window(cur) then
				last_pi_focus_win = cur
				return
			end

			local target = preferred_pi_focus_window()
			if target and vim.api.nvim_win_is_valid(target) and target ~= cur then
				vim.schedule(function()
					if vim.api.nvim_win_is_valid(target) then
						vim.api.nvim_set_current_win(target)
					end
				end)
			end
		end,
	})
end

local function cycle_pi_window(delta)
	local pi_wins = list_pi_windows()
	if #pi_wins == 0 then return end
	local cur = vim.api.nvim_get_current_win()
	local idx = 1
	for i, win in ipairs(pi_wins) do
		if win == cur then
			idx = i
			break
		end
	end
	local next_idx = idx + (delta or 1)
	if next_idx < 1 then next_idx = #pi_wins end
	if next_idx > #pi_wins then next_idx = 1 end
	local target = pi_wins[next_idx]
	if target and vim.api.nvim_win_is_valid(target) then
		vim.api.nvim_set_current_win(target)
		last_pi_focus_win = target
	end
end

local function map_window_stay_keys(buf)
	local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
	local next_fn = function() cycle_pi_window(1) end
	local prev_fn = function() cycle_pi_window(-1) end
	local first_fn = function()
		local pi_wins = list_pi_windows()
		if #pi_wins == 0 then return end
		vim.api.nvim_set_current_win(pi_wins[1])
		last_pi_focus_win = pi_wins[1]
	end
	local last_fn = function()
		local pi_wins = list_pi_windows()
		if #pi_wins == 0 then return end
		vim.api.nvim_set_current_win(pi_wins[#pi_wins])
		last_pi_focus_win = pi_wins[#pi_wins]
	end
	vim.keymap.set("n", "<C-w>w", next_fn, opts)
	vim.keymap.set("n", "<C-w><C-w>", next_fn, opts)
	vim.keymap.set("n", "<C-w>W", prev_fn, opts)
	vim.keymap.set("n", "<C-w>h", prev_fn, opts)
	vim.keymap.set("n", "<C-w>j", next_fn, opts)
	vim.keymap.set("n", "<C-w>k", prev_fn, opts)
	vim.keymap.set("n", "<C-w>l", next_fn, opts)
	vim.keymap.set("n", "<C-w><Left>", prev_fn, opts)
	vim.keymap.set("n", "<C-w><Right>", next_fn, opts)
	vim.keymap.set("n", "<C-w><Up>", prev_fn, opts)
	vim.keymap.set("n", "<C-w><Down>", next_fn, opts)
	vim.keymap.set("n", "<C-w>p", prev_fn, opts)
	vim.keymap.set("n", "<C-w>t", first_fn, opts)
	vim.keymap.set("n", "<C-w>b", last_fn, opts)
end

local function with_main_window_focus(fn)
	local win = focus_editor_window_for_file()
	if win and vim.api.nvim_win_is_valid(win) then
		with_focus_lock_suspended(function()
			vim.api.nvim_win_call(win, fn)
		end)
	else
		with_focus_lock_suspended(fn)
	end
end

local function open_model_selector()
	client.get_available_models(function(response)
		vim.schedule(function()
			if not response or not response.success or not response.data then
				local err = response and response.error or "failed to load models"
				vim.notify("pi: " .. err, vim.log.levels.ERROR)
				return
			end

			local models = response.data.models or {}
			if #models == 0 then
				vim.notify("pi: no available models", vim.log.levels.WARN)
				return
			end

			local items = {}
			for _, model in ipairs(models) do
				table.insert(items, {
					provider = model.provider or "?",
					id = model.id or "?",
					name = model.name or model.id or "?",
				})
			end

			with_main_window_focus(function()
				vim.ui.select(items, {
					prompt = "Select model",
					format_item = function(item)
						local suffix = (item.name and item.name ~= item.id) and ("  " .. item.name) or ""
						return item.provider .. "/" .. item.id .. suffix
					end,
				}, function(choice)
					if not choice then return end
					client.set_model(choice.provider, choice.id, function(set_response)
						vim.schedule(function()
							if set_response and set_response.success then
								vim.notify("pi: model set to " .. choice.provider .. "/" .. choice.id, vim.log.levels.INFO)
								M.refresh()
							else
								local err = set_response and set_response.error or "failed to set model"
								vim.notify("pi: " .. err, vim.log.levels.ERROR)
							end
						end)
					end)
				end)
			end)
		end)
	end)
end

local function open_fork_selector()
	client.get_fork_messages(function(response)
		vim.schedule(function()
			if not response or not response.success or not response.data then
				local err = response and response.error or "failed to load fork points"
				vim.notify("pi: " .. err, vim.log.levels.ERROR)
				return
			end
			local messages = response.data.messages or {}
			if #messages == 0 then
				vim.notify("pi: no user messages available for forking", vim.log.levels.INFO)
				return
			end
			with_main_window_focus(function()
				vim.ui.select(messages, {
					prompt = "Fork from user message",
					format_item = function(item)
						local text = type(item.text) == "string" and item.text or ""
						text = text:gsub("%s+", " ")
						if vim.fn.strchars(text) > 90 then
							text = vim.fn.strcharpart(text, 0, 87) .. "..."
						end
						return text
					end,
				}, function(choice)
					if not choice or not choice.entryId then return end
					client.fork(choice.entryId, function(fork_response)
						vim.schedule(function()
							if fork_response and fork_response.success and fork_response.data and not fork_response.data.cancelled then
								vim.notify("pi: forked session", vim.log.levels.INFO)
								vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
							elseif fork_response and fork_response.success and fork_response.data and fork_response.data.cancelled then
								vim.notify("pi: fork cancelled", vim.log.levels.INFO)
							else
								local err = fork_response and fork_response.error or "failed to fork session"
								vim.notify("pi: " .. err, vim.log.levels.ERROR)
							end
						end)
					end)
				end)
			end)
		end)
	end)
end

local function copy_last_assistant_to_clipboard()
	client.get_last_assistant_text(function(response)
		vim.schedule(function()
			if not response or not response.success or not response.data then
				local err = response and response.error or "failed to get last assistant message"
				vim.notify("pi: " .. err, vim.log.levels.ERROR)
				return
			end
			local text = response.data.text
			if not text or text == "" then
				vim.notify("pi: no assistant message to copy", vim.log.levels.INFO)
				return
			end
			vim.fn.setreg('"', text)
			pcall(vim.fn.setreg, "+", text)
			vim.notify("pi: copied last assistant message", vim.log.levels.INFO)
		end)
	end)
end

local function execute_local_slash_command(message)
	if type(message) ~= "string" or message:sub(1, 1) ~= "/" then
		return false
	end
	local cmd, args = message:match("^/(%S+)%s*(.*)$")
	if not cmd then return false end
	cmd = cmd:lower()
	args = args or ""

	if cmd == "new" then
		if not client.is_running() then
			vim.notify("pi: not running. Use :PiStart first", vim.log.levels.ERROR)
			return true
		end
		client.new_session(function(response)
			vim.schedule(function()
				if response and response.success then
					vim.notify("pi: new session created", vim.log.levels.INFO)
					vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
				else
					local err = response and response.error or "unknown error"
					vim.notify("pi: failed to create session: " .. err, vim.log.levels.ERROR)
				end
			end)
		end)
		return true
	end

	if cmd == "model" then
		open_model_selector()
		return true
	end

	if cmd == "compact" then
		client.compact(args ~= "" and args or nil, function(response)
			vim.schedule(function()
				if response and response.success then
					vim.notify("pi: compaction complete", vim.log.levels.INFO)
					M.refresh()
				else
					local err = response and response.error or "compaction failed"
					vim.notify("pi: " .. err, vim.log.levels.ERROR)
				end
			end)
		end)
		return true
	end

	if cmd == "copy" then
		copy_last_assistant_to_clipboard()
		return true
	end

	if cmd == "export" then
		client.export_html(args ~= "" and args or nil, function(response)
			vim.schedule(function()
				if response and response.success and response.data and response.data.path then
					vim.notify("pi: exported to " .. response.data.path, vim.log.levels.INFO)
				else
					local err = response and response.error or "export failed"
					vim.notify("pi: " .. err, vim.log.levels.ERROR)
				end
			end)
		end)
		return true
	end

	if cmd == "fork" then
		open_fork_selector()
		return true
	end

	if cmd == "resume" then
		local sidebar = require("pi.sidebar")
		if sidebar.is_open and not sidebar.is_open() then
			sidebar.open(vim.fn.getcwd())
		end
		sidebar.focus()
		return true
	end

	if cmd == "session" then
		if not client.is_running() then
			vim.notify("pi: not running", vim.log.levels.WARN)
			return true
		end
		client.get_session_stats(function(stats_response)
			vim.schedule(function()
				client.get_state(function(response)
					vim.schedule(function()
						if response and response.success and response.data then
							local st = response.data
							local model = st.model and (st.model.provider .. "/" .. st.model.id) or "?"
							local session_name = st.sessionName or st.sessionId or "?"
							local tokens = "?"
							if stats_response and stats_response.success and stats_response.data then
								local t = stats_response.data.totalTokens
								if t then tokens = tostring(t) end
							end
							local msg = string.format(
								"pi: session=%s | model=%s | messages=%s | tokens=%s",
								session_name,
								model,
								tostring(st.messageCount or "?"),
								tokens
							)
							vim.notify(msg, vim.log.levels.INFO)
						else
							vim.notify("pi: failed to read session state", vim.log.levels.WARN)
						end
					end)
				end)
			end)
		end)
		return true
	end

	if cmd == "name" then
		if args == "" then
			vim.notify("pi: usage /name <session name>", vim.log.levels.WARN)
			return true
		end
		client.set_session_name(args)
		vim.notify("pi: session renamed", vim.log.levels.INFO)
		vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
		return true
	end

	if cmd == "hotkeys" then
		vim.notify("pi: local commands: /model /new /resume /name /session /compact /copy /export /fork /quit", vim.log.levels.INFO)
		return true
	end

	if cmd == "quit" then
		close_pi_ui()
		client.stop()
		vim.notify("pi: stopped", vim.log.levels.INFO)
		return true
	end

	if cmd == "settings" or cmd == "scoped-models" or cmd == "import" or cmd == "share"
		or cmd == "tree" or cmd == "login" or cmd == "logout"
		or cmd == "reload" or cmd == "changelog"
	then
		vim.notify("pi: /" .. cmd .. " UI is not implemented in pi-nvim yet", vim.log.levels.INFO)
		return true
	end

	-- In RPC mode, unknown built-in slash commands should not go to the LLM.
	vim.notify("pi: unknown or unsupported slash command: /" .. cmd, vim.log.levels.WARN)
	return true
end

local function run_slash_command(message)
	if type(message) ~= "string" or message == "" then return end
	if execute_local_slash_command(message) then return end
	if not client.is_running() then
		vim.notify("pi: not running. Use :PiStart first", vim.log.levels.ERROR)
		return
	end
	-- Keep parity with normal prompt flow (optimistic user line + streaming state).
	table.insert(last_messages, {
		role = "user",
		content = message,
		timestamp = vim.loop.now(),
	})
	is_streaming = true
	reset_streaming_state()
	if is_open and chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
		M._render()
	end
	client.prompt(message)
end

local function close_command_palette()
	if palette_win and vim.api.nvim_win_is_valid(palette_win) then
		vim.api.nvim_win_close(palette_win, true)
	end
	palette_win = nil
	palette_buf = nil
	palette_items = {}
	palette_selected_idx = 1
end

local function render_command_palette()
	if not palette_buf or not vim.api.nvim_buf_is_valid(palette_buf) then return end
	local lines = {
		"  pi commands",
		"  Enter: run  q/Esc: close  j/k: move",
		"",
	}
	for idx, item in ipairs(palette_items) do
		local marker = (idx == palette_selected_idx) and ">" or " "
		local cmd = item.command
		local key = "[" .. item.key .. "]"
		local desc = item.description or ""
		table.insert(lines, string.format(" %s %-3s %-12s %s", marker, key, cmd, desc))
	end

	vim.api.nvim_buf_set_option(palette_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(palette_buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(palette_buf, "modifiable", false)

	vim.api.nvim_buf_clear_namespace(palette_buf, palette_ns, 0, -1)
	vim.api.nvim_buf_add_highlight(palette_buf, palette_ns, "Title", 0, 2, -1)
	vim.api.nvim_buf_add_highlight(palette_buf, palette_ns, "Comment", 1, 2, -1)
	if palette_selected_idx and palette_items[palette_selected_idx] then
		local row = 3 + palette_selected_idx
		vim.api.nvim_buf_add_highlight(palette_buf, palette_ns, "Visual", row - 1, 0, -1)
	end
end

local function execute_palette_item(item)
	if not item then return end
	close_command_palette()

	local command = item.command
	if item.prompt then
		with_focus_lock_suspended(function()
			vim.ui.input({ prompt = item.prompt .. ": " }, function(value)
				if value == nil then return end
				local v = value:gsub("^%s+", ""):gsub("%s+$", "")
				if command == "/import" and v == "" then
					vim.notify("pi: import path is required", vim.log.levels.WARN)
					return
				end
				if v ~= "" then
					run_slash_command(command .. " " .. v)
				else
					run_slash_command(command)
				end
			end)
		end)
		return
	end

	run_slash_command(command)
end

local function move_palette_selection(delta)
	if #palette_items == 0 then return end
	palette_selected_idx = math.max(1, math.min(#palette_items, palette_selected_idx + delta))
	render_command_palette()
end

local function is_normal_editor_window(win)
	if not win or not vim.api.nvim_win_is_valid(win) then return false end
	local cfg = vim.api.nvim_win_get_config(win)
	return not cfg.relative or cfg.relative == ""
end

local EXCLUDED_EDITOR_FILETYPES = {
	["NvimTree"] = true,
	["neo-tree"] = true,
	["netrw"] = true,
	["oil"] = true,
	["pi-sidebar"] = true,
	["pi-chat"] = true,
	["pi-input"] = true,
	["pi-changes"] = true,
}

local EXCLUDED_EDITOR_BUFTYPES = {
	nofile = true,
	prompt = true,
	terminal = true,
	quickfix = true,
	help = true,
}

local function is_preferred_file_window(win)
	if not is_normal_editor_window(win) then return false end
	local buf = vim.api.nvim_win_get_buf(win)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
	local ft = vim.api.nvim_buf_get_option(buf, "filetype") or ""
	local bt = vim.api.nvim_buf_get_option(buf, "buftype") or ""
	if EXCLUDED_EDITOR_FILETYPES[ft] then return false end
	if EXCLUDED_EDITOR_BUFTYPES[bt] then return false end
	return true
end

focus_editor_window_for_file = function()
	local cur = vim.api.nvim_get_current_win()
	if is_preferred_file_window(cur) then
		return cur
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_preferred_file_window(win) then
			vim.api.nvim_set_current_win(win)
			return win
		end
	end
	-- Fallback: use any non-floating editor window (may be explorer/dashboard),
	-- so we don't force-open a new bottom split.
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_normal_editor_window(win) then
			vim.api.nvim_set_current_win(win)
			return win
		end
	end
	vim.cmd("botright split")
	return vim.api.nvim_get_current_win()
end

local function find_closest_tool_idx_to_cursor()
	if #rendered_tool_entries == 0 or not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
		return nil
	end
	local cursor_row = vim.api.nvim_win_get_cursor(chat_win)[1] - 1
	local best_idx = 1
	local best_dist = math.huge
	for idx, entry in ipairs(rendered_tool_entries) do
		local dist = math.abs((entry.line or 0) - cursor_row)
		if dist < best_dist then
			best_dist = dist
			best_idx = idx
		end
	end
	return best_idx
end

local function apply_tool_selection_visual()
	if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then return end
	vim.api.nvim_buf_clear_namespace(chat_buf, chat_sel_ns, 0, -1)
	if not tool_nav_mode then return end
	if not selected_tool_idx or not rendered_tool_entries[selected_tool_idx] then return end
	local row = rendered_tool_entries[selected_tool_idx].line
	vim.api.nvim_buf_add_highlight(chat_buf, chat_sel_ns, "PiToolCallSelected", row, 0, -1)
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		vim.api.nvim_win_set_cursor(chat_win, { row + 1, 0 })
	end
end

--- Calculate dimensions for chat window and input bar
calc_dimensions = function()
	local total_w = vim.o.columns
	local total_h = vim.o.lines
	local mx, my = get_ui_margins()
	local sidebar_w = config.options.sidebar_width

	local sidebar_mod = require("pi.sidebar")
	local sidebar_open = sidebar_mod.is_open()
	local changes_open = changes.is_open()
	local top_row = my
	local bottom_row = total_h - 1 - my -- keep cmdline row untouched
	local usable_h = math.max(8, bottom_row - top_row + 1)
	local left_col = mx
	local right_col = total_w - mx - 1

	if not sidebar_open then
		local width = right_col - left_col + 1
		if changes_open then
			local changes_left_col = right_col - config.options.changes_width + 1
			width = changes_left_col - left_col - 1
		end
		width = math.max(20, width)
		local chat_height = math.max(5, usable_h - 3)
		return {
			col = left_col,
			width = width,
			chat_height = chat_height,  -- leave room for input + border
			input_row = top_row + chat_height + 1,
			row = top_row,
		}
	end

	local chat_left = left_col + sidebar_w + 3
	if changes_open then
		local changes_left_col = right_col - config.options.changes_width + 1
		local w = changes_left_col - chat_left - 1
		if w < 10 then w = right_col - chat_left + 1 end
		local chat_height = math.max(5, usable_h - 3)
		return {
			col = chat_left,
			width = w,
			chat_height = chat_height,
			input_row = top_row + chat_height + 1,
			row = top_row,
		}
	else
		local w = right_col - chat_left + 1
		local chat_height = math.max(5, usable_h - 3)
		return {
			col = chat_left,
			width = w,
			chat_height = chat_height,
			input_row = top_row + chat_height + 1,
			row = top_row,
		}
	end
end

function M.open()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then return end
	ensure_focus_lock_autocmd()
	local cur_win = vim.api.nvim_get_current_win()
	if cur_win and vim.api.nvim_win_is_valid(cur_win) and not is_pi_window(cur_win) then
		last_non_pi_win = cur_win
	end

	local dim = calc_dimensions()

	-- Chat buffer (shorter to leave room for input)
	chat_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(chat_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(chat_buf, "filetype", "pi-chat")
	vim.api.nvim_buf_set_option(chat_buf, "wrap", true)
	vim.api.nvim_buf_set_name(chat_buf, "pi://chat")

	local chat_opts = {
		style = "minimal", relative = "editor",
		width = dim.width, height = dim.chat_height,
		row = dim.row or 0, col = dim.col,
		border = "single", title = " 🤖 pi ",
	}
	chat_win = vim.api.nvim_open_win(chat_buf, false, chat_opts)
	is_open = true

	-- Input buffer (1 row at bottom) - stays modifiable for typing
	input_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(input_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(input_buf, "filetype", "pi-input")
	vim.api.nvim_buf_set_option(input_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "> " })
	-- Keep modifiable so user can type!

	local input_opts = {
		style = "minimal", relative = "editor",
		width = dim.width, height = 1,
		row = dim.input_row, col = dim.col,
		border = "none",
	}
	input_win = vim.api.nvim_open_win(input_buf, false, input_opts)

	-- Non-focusable bottom hint bar under the input row (outside chat content).
	hint_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(hint_buf, "pi://hints")
	vim.api.nvim_buf_set_option(hint_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(hint_buf, "filetype", "pi-hints")
	vim.api.nvim_buf_set_option(hint_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(hint_buf, 0, -1, false, { chat_footer_text() })
	vim.api.nvim_buf_set_option(hint_buf, "modifiable", false)
	vim.api.nvim_buf_add_highlight(hint_buf, chat_ns, "Comment", 0, 0, -1)

	local hint_row = dim.input_row + 1
	hint_row = calc_hint_row(dim.input_row)
	hint_win = vim.api.nvim_open_win(hint_buf, false, {
		style = "minimal",
		relative = "editor",
		width = dim.width,
		height = 1,
		row = hint_row,
		col = dim.col,
		border = "none",
		focusable = false,
		noautocmd = true,
	})

	-- Keymaps for chat buffer
	local km = { buffer = chat_buf, noremap = true, silent = true }
	vim.keymap.set("n", "q", function()
		close_pi_ui()
	end, km)
	vim.keymap.set("n", "r", function() M.refresh() end, km)
	vim.keymap.set("n", "i", function() M.focus_input() end, km)
	vim.keymap.set("n", "<CR>", function() M.focus_input() end, km)
	vim.keymap.set("n", config.options.keymaps.chat_command_palette, function()
		M.open_command_palette()
	end, km)
	-- Navigate between pi windows with C-h / C-l
	vim.keymap.set("n", "<C-h>", function()
		require("pi.sidebar").focus()
	end, km)
	vim.keymap.set("n", "<C-l>", function()
		local changes_mod = require("pi.changes")
		if changes_mod.is_open() then changes_mod.focus() end
	end, km)
	vim.keymap.set("n", "<Left>", function()
		require("pi.sidebar").focus()
	end, km)
	vim.keymap.set("n", "<Right>", function()
		local changes_mod = require("pi.changes")
		if changes_mod.is_open() then changes_mod.focus() end
	end, km)
	-- Navigate down to input bar
	vim.keymap.set("n", "<C-j>", function()
		M.focus_input()
	end, km)
	vim.keymap.set("n", "<Down>", function()
		M.focus_input()
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_nav_toggle, function()
		M.toggle_tool_nav_mode()
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_next, function()
		if M.is_tool_nav_mode() then
			M.select_next_tool()
		else
			vim.cmd("normal! j")
		end
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_prev, function()
		if M.is_tool_nav_mode() then
			M.select_prev_tool()
		else
			vim.cmd("normal! k")
		end
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_open_file, function()
		M.open_selected_tool_file()
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_open_diff, function()
		M.open_selected_tool_diff()
	end, km)

	-- Keymaps for input buffer (insert mode navigation)
	local ikm = { buffer = input_buf, noremap = true, silent = true }
	local nkm = { buffer = input_buf, noremap = true, silent = true }
	local function leave_input_to_chat(clear_input)
		if clear_input then
			vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "> " })
		end
		vim.cmd("stopinsert")
		if chat_win and vim.api.nvim_win_is_valid(chat_win) then
			vim.api.nvim_set_current_win(chat_win)
		end
	end
	vim.keymap.set("i", "<CR>", function()
		-- Confirm completion first (avoid accidentally sending '/command' picks).
		if vim.fn.pumvisible() == 1 then
			feedkeys("<C-y>")
			return
		end
		M.submit_input()
	end, ikm)
	vim.keymap.set("i", config.options.keymaps.chat_command_palette_insert, function()
		vim.cmd("stopinsert")
		M.open_command_palette()
	end, ikm)
	vim.keymap.set("i", "<Esc>", function()
		leave_input_to_chat(true)
	end, ikm)
	vim.keymap.set("i", "<C-j>", function()
		leave_input_to_chat(false)
	end, ikm)
	vim.keymap.set("i", "<C-k>", function()
		leave_input_to_chat(false)
	end, ikm)
	vim.keymap.set("i", "<C-c>", function()
		leave_input_to_chat(false)
	end, ikm)
	-- Navigate out of input bar
	vim.keymap.set("i", "<C-h>", function()
		leave_input_to_chat(false)
		vim.schedule(function()
			require("pi.sidebar").focus()
		end)
	end, ikm)
	vim.keymap.set("i", "<C-l>", function()
		leave_input_to_chat(false)
		vim.schedule(function()
			local changes_mod = require("pi.changes")
			if changes_mod.is_open() then
				changes_mod.focus()
			end
		end)
	end, ikm)
	-- If input buffer ends up in normal mode, keep escape routes deterministic.
	vim.keymap.set("n", "<Esc>", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", "<C-j>", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", "<C-k>", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", "q", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", config.options.keymaps.chat_command_palette, function()
		M.open_command_palette()
	end, nkm)

	map_window_stay_keys(chat_buf)
	map_window_stay_keys(input_buf)

	-- Reset streaming state on open
	is_streaming = false
	reset_streaming_state()

	-- Initial render
	M.refresh()

	-- Register event handlers once (avoid duplicates on re-open)
	if not handlers_registered then
		handlers_registered = true

		-- Real-time streaming: message_update gives us the partial assistant message
		client.on_event("message_update", function(event)
			if not event or not event.message then return end
			if event.message.role ~= "assistant" then return end

			is_streaming = true

			-- Extract text and tool calls from partial assistant content blocks
			local text = ""
				if event.message.content and type(event.message.content) == "table" then
					for block_idx, block in ipairs(event.message.content) do
						if block.type == "text" and block.text then
							text = text .. block.text
					elseif block.type == "toolCall" then
						local args = block.arguments or {}
						if type(args) == "string" then
							local ok, parsed = pcall(vim.fn.json_decode, args)
							if ok then args = parsed end
						end
						local fallback_id = "content_" .. tostring(block_idx)
						upsert_streaming_tool_call(block.id or fallback_id, block.name, args)
						end
					end
				end
				if streaming_saw_tool_activity then
					streaming_post_tool_text = text
				else
					streaming_pre_tool_text = text
				end

			local assistant_event = event.assistantMessageEvent
			if assistant_event and assistant_event.type == "toolcall_delta" then
				local content_idx = (assistant_event.contentIndex or 0) + 1
				local block = event.message.content and event.message.content[content_idx] or nil
				local fallback_id = "content_" .. tostring(content_idx)
				local tool_id = (block and block.id) or fallback_id
				local tool_name = (block and block.name) or "bash"
				local tc = upsert_streaming_tool_call(tool_id, tool_name, (block and block.arguments) or {})
				tc.partial_json = (tc.partial_json or "") .. (assistant_event.delta or "")
				local partial_command = extract_command_from_partial_json(tc.partial_json)
				if partial_command and partial_command ~= "" then
					tc.command = partial_command
				end
			elseif assistant_event and assistant_event.type == "toolcall_end" and assistant_event.toolCall then
				upsert_streaming_tool_call(
					assistant_event.toolCall.id,
					assistant_event.toolCall.name,
					assistant_event.toolCall.arguments or {}
				)
			end

			local now = vim.loop.now()
			if now - last_stream_render > 60 then
				last_stream_render = now
				vim.schedule(function()
					if is_open then M._render() end
				end)
			end
		end)

		-- Stream complete: refresh to show final state with tool results
		client.on_event("agent_end", function()
			vim.schedule(function()
				is_streaming = false
				reset_streaming_state()
				M.refresh()
			end)
		end)

		client.on_event("tool_execution_start", function(event)
			if not event then return end
			is_streaming = true
			streaming_saw_tool_activity = true
			local tc = upsert_streaming_tool_call(event.toolCallId, event.toolName, event.args or {})
			tc.running = true
			tc.is_partial_result = false
			tc.is_error = false
			vim.schedule(function()
				if is_open then M._render() end
			end)
		end)

		client.on_event("tool_execution_update", function(event)
			if not event then return end
			is_streaming = true
			local tc = upsert_streaming_tool_call(event.toolCallId, event.toolName, event.args or {})
			tc.running = true
			tc.is_partial_result = true
			tc.is_error = false
			tc.result = extract_tool_result_text(event.partialResult)
			vim.schedule(function()
				if is_open then M._render() end
			end)
		end)

		client.on_event("tool_execution_end", function(event)
			if not event then return end
			local tc = upsert_streaming_tool_call(event.toolCallId, event.toolName, event.args or {})
			tc.running = false
			tc.is_partial_result = false
			tc.is_error = event.isError == true
			tc.result = extract_tool_result_text(event.result)
			vim.schedule(function()
				if is_open then M._render() end
			end)
		end)
	end
end

function M.relayout()
	if not is_open then return end
	local dim = calc_dimensions()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		vim.api.nvim_win_set_config(chat_win, {
			relative = "editor",
			row = dim.row or 0,
			col = dim.col,
			width = dim.width,
			height = dim.chat_height,
		})
	end
	if input_win and vim.api.nvim_win_is_valid(input_win) then
		vim.api.nvim_win_set_config(input_win, {
			relative = "editor",
			row = dim.input_row,
			col = dim.col,
			width = dim.width,
			height = 1,
		})
	end
	if hint_win and vim.api.nvim_win_is_valid(hint_win) then
		vim.api.nvim_win_set_config(hint_win, {
			relative = "editor",
			row = calc_hint_row(dim.input_row),
			col = dim.col,
			width = dim.width,
			height = 1,
		})
	end
	if is_open then
		M._render()
	end
end

--- Focus the input bar (starts insert mode)
function M.focus_input()
	if input_win and vim.api.nvim_win_is_valid(input_win) then
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("startinsert!")
	end
end

function M.open_command_palette()
	ensure_focus_lock_autocmd()
	if palette_win and vim.api.nvim_win_is_valid(palette_win) then
		close_command_palette()
		return
	end

	palette_items = vim.deepcopy(COMMAND_PALETTE_ITEMS)
	palette_selected_idx = 1

	local total_w = vim.o.columns
	local total_h = vim.o.lines
	local width = math.min(86, math.max(58, math.floor(total_w * 0.60)))
	local height = math.min(#palette_items + 4, math.max(12, math.floor(total_h * 0.70)))
	local row = math.floor((total_h - height) / 2)
	local col = math.floor((total_w - width) / 2)

	palette_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(palette_buf, "pi://commands")
	vim.api.nvim_buf_set_option(palette_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(palette_buf, "filetype", "pi-commands")
	vim.api.nvim_buf_set_option(palette_buf, "modifiable", false)

	palette_win = vim.api.nvim_open_win(palette_buf, true, {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		border = "rounded",
		title = " pi commands ",
	})

	local km = { buffer = palette_buf, noremap = true, silent = true, nowait = true }
	vim.keymap.set("n", "q", function() close_command_palette() end, km)
	vim.keymap.set("n", "<Esc>", function() close_command_palette() end, km)
	vim.keymap.set("n", "j", function() move_palette_selection(1) end, km)
	vim.keymap.set("n", "<Down>", function() move_palette_selection(1) end, km)
	vim.keymap.set("n", "k", function() move_palette_selection(-1) end, km)
	vim.keymap.set("n", "<Up>", function() move_palette_selection(-1) end, km)
	vim.keymap.set("n", "<CR>", function()
		execute_palette_item(palette_items[palette_selected_idx])
	end, km)

	for idx, item in ipairs(palette_items) do
		vim.keymap.set("n", item.key, function()
			palette_selected_idx = idx
			execute_palette_item(item)
		end, km)
	end

	map_window_stay_keys(palette_buf)
	render_command_palette()
end

--- Submit the current input line to pi
function M.submit_input()
	local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
	local msg = lines[1] or ""
	-- Strip "> " prefix if present
	msg = msg:gsub("^>%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")

	if msg == "" then return end

	-- Clear input (buffer stays modifiable)
	vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "> " })

	-- Handle local slash commands in the UI layer.
	if execute_local_slash_command(msg) then
		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.cmd("startinsert!")
		end
		return
	end

	-- Start streaming mode
	is_streaming = true
	reset_streaming_state()
	table.insert(last_messages, {
		role = "user",
		content = msg,
		timestamp = vim.loop.now(),
	})
	if is_open and chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
		M._render()
	end

	-- Send to pi
	client.prompt(msg)

	-- Stay in input for next message
	vim.cmd("startinsert!")
end

function M.close()
	close_command_palette()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		vim.api.nvim_win_close(chat_win, true)
		chat_win = nil
	end
	if input_win and vim.api.nvim_win_is_valid(input_win) then
		vim.api.nvim_win_close(input_win, true)
		input_win = nil
	end
	if hint_win and vim.api.nvim_win_is_valid(hint_win) then
		vim.api.nvim_win_close(hint_win, true)
		hint_win = nil
	end
	hint_buf = nil
	is_open = false
end

function M.is_open() return is_open end

function M.focus()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		vim.api.nvim_set_current_win(chat_win)
	end
end

function M.is_tool_nav_mode()
	return tool_nav_mode
end

function M.toggle_tool_nav_mode()
	tool_nav_mode = not tool_nav_mode
	if tool_nav_mode then
		local idx = find_closest_tool_idx_to_cursor()
		if idx then
			selected_tool_idx = idx
			selected_tool_id = rendered_tool_entries[idx].id
		else
			selected_tool_idx = nil
			selected_tool_id = nil
		end
		apply_tool_selection_visual()
	else
		if chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
			vim.api.nvim_buf_clear_namespace(chat_buf, chat_sel_ns, 0, -1)
		end
	end
	vim.notify("pi: tool navigation " .. (tool_nav_mode and "enabled" or "disabled"), vim.log.levels.INFO)
end

local function jump_to_tool_idx(idx)
	if not idx or not rendered_tool_entries[idx] then return end
	selected_tool_idx = idx
	selected_tool_id = rendered_tool_entries[idx].id
	apply_tool_selection_visual()
end

function M.select_next_tool()
	if #rendered_tool_entries == 0 then
		vim.notify("pi: no tool calls in view", vim.log.levels.INFO)
		return
	end
	local next_idx = selected_tool_idx and math.min(selected_tool_idx + 1, #rendered_tool_entries) or 1
	jump_to_tool_idx(next_idx)
end

function M.select_prev_tool()
	if #rendered_tool_entries == 0 then
		vim.notify("pi: no tool calls in view", vim.log.levels.INFO)
		return
	end
	local prev_idx = selected_tool_idx and math.max(selected_tool_idx - 1, 1) or 1
	jump_to_tool_idx(prev_idx)
end

local function get_selected_tool_entry()
	if selected_tool_idx and rendered_tool_entries[selected_tool_idx] then
		return rendered_tool_entries[selected_tool_idx]
	end
	if #rendered_tool_entries == 0 then
		return nil
	end
	return rendered_tool_entries[1]
end

function M.open_selected_tool_file()
	local entry = get_selected_tool_entry()
	if not entry then
		vim.notify("pi: no tool call selected", vim.log.levels.INFO)
		return
	end
	local abs_path = resolve_tool_file_path(entry)
	if not abs_path then
		vim.notify("pi: selected tool call has no file path", vim.log.levels.WARN)
		return
	end
	close_pi_ui()
	local escaped = vim.fn.fnameescape(abs_path)
	local target_win = last_non_pi_win
	if target_win and vim.api.nvim_win_is_valid(target_win) and not is_pi_window(target_win) then
		vim.api.nvim_set_current_win(target_win)
	end
	vim.cmd("edit " .. escaped)
end

function M.open_selected_tool_diff()
	local entry = get_selected_tool_entry()
	if not entry then
		vim.notify("pi: no tool call selected", vim.log.levels.INFO)
		return
	end

	if entry.details and type(entry.details.diff) == "string" and entry.details.diff ~= "" then
		changes.show_diff({
			title = (entry.name or "tool") .. " diff",
			text = entry.details.diff,
			source = resolve_tool_file_path(entry),
			tool = entry.name or "tool",
		})
		return
	end

	local abs_path = resolve_tool_file_path(entry)
	if not abs_path then
		vim.notify("pi: selected tool call has no diff source", vim.log.levels.WARN)
		return
	end

	if is_diff_capable_tool(entry.name) then
		local diff_text = get_git_diff_for_file(abs_path)
		if not diff_text then return end
		changes.show_diff({
			title = vim.fn.fnamemodify(abs_path, ":t"),
			text = diff_text,
			source = abs_path,
			tool = entry.name,
		})
		return
	end

	vim.notify("pi: diff action is only available for write/write_file/edit tool calls", vim.log.levels.INFO)
end

function M.refresh()
	if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then return end
	if not client.is_running() then
		M._set_content({ "", "  pi is not running", "", "  :PiStart to start", "" })
		return
	end
	if refresh_inflight then
		refresh_pending = true
		return
	end
	refresh_inflight = true

	client.get_state(function(state_resp)
		if state_resp and state_resp.success then
			local state = state_resp.data
			current_model = state.model and (state.model.provider .. "/" .. state.model.id) or ""
		end

		client.get_messages(function(response)
			vim.schedule(function()
				refresh_inflight = false
				if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then
					if refresh_pending then
						refresh_pending = false
						M.refresh()
					end
					return
				end
				if not response or not response.success then
					M._set_content({ "", "  Failed to load messages", "" })
				else
					last_messages = type(response.data.messages) == "table" and response.data.messages or {}
					M._render()
				end
				if refresh_pending then
					refresh_pending = false
					M.refresh()
				end
			end)
		end)
	end)
end

--- Render all messages
function M._render()
	local total_messages = #last_messages
	local max_messages = config.options.chat_max_messages or 150
	local start_idx = 1
	if max_messages > 0 and total_messages > max_messages then
		start_idx = total_messages - max_messages + 1
	end
	local messages = {}
	for i = start_idx, total_messages do
		table.insert(messages, last_messages[i])
	end

	local lines = {}
	local highlights = {}
	local line_idx = 0
	local content_width = get_chat_content_width()
	local section_width = math.max(content_width, 20)
	local text_width = math.max(section_width - 2, 18)
	local separator = "  " .. string.rep("━", section_width)
	local tool_entries = {}

	local function add_line(text, hl_group)
		table.insert(lines, sanitize_line_text(text))
		if hl_group then
			table.insert(highlights, { line_idx, hl_group })
		end
		line_idx = line_idx + 1
	end

	local function add_tool_entry(entry)
		table.insert(tool_entries, entry)
	end

	if #messages == 0 then
		add_line("")
		add_line("  No messages yet. Type in the input bar below.", "Comment")
		M._set_content(lines, highlights)
		return
	end

	-- Model info header
	local model_text = "  pi"
	if current_model and current_model ~= "" then
		model_text = model_text .. "  " .. current_model
	end
	add_line(model_text, "Title")
	if start_idx > 1 then
		add_line("  [showing last " .. tostring(#messages) .. " of " .. tostring(total_messages) .. " messages]", "Comment")
	end
	add_line("")

	-- Track tool calls in current assistant turn so toolResult can reuse names
	local pending_tools = {}
	local pending_tool_order = {}
	local assistant_section_open = false
	local last_render_kind = nil -- "text" | "tool"

	local function open_user_section()
		add_line("")
		add_line(separator, "PiSeparator")
		add_line("  You", "PiUserHeader")
		add_line(separator, "PiSeparator")
		assistant_section_open = false
		pending_tools = {}
		pending_tool_order = {}
		last_render_kind = nil
	end

	local function open_assistant_section(header_text)
		if assistant_section_open then return end
		add_line("")
		add_line(separator, "PiSeparator")
		add_line("  " .. header_text, "PiAssistantHeader")
		add_line(separator, "PiSeparator")
		assistant_section_open = true
	end

	for _, msg in ipairs(messages) do
		if msg.role == "user" then
			local text = M._extract_text(msg)
			if text and text ~= "" then
				open_user_section()
				local wrapped = M._wrap_text(text, text_width)
				for _, l in ipairs(wrapped) do
					add_line("  " .. l)
				end
				last_render_kind = "text"
			end

		elseif msg.role == "assistant" then
			open_assistant_section("Assistant")

			local text = M._extract_text(msg)
			if text and text ~= "" then
				if last_render_kind == "tool" then
					add_line("")
				end
				local wrapped = M._wrap_text(text, text_width)
				for _, l in ipairs(wrapped) do
					add_line("  " .. l)
				end
				last_render_kind = "text"
			end

			-- Extract tool calls from both msg.tool_calls and msg.content
			local tcalls = M._extract_tool_calls(msg)
			if #tcalls > 0 then
				add_line("")
				for _, tc in ipairs(tcalls) do
					local file = tc.file or ""
					local cmd = tc.command or ""
					local tool_id = tc.id or ("tool_" .. tostring(#pending_tool_order + 1))
					if file ~= "" then
						local body = tc.name .. "  " .. file
						add_line("  ▶ " .. M._truncate_text(body, section_width - 2), "PiToolCall")
					elseif cmd ~= "" then
						local body = tc.name .. "  " .. cmd:gsub("\n", " ")
						add_line("  ▶ " .. M._truncate_text(body, section_width - 2), "PiToolCall")
					else
						add_line("  ▶ " .. tc.name, "PiToolCall")
					end
					pending_tools[tool_id] = tc
					table.insert(pending_tool_order, tool_id)
					add_tool_entry({
						id = tool_id,
						name = tc.name,
						input = tc.input,
						line = line_idx - 1,
						details = tc.details,
						result_text = tc.result,
					})
				end
				last_render_kind = "tool"
			end

		elseif msg.role == "toolResult" then
			open_assistant_section("Assistant")
			local text = M._extract_text(msg)
			if text then
				local preview = text:gsub("\n", " ")
				local tool_data = msg.toolCallId and pending_tools[msg.toolCallId] or nil
				if not tool_data and #pending_tool_order > 0 then
					local last_id = pending_tool_order[#pending_tool_order]
					tool_data = pending_tools[last_id]
				end
				local tool_name = (tool_data and tool_data.name) or (msg.toolName or "tool")
				local prefix = "◀ " .. tool_name .. ": "
				local available = math.max(section_width - 2 - vim.fn.strdisplaywidth(prefix), 12)
				preview = M._truncate_text(preview, available)
				add_line("  ◀ " .. tool_name .. ": " .. preview, "PiToolResult")
				if msg.toolCallId and pending_tools[msg.toolCallId] then
					pending_tools[msg.toolCallId].details = msg.details
					pending_tools[msg.toolCallId].result_text = text
					for i = #tool_entries, 1, -1 do
						if tool_entries[i].id == msg.toolCallId then
							tool_entries[i].details = msg.details
							tool_entries[i].result_text = text
							break
						end
					end
				end
				last_render_kind = "tool"
			end
		end
	end

	-- Append streaming content if active
	if is_streaming then
		open_assistant_section("Assistant  (typing...)")
		if streaming_pre_tool_text ~= "" then
			if last_render_kind == "tool" then
				add_line("")
			end
			local wrapped = M._wrap_text(streaming_pre_tool_text, text_width)
			for _, l in ipairs(wrapped) do
				add_line("  " .. l)
			end
			last_render_kind = "text"
		end

		for _, tool_id in ipairs(streaming_tool_order) do
			local tc = streaming_tools_by_id[tool_id]
			if tc then
				local file = tc.file or ""
				local cmd = tc.command or ""
				local suffix = tc.running and "  (running...)" or ""
				if cmd ~= "" then
					local body = tc.name .. "  " .. cmd:gsub("\n", " ")
					add_line("  ▶ " .. M._truncate_text(body, section_width - 2) .. suffix, "PiToolCall")
				elseif file ~= "" then
					local body = tc.name .. "  " .. file
					add_line("  ▶ " .. M._truncate_text(body, section_width - 2) .. suffix, "PiToolCall")
				else
					add_line("  ▶ " .. tc.name .. suffix, "PiToolCall")
				end
				add_tool_entry({
					id = tool_id,
					name = tc.name,
					input = tc.input,
					line = line_idx - 1,
					details = tc.details,
					result_text = tc.result,
				})

				if tc.result and tc.result ~= "" then
					local preview = tc.result:gsub("\n", " ")
					local marker = tc.is_partial_result and "◀~ " or "◀ "
					local prefix = marker .. tc.name .. ": "
					local available = math.max(section_width - 2 - vim.fn.strdisplaywidth(prefix), 12)
					preview = M._truncate_text(preview, available)
					add_line("  " .. marker .. tc.name .. ": " .. preview, "PiToolResult")
				end
				last_render_kind = "tool"
			end
		end

		if streaming_post_tool_text ~= "" then
			if last_render_kind == "tool" then
				add_line("")
			end
			local wrapped = M._wrap_text(streaming_post_tool_text, text_width)
			for _, l in ipairs(wrapped) do
				add_line("  " .. l)
			end
			last_render_kind = "text"
		end
	end

	rendered_tool_entries = tool_entries
	if #rendered_tool_entries == 0 then
		selected_tool_idx = nil
		selected_tool_id = nil
	else
		selected_tool_idx = math.min(math.max(selected_tool_idx or 1, 1), #rendered_tool_entries)
		selected_tool_id = rendered_tool_entries[selected_tool_idx].id
	end

	if tool_nav_mode and selected_tool_idx and rendered_tool_entries[selected_tool_idx] then
		-- Selection highlight is handled by dedicated namespace for fast navigation.
	end

	M._set_content(lines, highlights)
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		if tool_nav_mode and selected_tool_idx and rendered_tool_entries[selected_tool_idx] then
			apply_tool_selection_visual()
		else
			local lc = vim.api.nvim_buf_line_count(chat_buf)
			vim.api.nvim_win_set_cursor(chat_win, { lc, 0 })
		end
	end
end

--- Extract tool calls from a message (from both msg.tool_calls and msg.content)
function M._extract_tool_calls(msg)
	local calls = {}
	if not msg then return calls end

	-- From msg.tool_calls (legacy or computed field)
	if msg.tool_calls and type(msg.tool_calls) == "table" then
		for _, tc in ipairs(msg.tool_calls) do
			local input = tc.input or tc.parameters or tc.arguments or {}
			if type(input) == "string" then
				local ok, p = pcall(vim.fn.json_decode, input)
				if ok then input = p end
			end
			table.insert(calls, {
				id = tc.id or tc.toolCallId,
				name = tc.name or tc.tool or "?",
				input = input,
				file = input.file_path or input.path or input.file or "",
				command = input.command or "",
			})
		end
	end

	-- From msg.content blocks (modern format)
	if msg.content and type(msg.content) == "table" then
		for _, block in ipairs(msg.content) do
			if block.type == "toolCall" then
				local args = block.arguments or {}
				if type(args) == "string" then
					local ok, p = pcall(vim.fn.json_decode, args)
					if ok then args = p end
				end
				table.insert(calls, {
					id = block.id,
					name = block.name or "?",
					input = args,
					file = args.file_path or args.path or args.file or "",
					command = args.command or "",
				})
			end
		end
	end

	return calls
end

function M._extract_text(msg)
	if not msg then return nil end
	local content = msg.content
	if not content then return nil end
	if type(content) == "string" then
		return clip_text_length(normalize_render_text(content))
	end
	if type(content) == "table" then
		local parts = {}
		for _, block in ipairs(content) do
			if block.type == "text" and type(block.text) == "string" then
				table.insert(parts, block.text)
			end
		end
		if #parts == 0 then return nil end
		return clip_text_length(normalize_render_text(table.concat(parts, "\n")))
	end
	return nil
end

function M._truncate_text(text, width)
	if not text then return "" end
	if width <= 0 then return "" end
	if vim.fn.strdisplaywidth(text) <= width then return text end
	local out = text
	while #out > 0 and vim.fn.strdisplaywidth(out .. "…") > width do
		out = out:sub(1, -2)
	end
	if out == "" then return "…" end
	return out .. "…"
end

function M._wrap_text(text, width)
	if not text or text == "" then return { "" } end
	local result = {}
	for _, raw in ipairs(vim.split(text, "\n")) do
		local line = raw:gsub("\x1b%[[%d;]*m", "")
		if line == "" then
			table.insert(result, "")
		elseif vim.fn.strdisplaywidth(line) <= width then
			table.insert(result, line)
		else
			local r = line
			while r ~= "" do
				if vim.fn.strdisplaywidth(r) <= width then
					table.insert(result, r)
					break
				end

				local best_char = 0
				local split_char = 0
				local char_count = vim.fn.strchars(r)
				for i = 1, char_count do
					local chunk = vim.fn.strcharpart(r, 0, i)
					if vim.fn.strdisplaywidth(chunk) > width then break end
					best_char = i
					if vim.fn.strcharpart(r, i - 1, 1) == " " then
						split_char = i
					end
				end

				local split_at = split_char > 0 and split_char or math.max(best_char, 1)
				local head = vim.fn.strcharpart(r, 0, split_at)
				head = head:gsub("%s+$", "")
				table.insert(result, head)
				r = vim.fn.strcharpart(r, split_at):gsub("^%s+", "")
			end
		end
	end
	return result
end

function M._set_content(lines, highlights)
	if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then return end
	local safe_lines = {}
	for i = 1, #lines do
		safe_lines[i] = sanitize_line_text(lines[i])
	end
	vim.api.nvim_buf_set_option(chat_buf, "modifiable", true)
	local ok, err = pcall(vim.api.nvim_buf_set_lines, chat_buf, 0, -1, false, safe_lines)
	if not ok then
		vim.api.nvim_buf_set_option(chat_buf, "modifiable", false)
		vim.notify("pi: failed to render chat buffer: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.api.nvim_buf_set_option(chat_buf, "modifiable", false)
	vim.api.nvim_buf_clear_namespace(chat_buf, chat_ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(chat_buf, chat_sel_ns, 0, -1)
	if highlights and #highlights > 0 then
		for _, hl in ipairs(highlights) do
			local row, group = hl[1], hl[2]
			if row ~= nil and group then
				local line = safe_lines[row + 1] or ""
				if line ~= "" then
					-- end_col is byte-based; -1 colors full line (important for multi-byte separator chars).
					vim.api.nvim_buf_add_highlight(chat_buf, chat_ns, group, row, 0, -1)
				end
			end
		end
	end
end

-- Auto-refresh on session change
vim.api.nvim_create_autocmd("User", {
	pattern = "PiSessionChanged",
	callback = function()
		if is_open and chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
			vim.schedule(function() M.refresh() end)
		end
	end,
})

return M

--- Chat Panel - shows the pi conversation in the center with a bottom input bar

local config = require("pi.config")
local client = require("pi.client")
local changes = require("pi.changes")
local render = require("pi.chat.render")
local stream = require("pi.chat.stream")
local tool_nav = require("pi.chat.tool_nav")
local palette = require("pi.chat.palette")
local focus = require("pi.chat.focus")
local slash = require("pi.chat.slash")
local completion = require("pi.chat.completion")

local M = {}

-- Window handles
local chat_buf = nil
local chat_win = nil
local input_buf = nil
local input_win = nil
local hint_buf = nil
local hint_win = nil
local is_open = false

-- Message/model state
local last_messages = {}
local current_model = ""
local auto_compaction_enabled = true
local current_context_usage = nil
local hint_height = 2

-- Namespace
local chat_ns = vim.api.nvim_create_namespace("pi_chat")
local chat_sel_ns = vim.api.nvim_create_namespace("pi_chat_sel")

-- Refresh state
local refresh_inflight = false
local refresh_pending = false

-- Sub-module state
local stream_state = stream.new_state()
local tool_nav_state = tool_nav.new_state()
local expanded_bash_tools = {}
local expanded_read_tools = {}
local last_non_pi_win = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get_ui_margins()
	local mx = tonumber(config.options.ui_margin_cols) or 0
	local my = tonumber(config.options.ui_margin_rows) or 0
	return math.max(0, math.floor(mx)), math.max(0, math.floor(my))
end

local function get_chat_content_width()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		local ok, width = pcall(vim.api.nvim_win_get_width, chat_win)
		if ok and width and width > 6 then
			return math.max(width - 2, 20)
		end
	end
	local dim = M.calc_dimensions()
	return math.max(dim.width - 2, 20)
end

local function chat_footer_text()
	return " [i] input  [q] close  [?] commands  [gt] tool-nav  [j/k] select  [Enter] action "
end

local function format_tokens(count)
	if type(count) ~= "number" then return "?" end
	if count < 1000 then return tostring(math.floor(count + 0.5)) end
	if count < 10000 then return string.format("%.1fk", count / 1000) end
	if count < 1000000 then return string.format("%dk", math.floor((count + 500) / 1000)) end
	if count < 10000000 then return string.format("%.1fM", count / 1000000) end
	return string.format("%dM", math.floor((count + 500000) / 1000000))
end

local function render_context_right()
	if type(current_context_usage) ~= "table" then
		return " context: ? "
	end
	local percent_value = current_context_usage.percent
	local percent_text = type(percent_value) == "number" and string.format("%.1f%%", percent_value) or "?"
	local window_text = format_tokens(tonumber(current_context_usage.contextWindow))
	local token_value = current_context_usage.tokens
	local token_text = type(token_value) == "number" and (" (" .. format_tokens(token_value) .. ")") or ""
	local auto_text = auto_compaction_enabled and " (auto)" or ""
	return " context: " .. percent_text .. "/" .. window_text .. token_text .. auto_text .. " "
end

local function render_hint_footer_line(width)
	local left = chat_footer_text()
	local model = (type(current_model) == "string" and current_model ~= "") and current_model or "?"
	local right = " model: " .. model .. " "
	local left_w = vim.fn.strdisplaywidth(left)
	local right_w = vim.fn.strdisplaywidth(right)
	if width <= 0 then
		return left .. right
	end
	if right_w >= width then
		return render.truncate_text(right, width)
	end
	if left_w + right_w <= width then
		return left .. string.rep(" ", width - left_w - right_w) .. right
	end
	local left_target = math.max(1, width - right_w - 1)
	return render.truncate_text(left, left_target) .. " " .. right
end

local function render_hint_context_line(width)
	local right = render_context_right()
	local right_w = vim.fn.strdisplaywidth(right)
	if width <= 0 then
		return right
	end
	if right_w >= width then
		return render.truncate_text(right, width)
	end
	return string.rep(" ", width - right_w) .. right
end

local function update_hint_bar(width)
	if not hint_buf or not vim.api.nvim_buf_is_valid(hint_buf) then return end
	local w = width
	if not w or w <= 0 then
		if hint_win and vim.api.nvim_win_is_valid(hint_win) then
			w = vim.api.nvim_win_get_width(hint_win)
		else
			local dim = M.calc_dimensions()
			w = dim.width or 0
		end
	end
	w = math.max(0, w)
	local lines = {
		render_hint_context_line(w),
		render_hint_footer_line(w),
	}
	vim.api.nvim_buf_set_option(hint_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(hint_buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(hint_buf, "modifiable", false)
	vim.api.nvim_buf_clear_namespace(hint_buf, chat_ns, 0, -1)
	for i = 0, #lines - 1 do
		vim.api.nvim_buf_add_highlight(hint_buf, chat_ns, "Comment", i, 0, -1)
	end
end

local function calc_hint_row(input_row)
	local hint_row = (input_row or 0) + 1
	local max_row = math.max(0, vim.o.lines - hint_height - 1)
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

local function close_pi_ui()
	M.close()
	local ok_sidebar, sidebar = pcall(require, "pi.sidebar")
	if ok_sidebar and sidebar and sidebar.close then sidebar.close() end
	local ok_changes, changes_mod = pcall(require, "pi.changes")
	if ok_changes and changes_mod and changes_mod.close then changes_mod.close() end
end

local function feedkeys(keys, mode)
	local term = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(term, mode or "in", true)
end

-- ---------------------------------------------------------------------------
-- Window dimensions
-- ---------------------------------------------------------------------------

function M.calc_dimensions()
	local total_w = vim.o.columns
	local total_h = vim.o.lines
	local mx, my = get_ui_margins()
	local sidebar_w = config.options.sidebar_width

	local sidebar_mod = require("pi.sidebar")
	local sidebar_open = sidebar_mod.is_open()
	local changes_open = changes.is_open()
	local top_row = my
	local bottom_row = total_h - 1 - my
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
		local chat_height = math.max(5, usable_h - (hint_height + 2))
		return { col = left_col, width = width, chat_height = chat_height, input_row = top_row + chat_height + 1, row = top_row }
	end

	local chat_left = left_col + sidebar_w + 3
	if changes_open then
		local changes_left_col = right_col - config.options.changes_width + 1
		local w = changes_left_col - chat_left - 1
		if w < 10 then w = right_col - chat_left + 1 end
		local chat_height = math.max(5, usable_h - (hint_height + 2))
		return { col = chat_left, width = w, chat_height = chat_height, input_row = top_row + chat_height + 1, row = top_row }
	else
		local w = right_col - chat_left + 1
		local chat_height = math.max(5, usable_h - (hint_height + 2))
		return { col = chat_left, width = w, chat_height = chat_height, input_row = top_row + chat_height + 1, row = top_row }
	end
end

-- ---------------------------------------------------------------------------
-- Content helpers (delegated to render module)
-- ---------------------------------------------------------------------------

function M._extract_text(msg)
	local text = render.extract_text(msg)
	if not text then return nil end
	return clip_text_length(normalize_render_text(text))
end

function M._truncate_text(text, width)
	return render.truncate_text(text, width)
end

function M._wrap_text(text, width)
	return render.wrap_text(text, width)
end

function M._set_content(lines, highlights)
	if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then return end
	local safe_lines = {}
	for i = 1, #lines do
		local text = lines[i]
		if type(text) ~= "string" then text = text == nil and "" or tostring(text) end
		safe_lines[i] = text
			:gsub("\x1b%[[%d;]*m", "")
			:gsub("[%z\1-\8\11\12\14-\31\127]", " ")
			:gsub("\r", "")
			:gsub("\n", " ")
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
					local col_start = hl[3] or 0
					local col_end = hl[4] or -1
					vim.api.nvim_buf_add_highlight(chat_buf, chat_ns, group, row, col_start, col_end)
				end
			end
		end
	end
end

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

	local content_width = get_chat_content_width()
	local section_width = math.max(content_width, 20)
	local text_width = math.max(section_width - 2, 18)

	local lines, highlights, entries = render.render({
		messages = messages,
		total_messages = total_messages,
		start_idx = start_idx,
		current_model = current_model,
		is_streaming = stream_state.is_streaming,
		streaming_pre_tool_text = stream_state.pre_tool_text,
		streaming_post_tool_text = stream_state.post_tool_text,
		streaming_tools_by_id = stream_state.tools_by_id,
		streaming_tool_order = stream_state.tool_order,
		section_width = section_width,
		text_width = text_width,
		expanded_bash_tools = expanded_bash_tools,
		expanded_read_tools = expanded_read_tools,
	})

	tool_nav.set_entries(tool_nav_state, entries)
	M._set_content(lines, highlights)

	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		if tool_nav.is_mode(tool_nav_state) then
			tool_nav.apply_selection_visual(tool_nav_state, chat_buf, chat_win, chat_sel_ns)
		else
			local lc = vim.api.nvim_buf_line_count(chat_buf)
			vim.api.nvim_win_set_cursor(chat_win, { lc, 0 })
		end
	end
end

-- ---------------------------------------------------------------------------
-- Slash commands (delegated to slash module)
-- ---------------------------------------------------------------------------

local function open_model_selector()
	client.get_available_models(function(response)
		vim.schedule(function()
			if not response or not response.success or not response.data then
				vim.notify("pi: " .. (response and response.error or "failed to load models"), vim.log.levels.ERROR)
				return
			end
			local models = response.data.models or {}
			if #models == 0 then
				vim.notify("pi: no available models", vim.log.levels.WARN)
				return
			end
			local items = {}
			for _, model in ipairs(models) do
				table.insert(items, { provider = model.provider or "?", id = model.id or "?", name = model.name or model.id or "?" })
			end
			focus.with_lock_suspended(function()
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
								vim.notify("pi: " .. (set_response and set_response.error or "failed to set model"), vim.log.levels.ERROR)
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
				vim.notify("pi: " .. (response and response.error or "failed to load fork points"), vim.log.levels.ERROR)
				return
			end
			local messages = response.data.messages or {}
			if #messages == 0 then
				vim.notify("pi: no user messages available for forking", vim.log.levels.INFO)
				return
			end
			focus.with_lock_suspended(function()
				vim.ui.select(messages, {
					prompt = "Fork from user message",
					format_item = function(item)
						local t = type(item.text) == "string" and item.text or ""
						t = t:gsub("%s+", " ")
						if vim.fn.strchars(t) > 90 then t = vim.fn.strcharpart(t, 0, 87) .. "..." end
						return t
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
								vim.notify("pi: " .. (fork_response and fork_response.error or "failed to fork session"), vim.log.levels.ERROR)
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
				vim.notify("pi: " .. (response and response.error or "failed to get last assistant message"), vim.log.levels.ERROR)
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

local function run_slash_command(message)
	if type(message) ~= "string" or message == "" then return end
	if slash.execute_local(message, {
		client = client,
		refresh = M.refresh,
		close_pi_ui = close_pi_ui,
		open_model_selector = open_model_selector,
		open_fork_selector = open_fork_selector,
		copy_last_assistant_to_clipboard = copy_last_assistant_to_clipboard,
	}) then
		return
	end
	if not client.is_running() then
		vim.notify("pi: not running. Use :PiStart first", vim.log.levels.ERROR)
		return
	end
	table.insert(last_messages, { role = "user", content = message, timestamp = vim.loop.now() })
	stream_state.is_streaming = true
	stream.reset(stream_state)
	if is_open and chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
		M._render()
	end
	client.prompt(message)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.open()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then return end

	local ctx = {
		get_palette_window = palette.get_window,
		get_input_window = function() return input_win end,
		get_chat_window = function() return chat_win end,
	}
	focus.ensure_lock(ctx)

	local cur_win = vim.api.nvim_get_current_win()
	if cur_win and vim.api.nvim_win_is_valid(cur_win) and not focus.is_pi_window(cur_win) then
		last_non_pi_win = cur_win
	end

	local dim = M.calc_dimensions()

	-- Chat buffer
	chat_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(chat_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(chat_buf, "filetype", "pi-chat")
	vim.api.nvim_buf_set_option(chat_buf, "wrap", true)
	vim.api.nvim_buf_set_name(chat_buf, "pi://chat")

	chat_win = vim.api.nvim_open_win(chat_buf, false, {
		style = "minimal", relative = "editor",
		width = dim.width, height = dim.chat_height,
		row = dim.row or 0, col = dim.col,
		border = "single", title = " 🤖 pi ",
	})
	is_open = true

	-- Input buffer
	input_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(input_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(input_buf, "filetype", "pi-input")
	vim.api.nvim_buf_set_option(input_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "> " })

	input_win = vim.api.nvim_open_win(input_buf, false, {
		style = "minimal", relative = "editor",
		width = dim.width, height = 1,
		row = dim.input_row, col = dim.col,
		border = "none",
	})

	-- Hint buffer
	hint_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(hint_buf, "pi://hints")
	vim.api.nvim_buf_set_option(hint_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(hint_buf, "filetype", "pi-hints")
	vim.api.nvim_buf_set_option(hint_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(hint_buf, 0, -1, false, { "", "" })
	vim.api.nvim_buf_set_option(hint_buf, "modifiable", false)

	hint_win = vim.api.nvim_open_win(hint_buf, false, {
		style = "minimal", relative = "editor",
		width = dim.width, height = hint_height,
		row = calc_hint_row(dim.input_row), col = dim.col,
		border = "none", focusable = false, noautocmd = true,
	})
	update_hint_bar(dim.width)

	-- Completion
	completion.setup(input_buf)

	-- Keymaps for chat buffer
	local km = { buffer = chat_buf, noremap = true, silent = true }
	vim.keymap.set("n", "q", function() close_pi_ui() end, km)
	vim.keymap.set("n", "r", function() M.refresh() end, km)
	vim.keymap.set("n", "i", function() M.focus_input() end, km)
	vim.keymap.set("n", "<CR>", function()
		if tool_nav.is_mode(tool_nav_state) and tool_nav_state.selected_tool_idx then
			tool_nav.tool_enter_action(tool_nav_state, expanded_read_tools, expanded_bash_tools, {
				changes = changes,
				on_render = M._render,
				focus_input = M.focus_input,
				close_pi_ui = close_pi_ui,
				get_last_non_pi_win = function() return last_non_pi_win end,
				is_pi_window = focus.is_pi_window,
			})
		else
			M.focus_input()
		end
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_command_palette, function() M.open_command_palette() end, km)
	vim.keymap.set("n", "<C-h>", function() require("pi.sidebar").focus() end, km)
	vim.keymap.set("n", "<C-l>", function()
		local changes_mod = require("pi.changes")
		if changes_mod.is_open() then changes_mod.focus() end
	end, km)
	vim.keymap.set("n", "<Left>", function() require("pi.sidebar").focus() end, km)
	vim.keymap.set("n", "<Right>", function()
		local changes_mod = require("pi.changes")
		if changes_mod.is_open() then changes_mod.focus() end
	end, km)
	vim.keymap.set("n", "<C-j>", function() M.focus_input() end, km)
	vim.keymap.set("n", "<Down>", function() M.focus_input() end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_nav_toggle, function() M.toggle_tool_nav_mode() end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_next, function()
		if tool_nav.is_mode(tool_nav_state) then
			tool_nav.select_next(tool_nav_state, chat_buf, chat_win, chat_sel_ns)
		else
			vim.cmd("normal! j")
		end
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_prev, function()
		if tool_nav.is_mode(tool_nav_state) then
			tool_nav.select_prev(tool_nav_state, chat_buf, chat_win, chat_sel_ns)
		else
			vim.cmd("normal! k")
		end
	end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_open_file, function() M.open_selected_tool_file() end, km)
	vim.keymap.set("n", config.options.keymaps.chat_tool_open_diff, function() M.open_selected_tool_diff() end, km)

	-- Keymaps for input buffer
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
	vim.keymap.set("i", "<Esc>", function() leave_input_to_chat(true) end, ikm)
	vim.keymap.set("i", "<C-j>", function() leave_input_to_chat(false) end, ikm)
	vim.keymap.set("i", "<C-k>", function() leave_input_to_chat(false) end, ikm)
	vim.keymap.set("i", "<C-c>", function() leave_input_to_chat(false) end, ikm)
	vim.keymap.set("i", "<C-h>", function()
		leave_input_to_chat(false)
		vim.schedule(function() require("pi.sidebar").focus() end)
	end, ikm)
	vim.keymap.set("i", "<C-l>", function()
		leave_input_to_chat(false)
		vim.schedule(function()
			local changes_mod = require("pi.changes")
			if changes_mod.is_open() then changes_mod.focus() end
		end)
	end, ikm)
	vim.keymap.set("n", "<Esc>", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", "<C-j>", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", "<C-k>", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", "q", function() leave_input_to_chat(false) end, nkm)
	vim.keymap.set("n", config.options.keymaps.chat_command_palette, function() M.open_command_palette() end, nkm)

	focus.map_window_stay_keys(chat_buf)
	focus.map_window_stay_keys(input_buf)

	-- Reset and register handlers
	stream_state.is_streaming = false
	stream.reset(stream_state)
	stream.ensure_handlers({
		client = client,
		state = stream_state,
		is_open = function() return is_open end,
		on_render = M._render,
		on_refresh = M.refresh,
	})

	M.refresh()
end

function M.relayout()
	if not is_open then return end
	local dim = M.calc_dimensions()
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		vim.api.nvim_win_set_config(chat_win, {
			relative = "editor", row = dim.row or 0, col = dim.col,
			width = dim.width, height = dim.chat_height,
		})
	end
	if input_win and vim.api.nvim_win_is_valid(input_win) then
		vim.api.nvim_win_set_config(input_win, {
			relative = "editor", row = dim.input_row, col = dim.col,
			width = dim.width, height = 1,
		})
	end
	if hint_win and vim.api.nvim_win_is_valid(hint_win) then
		vim.api.nvim_win_set_config(hint_win, {
			relative = "editor", row = calc_hint_row(dim.input_row), col = dim.col,
			width = dim.width, height = hint_height,
		})
	end
	update_hint_bar(dim.width)
	if is_open then M._render() end
end

function M.focus_input()
	if input_win and vim.api.nvim_win_is_valid(input_win) then
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("startinsert!")
	end
end

function M.open_command_palette()
	palette.open({
		ensure_focus_lock_autocmd = function()
			local ctx = {
				get_palette_window = palette.get_window,
				get_input_window = function() return input_win end,
				get_chat_window = function() return chat_win end,
			}
			focus.ensure_lock(ctx)
		end,
		with_focus_lock_suspended = focus.with_lock_suspended,
		map_window_stay_keys = focus.map_window_stay_keys,
		run_slash_command = run_slash_command,
	})
end

function M.submit_input()
	local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
	local msg = lines[1] or ""
	msg = msg:gsub("^>%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "" then return end
	vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "> " })
	if slash.execute_local(msg, {
		client = client,
		refresh = M.refresh,
		close_pi_ui = close_pi_ui,
		open_model_selector = open_model_selector,
		open_fork_selector = open_fork_selector,
		copy_last_assistant_to_clipboard = copy_last_assistant_to_clipboard,
	}) then
		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.cmd("startinsert!")
		end
		return
	end
	if not client.is_running() then
		vim.notify("pi: not running. Use :PiStart first", vim.log.levels.ERROR)
		return
	end
	stream_state.is_streaming = true
	stream.reset(stream_state)
	table.insert(last_messages, { role = "user", content = msg, timestamp = vim.loop.now() })
	if is_open and chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
		M._render()
	end
	client.prompt(msg)
	vim.cmd("startinsert!")
end

function M.close()
	palette.close()
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

-- ---------------------------------------------------------------------------
-- Tool navigation (delegated to tool_nav module)
-- ---------------------------------------------------------------------------

function M.is_tool_nav_mode()
	return tool_nav.is_mode(tool_nav_state)
end

function M.toggle_tool_nav_mode()
	tool_nav.toggle_mode(tool_nav_state, chat_buf, chat_win, chat_sel_ns)
end

function M.select_next_tool()
	tool_nav.select_next(tool_nav_state, chat_buf, chat_win, chat_sel_ns)
end

function M.select_prev_tool()
	tool_nav.select_prev(tool_nav_state, chat_buf, chat_win, chat_sel_ns)
end

function M.open_selected_tool_file()
	tool_nav.open_selected_file(tool_nav_state, {
		close_pi_ui = close_pi_ui,
		get_last_non_pi_win = function() return last_non_pi_win end,
		is_pi_window = focus.is_pi_window,
	})
end

function M.open_selected_tool_diff()
	tool_nav.open_selected_diff(tool_nav_state, changes, {
		close_pi_ui = close_pi_ui,
		get_last_non_pi_win = function() return last_non_pi_win end,
		is_pi_window = focus.is_pi_window,
	})
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

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
			auto_compaction_enabled = state.autoCompactionEnabled ~= false
			update_hint_bar()
		end
	end)

	client.get_session_stats(function(stats_resp)
		if stats_resp and stats_resp.success and stats_resp.data then
			current_context_usage = stats_resp.data.contextUsage
		else
			current_context_usage = nil
		end
		update_hint_bar()
	end)

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
end

-- ---------------------------------------------------------------------------
-- Auto-refresh
-- ---------------------------------------------------------------------------

vim.api.nvim_create_autocmd("User", {
	pattern = "PiSessionChanged",
	callback = function()
		if is_open and chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
			vim.schedule(function() M.refresh() end)
		end
	end,
})

return M

--- Session Sidebar - shows pinned sessions and all sessions on the left side
---
--- Layout:
--- ┌──────────────────────┐
--- │ 📌 Pinned Sessions   │
--- │ > Fix auth bug  2m   │
--- │   Refactor API  1h   │
--- │                      │
--- │ ─── All Sessions ─── │
--- │   New feat      3d   │
--- │   Quick fix     5m   │
--- └──────────────────────┘

local config = require("pi.config")
local client = require("pi.client")

local M = {}

local sidebar_buf = nil
local sidebar_win = nil
local sessions = {}
local pinned_paths = {}
local selected_index = 0
local pinned_count = 0
local refresh_seq = 0
local ENRICH_MAX_FILE_BYTES = 1024 * 1024
local ENRICH_MAX_LINES = 1500

-- Paths
local data_dir = vim.fn.stdpath("data") .. "/pi"
local pinned_file = data_dir .. "/pinned_sessions.json"

local function get_pinned_file()
	return config.options.pinned_file or pinned_file
end

local function get_agent_dir()
	local env_dir = vim.env.PI_CODING_AGENT_DIR
	if env_dir and env_dir ~= "" then
		if env_dir == "~" then return vim.fn.expand("~") end
		if env_dir:sub(1, 2) == "~/" then
			return vim.fn.expand("~") .. env_dir:sub(2)
		end
		return env_dir
	end
	return vim.fn.expand("~/.pi/agent")
end

local function encode_cwd_for_session_dir(cwd)
	local abs = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p")
	abs = abs:gsub("[/\\]$", "")
	local safe = abs:gsub("^[/\\]", ""):gsub("[/\\:]", "-")
	return "--" .. safe .. "--"
end

local function get_sessions_dir_for_cwd(cwd)
	if config.options.session_dir and config.options.session_dir ~= "" then
		return config.options.session_dir
	end
	local agent_dir = get_agent_dir()
	return agent_dir .. "/sessions/" .. encode_cwd_for_session_dir(cwd)
end

local function decode_json(line)
	if not line or line == "" then return nil end
	if vim.json and vim.json.decode then
		local ok, parsed = pcall(vim.json.decode, line)
		if ok then return parsed end
	end
	local ok, parsed = pcall(vim.fn.json_decode, line)
	if ok then return parsed end
	return nil
end

--- Load pinned session paths from disk
local function load_pinned()
	local f = io.open(get_pinned_file(), "r")
	if f then
		local content = f:read("*a")
		f:close()
		local ok, data = pcall(vim.fn.json_decode, content)
		if ok and type(data) == "table" then
			pinned_paths = data
			return
		end
	end
	pinned_paths = {}
end

--- Save pinned session paths to disk
local function save_pinned()
	vim.fn.mkdir(data_dir, "p")
	local f = io.open(get_pinned_file(), "w")
	if f then
		f:write(vim.fn.json_encode(pinned_paths))
		f:close()
	end
end

--- Check if a session path is pinned
local function is_pinned(path)
	for _, p in ipairs(pinned_paths) do
		if p == path then return true end
	end
	return false
end

--- Toggle pin status for selected session
local function toggle_pin()
	if selected_index <= 0 or selected_index > #sessions then return end
	local session = sessions[selected_index]
	local path = session.path

	if is_pinned(path) then
		-- Unpin
		local new_pinned = {}
		for _, p in ipairs(pinned_paths) do
			if p ~= path then table.insert(new_pinned, p) end
		end
		pinned_paths = new_pinned
	else
		-- Pin
		table.insert(pinned_paths, path)
	end

	save_pinned()
	M.render()
end

--- Format relative time
local function time_ago(date_str)
	local session_time = vim.fn.strptime("%Y-%m-%dT%H:%M:%S", date_str:sub(1, 19))
	if not session_time then return "?" end
	local diff = os.time() - session_time
	if diff < 60 then return "now" end
	if diff < 3600 then return math.floor(diff / 60) .. "m" end
	if diff < 86400 then return math.floor(diff / 3600) .. "h" end
	if diff < 604800 then return math.floor(diff / 86400) .. "d" end
	if diff < 2592000 then return math.floor(diff / 604800) .. "w" end
	return math.floor(diff / 2592000) .. "mo"
end

local function get_ui_margins()
	local mx = tonumber(config.options.ui_margin_cols) or 0
	local my = tonumber(config.options.ui_margin_rows) or 0
	return math.max(0, math.floor(mx)), math.max(0, math.floor(my))
end

--- Scan session directory for current working directory.
local function scan_sessions(cwd)
	local sessions_dir = get_sessions_dir_for_cwd(cwd)
	if vim.fn.isdirectory(sessions_dir) == 0 then
		sessions = {}
		return
	end

	-- Scan current cwd session dir only.
	local all_files = {}
	local dir_handle = vim.loop.fs_scandir(sessions_dir)
	if dir_handle then
		while true do
			local name, entry_type = vim.loop.fs_scandir_next(dir_handle)
			if not name then break end
			if entry_type == "file" and name:sub(-6) == ".jsonl" then
				table.insert(all_files, sessions_dir .. "/" .. name)
			end
		end
	end

	sessions = {}

	for _, file in ipairs(all_files) do
		local info = {
			path = file,
			id = vim.fn.fnamemodify(file, ":t:r"),
			created = "",
			modified = "",
			message_count = 0,
			first_message = "(empty)",
			name = nil,
			cwd = "",
			size_bytes = 0,
		}

		local stat = vim.loop.fs_stat(file)
		if stat and stat.mtime and stat.mtime.sec then
			info.modified = os.date("!%Y-%m-%dT%H:%M:%S", stat.mtime.sec)
			info.created = info.modified
			info.size_bytes = stat.size or 0
		end

		local valid_header = false
		local f = io.open(file, "r")
		if f then
			local header_line = f:read("*l")
			f:close()
			local header = decode_json(header_line)
			if header
				and type(header) == "table"
				and header.type == "session"
				and type(header.id) == "string"
			then
				valid_header = true
				info.id = header.id or info.id
				info.created = header.timestamp or info.created
				info.cwd = header.cwd or info.cwd
			end
		end

		if valid_header then
			table.insert(sessions, info)
		end
	end

	-- Sort by modified (newest first)
	table.sort(sessions, function(a, b)
		return a.modified > b.modified
	end)
end

--- Enrich sessions with message data (synchronous - session files are small)
local function enrich_sessions(callback, seq)
	if #sessions == 0 then
		if callback then callback() end
		return
	end

	local idx = 1
	local chunk_size = 12

	local function process_one(session_idx)
		local session = sessions[session_idx]
		if not session then return end
		local f = io.open(session.path, "r")
		if not f then return end

		local msg_count = 0
		local first_msg = "(empty)"
		local session_name = nil
		local last_activity = nil
		local line_count = 0

		for line in f:lines() do
			line_count = line_count + 1
			if line_count > ENRICH_MAX_LINES then break end
			local entry = decode_json(line)
			if entry then
				if entry.type == "message" and entry.message then
					msg_count = msg_count + 1
					local msg = entry.message
					if msg.role == "user" and first_msg == "(empty)" then
						local text_content = msg.content
						if type(text_content) == "string" then
							first_msg = text_content:sub(1, 80)
						elseif type(text_content) == "table" then
							for _, block in ipairs(text_content) do
								if block.type == "text" and block.text then
									first_msg = block.text:sub(1, 80)
									break
								end
							end
						end
					end
					if msg.role == "user" or msg.role == "assistant" then
						local ts = entry.timestamp
						if ts and ts > (last_activity or "") then
							last_activity = ts
						end
					end
				elseif entry.type == "session_info" and entry.name then
					session_name = entry.name
				end
			end
		end
		f:close()

		sessions[session_idx].message_count = msg_count
		sessions[session_idx].first_message = first_msg
		sessions[session_idx].name = session_name
		if last_activity then
			sessions[session_idx].modified = last_activity
		end
	end

	local function process_chunk()
		if seq ~= refresh_seq then return end
		local processed = 0
		while idx <= #sessions and processed < chunk_size do
			process_one(idx)
			idx = idx + 1
			processed = processed + 1
		end

		if idx <= #sessions then
			if sidebar_buf and vim.api.nvim_buf_is_valid(sidebar_buf) then
				vim.schedule(function()
					if seq == refresh_seq then M.render() end
				end)
			end
			vim.defer_fn(process_chunk, 1)
			return
		end

		-- Sort by modified time after enrichment
		table.sort(sessions, function(a, b)
			return a.modified > b.modified
		end)

		if callback then callback() end
	end

	process_chunk()
end

--- Open the sidebar window
function M.open(cwd)
	if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
		M.refresh(cwd)
		return
	end

	local target_cwd = cwd or vim.fn.getcwd()
	load_pinned()
	scan_sessions(target_cwd)

	-- Create buffer
	sidebar_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(sidebar_buf, "pi://sessions")

	-- Buffer options
	vim.api.nvim_buf_set_option(sidebar_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(sidebar_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(sidebar_buf, "filetype", "pi-sidebar")

	-- Open window on the left
	local width = config.options.sidebar_width
	local mx, my = get_ui_margins()
	local height = math.max(8, vim.o.lines - 1 - (my * 2))
	local opts = {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height, -- minus cmdline + margins
		row = my,
		col = mx,
		border = "single",
	}
	sidebar_win = vim.api.nvim_open_win(sidebar_buf, true, opts)

	-- Set up keymaps
	M._set_keymaps()

	-- Enrich and render
	refresh_seq = refresh_seq + 1
	local seq = refresh_seq
	enrich_sessions(function()
		vim.schedule(function()
			if seq == refresh_seq then M.render() end
		end)
	end, seq)

	M.render()
end

--- Check if sidebar is open
--- @return boolean
function M.is_open()
	return sidebar_win ~= nil and vim.api.nvim_win_is_valid(sidebar_win)
end

--- Focus the sidebar window
function M.focus()
	if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
		vim.api.nvim_set_current_win(sidebar_win)
	end
end

--- Close the sidebar
function M.close()
	if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
		vim.api.nvim_win_close(sidebar_win, true)
		sidebar_win = nil
	end
end

--- Toggle the sidebar
function M.toggle(cwd)
	if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
		M.close()
	else
		M.open(cwd)
	end
end

--- Refresh session list
function M.refresh(cwd)
	local target_cwd = cwd or vim.fn.getcwd()
	load_pinned()
	scan_sessions(target_cwd)
	refresh_seq = refresh_seq + 1
	local seq = refresh_seq
	enrich_sessions(function()
		vim.schedule(function()
			if seq == refresh_seq then M.render() end
		end)
	end, seq)
end

--- Render the sidebar
function M.render()
	if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then
		return
	end

	vim.api.nvim_buf_set_option(sidebar_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, {})

	local lines = {}
	local highlights = {}

	-- Pinned sessions section
	local pinned_sessions = {}
	local unpinned_sessions = {}

	for _, s in ipairs(sessions) do
		if is_pinned(s.path) then
			table.insert(pinned_sessions, s)
		else
			table.insert(unpinned_sessions, s)
		end
	end

	local idx = 0

	local function get_selected_path()
		if selected_index <= 0 or selected_index > #sessions then return nil end
		return sessions[selected_index].path
	end

	if #pinned_sessions > 0 then
		table.insert(lines, " 📌 Pinned Sessions")
		table.insert(highlights, { idx, "PiSidebarHeader" })
		idx = idx + 1

		for _, s in ipairs(pinned_sessions) do
			idx = idx + 1
			local sel_path = get_selected_path() == s.path and s.path or nil
			local display = M._format_session_line(s, sel_path)
			table.insert(lines, display.text)
			for _, hl in ipairs(display.highlights) do
				table.insert(highlights, { idx - 1, hl.group, hl.col, hl.end_col })
			end
		end

		table.insert(lines, "")
		idx = idx + 1
	end

	-- All sessions section
	table.insert(lines, " ── Sessions")
	table.insert(highlights, { idx, "PiSidebarHeader" })
	pinned_count = #pinned_sessions
	idx = idx + 1

	if #unpinned_sessions == 0 and #pinned_sessions == 0 then
		table.insert(lines, "  (no sessions)")
		table.insert(highlights, { idx, "PiSidebarTime", 0, -1 })
	else
		for _, s in ipairs(unpinned_sessions) do
			idx = idx + 1
			local sel_path = get_selected_path() == s.path and s.path or nil
			local display = M._format_session_line(s, sel_path)
			table.insert(lines, display.text)
			for _, hl in ipairs(display.highlights) do
				table.insert(highlights, { idx - 1, hl.group, hl.col, hl.end_col })
			end
		end
	end

	-- Help footer
	local win_h = sidebar_win and vim.api.nvim_win_is_valid(sidebar_win)
		and vim.api.nvim_win_get_height(sidebar_win)
		or (vim.o.lines - 1)
	local footer_h = win_h - #lines - 4
	if footer_h > 0 then
		for _ = 1, footer_h do
			table.insert(lines, "")
		end
	end
	table.insert(lines, " ────────────────")
	table.insert(highlights, { #lines - 1, "PiSidebarHeader" })
	table.insert(lines, " <CR> open  P pin  q close")
	table.insert(highlights, { #lines - 1, "PiSidebarTime" })
	table.insert(lines, " d delete  r name  ? cmds")
	table.insert(highlights, { #lines - 1, "PiSidebarTime" })

	vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)

	-- Apply highlights
	for _, hl in ipairs(highlights) do
		local row, group = hl[1], hl[2]
		if not row or not group then goto continue end
		local col = hl[3] or 0
		local end_col = hl[4] or -1
		local line_text = lines[row + 1] or ""
		local len = vim.api.nvim_strwidth(line_text)
		if end_col == -1 or end_col > len then end_col = len end
		if col < 0 then col = 0 end
		if col < len and end_col > col then
			vim.api.nvim_buf_add_highlight(sidebar_buf, -1, group, row, col, end_col)
		end
		::continue::
	end

	vim.api.nvim_buf_set_option(sidebar_buf, "modifiable", false)
end

--- Format a session line
--- @param session table
--- @param selected_path string|nil
--- @return { text: string, highlights: table }
function M._format_session_line(session, selected_path)
	local prefix = selected_path and "› " or "  "
	local msg = session.name or session.first_message
	if not msg or msg == "" then msg = "(empty)" end
	-- Truncate message
	if vim.api.nvim_strwidth(msg) > 22 then
		msg = vim.fn.strcharpart(msg, 0, 20) .. "…"
	end

	local time = time_ago(session.modified)
	local count = session.message_count > 0 and tostring(session.message_count) or ""

	-- Calculate spacing
	local left = prefix .. msg
	local left_w = vim.api.nvim_strwidth(left)
	local right = time .. (count ~= "" and " (" .. count .. ")" or "")
	local right_w = vim.api.nvim_strwidth(right)
	local total_w = config.options.sidebar_width - 2
	local spacing = math.max(1, total_w - left_w - right_w)

	local text = left .. string.rep(" ", spacing) .. right
	local highlights = {}

	if selected_path then
		table.insert(highlights, { group = "PiSidebarSelected", col = 0, end_col = -1 })
	end

	if is_pinned(session.path) then
		table.insert(highlights, { group = "PiSidebarPinned", col = 2, end_col = 2 + vim.api.nvim_strwidth(msg) })
	end

	local right_start = left_w + spacing
	table.insert(highlights, { group = "PiSidebarTime", col = right_start, end_col = right_start + right_w })

	return { text = text, highlights = highlights }
end

--- Get the selected session path
--- @return string|nil
function M.get_selected_path()
	if selected_index <= 0 or selected_index > #sessions then return nil end
	return sessions[selected_index].path
end

--- Switch to the selected session
function M.select_session()
	local path = M.get_selected_path()
	if not path then
		vim.notify("pi: no session selected", vim.log.levels.WARN)
		return
	end
	if not client.is_running() then
		vim.notify("pi: not running. Use :PiStart first", vim.log.levels.ERROR)
		return
	end
	vim.notify("pi: switching session...", vim.log.levels.INFO)
	local id = client.switch_session(path, function(response)
		vim.schedule(function()
			if response and response.success then
				vim.notify("pi: switched session", vim.log.levels.INFO)
				vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
				-- Focus chat after switching
				local chat_mod = require("pi.chat")
				if not chat_mod.is_open() then
					chat_mod.open()
				end
				chat_mod.focus()
			else
				local err = response and response.error or "unknown error"
				vim.notify("pi: failed to switch session: " .. err, vim.log.levels.ERROR)
			end
		end)
	end)
	if not id then
		vim.notify("pi: failed to send switch command", vim.log.levels.ERROR)
	end
end

--- Set up keymaps for the sidebar
function M._set_keymaps()
	local opts = { buffer = sidebar_buf, noremap = true, silent = true }

	vim.keymap.set("n", config.options.keymaps.sidebar_select, function()
		M.select_session()
	end, opts)

	-- Pin/Unpin
	vim.keymap.set("n", config.options.keymaps.sidebar_toggle_pin, function()
		toggle_pin()
	end, opts)

	-- Delete session
	vim.keymap.set("n", config.options.keymaps.sidebar_delete, function()
		local ok = vim.fn.confirm("Delete this session?", "&Yes\n&No")
		if ok == 1 then
			local path = M.get_selected_path()
			if path then
				os.remove(path)
				vim.notify("pi: session deleted", vim.log.levels.INFO)
				M.refresh()
			end
		end
	end, opts)

	-- Rename session
	vim.keymap.set("n", config.options.keymaps.sidebar_rename, function()
		local path = M.get_selected_path()
		if not path then return end
		vim.ui.input({ prompt = "Session name: " }, function(name)
			if name and name ~= "" then
				client.set_session_name(name)
				vim.notify("pi: session renamed", vim.log.levels.INFO)
				M.refresh()
			end
		end)
	end, opts)

	vim.keymap.set("n", "<Down>", function()
		selected_index = math.min(selected_index + 1, #sessions)
		M.render()
	end, opts)

	vim.keymap.set("n", "j", function()
		selected_index = math.min(selected_index + 1, #sessions)
		M.render()
	end, opts)

	vim.keymap.set("n", "<Up>", function()
		selected_index = math.max(selected_index - 1, 1)
		M.render()
	end, opts)

	vim.keymap.set("n", "k", function()
		selected_index = math.max(selected_index - 1, 1)
		M.render()
	end, opts)

	-- Navigate to chat with <C-l>
	vim.keymap.set("n", "<C-l>", function()
		require("pi.chat").focus()
	end, opts)
	-- Also map <Right> arrow for convenience
	vim.keymap.set("n", "<Right>", function()
		require("pi.chat").focus()
	end, opts)

	vim.keymap.set("n", "q", function()
		M.close()
		-- Also close chat if it's open
		local chat_mod = require("pi.chat")
		chat_mod.close()
	end, opts)

	-- Set initial selection to first session
	if #sessions > 0 and selected_index == 0 then
		selected_index = 1
	end
end

-- Auto-refresh on session change
vim.api.nvim_create_autocmd("User", {
	pattern = "PiSessionChanged",
	callback = function()
		if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
			M.refresh()
		end
	end,
})

return M

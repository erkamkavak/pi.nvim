local json = require("pi.util.json")

local M = {}

local ENRICH_MAX_LINES = 1500

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

function M.new(config)
	local data_dir = vim.fn.stdpath("data") .. "/pi"
	local default_pinned_file = data_dir .. "/pinned_sessions.json"

	local st = {
		config = config,
		data_dir = data_dir,
		default_pinned_file = default_pinned_file,
		sessions = {},
		pinned_paths = {},
		selected_index = 0,
		pinned_count = 0,
		refresh_seq = 0,
	}

	function st.get_pinned_file()
		return st.config.options.pinned_file or st.default_pinned_file
	end

	function st.get_sessions_dir_for_cwd(cwd)
		if st.config.options.session_dir and st.config.options.session_dir ~= "" then
			return st.config.options.session_dir
		end
		return get_agent_dir() .. "/sessions/" .. encode_cwd_for_session_dir(cwd)
	end

	function st.load_pinned()
		local f = io.open(st.get_pinned_file(), "r")
		if f then
			local content = f:read("*a")
			f:close()
			local ok, data = pcall(vim.fn.json_decode, content)
			if ok and type(data) == "table" then
				st.pinned_paths = data
				return
			end
		end
		st.pinned_paths = {}
	end

	function st.save_pinned()
		vim.fn.mkdir(st.data_dir, "p")
		local f = io.open(st.get_pinned_file(), "w")
		if f then
			f:write(vim.fn.json_encode(st.pinned_paths))
			f:close()
		end
	end

	function st.is_pinned(path)
		for _, p in ipairs(st.pinned_paths) do
			if p == path then return true end
		end
		return false
	end

	function st.toggle_pin_selected()
		if st.selected_index <= 0 or st.selected_index > #st.sessions then return end
		local path = st.sessions[st.selected_index].path
		if st.is_pinned(path) then
			local next = {}
			for _, p in ipairs(st.pinned_paths) do
				if p ~= path then table.insert(next, p) end
			end
			st.pinned_paths = next
		else
			table.insert(st.pinned_paths, path)
		end
		st.save_pinned()
	end

	function st.scan_sessions(cwd)
		local sessions_dir = st.get_sessions_dir_for_cwd(cwd)
		if vim.fn.isdirectory(sessions_dir) == 0 then
			st.sessions = {}
			return
		end

		local files = {}
		local handle = vim.loop.fs_scandir(sessions_dir)
		if handle then
			while true do
				local name, entry_type = vim.loop.fs_scandir_next(handle)
				if not name then break end
				if entry_type == "file" and name:sub(-6) == ".jsonl" then
					table.insert(files, sessions_dir .. "/" .. name)
				end
			end
		end

		st.sessions = {}
		for _, file in ipairs(files) do
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
				local header = json.decode(f:read("*l"))
				f:close()
				if header and type(header) == "table" and header.type == "session" and type(header.id) == "string" then
					valid_header = true
					info.id = header.id or info.id
					info.created = header.timestamp or info.created
					info.cwd = header.cwd or info.cwd
				end
			end

			if valid_header then
				table.insert(st.sessions, info)
			end
		end

		table.sort(st.sessions, function(a, b) return a.modified > b.modified end)
	end

	function st.enrich_sessions(seq, on_progress, on_done)
		if #st.sessions == 0 then
			if on_done then on_done() end
			return
		end

		local idx = 1
		local chunk_size = 12

		local function process_one(session_idx)
			local session = st.sessions[session_idx]
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
				local entry = json.decode(line)
				if entry then
					if entry.type == "message" and entry.message then
						msg_count = msg_count + 1
						local msg = entry.message
						if msg.role == "user" and first_msg == "(empty)" then
							local c = msg.content
							if type(c) == "string" then
								first_msg = c:sub(1, 80)
							elseif type(c) == "table" then
								for _, block in ipairs(c) do
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

			session.message_count = msg_count
			session.first_message = first_msg
			session.name = session_name
			if last_activity then
				session.modified = last_activity
			end
		end

		local function process_chunk()
			if seq ~= st.refresh_seq then return end
			local processed = 0
			while idx <= #st.sessions and processed < chunk_size do
				process_one(idx)
				idx = idx + 1
				processed = processed + 1
			end

			if idx <= #st.sessions then
				if on_progress then on_progress() end
				vim.defer_fn(process_chunk, 1)
				return
			end

			table.sort(st.sessions, function(a, b) return a.modified > b.modified end)
			if on_done then on_done() end
		end

		process_chunk()
	end

	function st.bump_refresh_seq()
		st.refresh_seq = st.refresh_seq + 1
		return st.refresh_seq
	end

	function st.get_selected_path()
		if st.selected_index <= 0 or st.selected_index > #st.sessions then return nil end
		return st.sessions[st.selected_index].path
	end

	function st.ensure_initial_selection()
		if #st.sessions > 0 and st.selected_index == 0 then
			st.selected_index = 1
		end
	end

	function st.move_selection(delta)
		if #st.sessions == 0 then return end
		st.selected_index = math.max(1, math.min(st.selected_index + delta, #st.sessions))
	end

	function st.partition_sessions()
		local pinned = {}
		local regular = {}
		for _, s in ipairs(st.sessions) do
			if st.is_pinned(s.path) then
				table.insert(pinned, s)
			else
				table.insert(regular, s)
			end
		end
		st.pinned_count = #pinned
		return pinned, regular
	end

	function st.format_session_line(session, sidebar_width)
		local selected_path = st.get_selected_path()
		local is_selected = selected_path == session.path
		local prefix = is_selected and "› " or "  "
		local msg = session.name or session.first_message
		if not msg or msg == "" then msg = "(empty)" end
		if vim.api.nvim_strwidth(msg) > 22 then
			msg = vim.fn.strcharpart(msg, 0, 20) .. "…"
		end

		local age = time_ago(session.modified)
		local count = session.message_count > 0 and tostring(session.message_count) or ""
		local left = prefix .. msg
		local left_w = vim.api.nvim_strwidth(left)
		local right = age .. (count ~= "" and " (" .. count .. ")" or "")
		local right_w = vim.api.nvim_strwidth(right)
		local total_w = sidebar_width - 2
		local spacing = math.max(1, total_w - left_w - right_w)
		local out = left .. string.rep(" ", spacing) .. right

		local highlights = {}
		if is_selected then
			table.insert(highlights, { group = "PiSidebarSelected", col = 0, end_col = -1 })
		end
		if st.is_pinned(session.path) then
			table.insert(highlights, { group = "PiSidebarPinned", col = 2, end_col = 2 + vim.api.nvim_strwidth(msg) })
		end
		local right_start = left_w + spacing
		table.insert(highlights, { group = "PiSidebarTime", col = right_start, end_col = right_start + right_w })

		return { text = out, highlights = highlights }
	end

	function st.delete_selected_file()
		local path = st.get_selected_path()
		if path then
			os.remove(path)
		end
	end

	return st
end

return M

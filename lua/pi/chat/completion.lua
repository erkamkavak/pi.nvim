--- File completion for @ mentions in chat input.
---
--- Uses Neovim's 'completefunc' for native completion integration.
---
--- Inspired by pi-mono's CombinedAutocompleteProvider which handles
--- @file fuzzy completion using fd (source: pi-mono/packages/tui/src/autocomplete.ts).
---
--- Key behaviors (matching pi-mono):
---   - Tab triggers completion when no menu is showing
---   - Tab accepts selected item when menu IS showing
---   - @ auto-triggers completion when typed after whitespace/start of line
---   - Directories listed first, end with /
---   - Supports relative, absolute, and ~/ paths

local M = {}

--- Find the @ prefix before cursor in the current line.
--- Returns the 1-indexed column where @ starts, or nil if not in @ context.
--- @param line string The current line content
--- @param col number 0-indexed byte column of cursor
--- @return number|nil at_col
local function find_at_start(line, col)
	if not line or col <= 0 then return nil end

	local text_before = line:sub(1, col)

	-- Walk backwards from cursor to find @ at a token start
	for i = col, 1, -1 do
		local char = text_before:sub(i, i)

		if char == "@" then
			-- @ must be at start of line or preceded by whitespace
			if i == 1 then
				return i -- 1-indexed column of @
			end
			local prev = text_before:sub(i - 1, i - 1)
			if prev == " " or prev == "\t" then
				return i
			end
			-- @ in middle of a word (e.g. email), not a mention
			return nil
		end

		-- Stop at whitespace (we're in a different token)
		if char == " " or char == "\t" then
			return nil
		end
	end

	return nil
end

--- Resolve a relative/absolute/home path to an absolute path.
local function resolve_path(path, base_dir)
	if path == "" or path == "." then
		return base_dir
	end
	if path:sub(1, 1) == "~" then
		return vim.fn.expand(path)
	end
	if path:sub(1, 1) == "/" then
		return path
	end
	return base_dir .. "/" .. path
end

--- Get the directory part of a path (like POSIX dirname).
local function dirname(path)
	local normalized = path:gsub("\\", "/")
	local dir = normalized:match("^(.*/)[^/]*$")
	return dir or "."
end

--- Get the filename part of a path (like POSIX basename).
local function basename(path)
	local normalized = path:gsub("\\", "/")
	local name = normalized:match(".*/(.*)$")
	return name or path
end

--- Get file/directory completions for a given @path prefix.
--- @param raw_path string The path text after @ (e.g. "src/" or "src/main")
--- @param base_dir string Base directory for relative paths
--- @return table[] Completion items
function M.get_file_completions(raw_path, base_dir)
	local items = {}

	-- Resolve the search directory and prefix
	local search_dir, search_prefix, display_prefix

	if raw_path == "" then
		search_dir = base_dir
		display_prefix = ""
		search_prefix = ""
	elseif raw_path == "/" then
		search_dir = "/"
		display_prefix = "/"
		search_prefix = ""
	elseif raw_path == "./" then
		search_dir = base_dir
		display_prefix = "./"
		search_prefix = ""
	elseif raw_path == "../" then
		search_dir = base_dir .. "/.."
		display_prefix = "../"
		search_prefix = ""
	elseif raw_path == "~" or raw_path == "~/" then
		search_dir = vim.fn.expand("~")
		display_prefix = "~/"
		search_prefix = ""
	elseif raw_path:match("/$") then
		local dir_path = resolve_path(raw_path, base_dir)
		search_dir = dir_path
		search_prefix = ""
		display_prefix = raw_path
	else
		local dir_part = dirname(raw_path)
		local file_part = basename(raw_path)

		if dir_part == "/" then
			search_dir = "/"
			display_prefix = "/"
		else
			local expanded = resolve_path(dir_part == "." and "" or dir_part, base_dir)
			search_dir = expanded
			display_prefix = dir_part ~= "." and (dir_part .. "/") or ""
		end
		search_prefix = file_part
	end

	-- Read directory entries
	local ok, entries = pcall(vim.fn.readdir, search_dir)
	if not ok or type(entries) ~= "table" then
		return items
	end

	-- Cache stat results
	local stat_cache = {}
	local function is_directory(entry)
		local path = search_dir .. "/" .. entry
		if stat_cache[path] ~= nil then
			return stat_cache[path]
		end
		local ok_dir, stat = pcall(vim.loop.fs_stat, path)
		local result = ok_dir and stat and stat.type == "directory"
		stat_cache[path] = result
		return result
	end

	local lower_prefix = search_prefix:lower()

	for _, entry in ipairs(entries) do
		-- Skip hidden files unless prefix starts with dot
		if search_prefix:sub(1, 1) ~= "." and entry:sub(1, 1) == "." then
			goto continue
		end

		-- Case-insensitive prefix matching
		if lower_prefix == "" or entry:sub(1, #search_prefix):lower() == lower_prefix then
			local is_dir = is_directory(entry)
			local word = entry .. (is_dir and "/" or "")

			-- Build display path for the menu
			local display_path = display_prefix ~= "" and (display_prefix .. word) or word

			-- The word includes @ prefix so Neovim replaces correctly.
			-- e.g. user typed "@src/ma", we return "@src/main.ts" as word.
			table.insert(items, {
				word = "@" .. display_path,
				abbr = word,
				menu = display_path,
				icase = 1,
				dup = 1,
			})
		end

		::continue::
	end

	-- Sort: directories first, then alphabetically
	table.sort(items, function(a, b)
		local a_is_dir = a.abbr:match("/$") ~= nil
		local b_is_dir = b.abbr:match("/$") ~= nil
		if a_is_dir and not b_is_dir then return true end
		if not a_is_dir and b_is_dir then return false end
		return a.abbr:lower() < b.abbr:lower()
	end)

	return items
end

--- completefunc handler. Called by Neovim with (findstart, base).
--- Set via: vim.bo.completefunc = 'v:lua.require("pi.chat.completion").completefunc'
---
--- When findstart == 1: return the column (1-indexed) where completion starts,
--- or -1 to cancel.
--- When findstart == 0: return a list of completion items for the given base.
---
--- @param findstart number|string
--- @param base string
--- @return number|table
function M.completefunc(findstart, base)
	if findstart == 1 then
		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-indexed
		local at_col = find_at_start(line, col)
		if at_col then
			return at_col -- 1-indexed column of @
		end
		return -1 -- no completion
	end

	-- findstart == 0: return matching items
	-- base includes the @ prefix, e.g. "@src/ma"
	local raw_path = base:sub(2) -- strip leading @
	local base_dir = vim.fn.getcwd()
	return M.get_file_completions(raw_path, base_dir)
end

--- Feed keys to trigger completion (used by Tab keymap and auto-trigger).
local function feed_completion_keys()
	local term = vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true)
	vim.api.nvim_feedkeys(term, "n", false)
end

--- Set up @ completion for a given buffer.
--- @param buf number Buffer handle
function M.setup(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

	-- Set completefunc
	vim.api.nvim_buf_set_option(buf, "completefunc", "v:lua.require('pi.chat.completion').completefunc")

	-- Create augroup
	local augroup = "pi_completion_" .. buf
	pcall(vim.api.nvim_del_augroup_by_name, augroup)
	local group_id = vim.api.nvim_create_augroup(augroup, { clear = true })

	-- Store group_id on the module for teardown
	M._augroups = M._augroups or {}
	M._augroups[buf] = group_id

	-- Auto-trigger: when @ is typed (cursor right after @, no completion showing)
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = group_id,
		buffer = buf,
		callback = function()
			if vim.fn.pumvisible() == 1 then return end

			local line = vim.api.nvim_get_current_line()
			local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-indexed
			if col <= 0 then return end

			-- Trigger only when the character right before cursor is @
			-- and it's at a word boundary
			local char_before = line:sub(col, col)
			if char_before ~= "@" then return end

			local at_col = find_at_start(line, col)
			if not at_col then return end

			-- Defer slightly so the @ is fully in the buffer before triggering
			vim.defer_fn(function()
				-- Guard: still in same buf, still in insert mode, still at @ context
				if vim.api.nvim_get_current_buf() ~= buf then return end
				if vim.fn.mode() ~= "i" then return end
				if vim.fn.pumvisible() == 1 then return end

				local cur_line = vim.api.nvim_get_current_line()
				local cur_col = vim.api.nvim_win_get_cursor(0)[2]
				if cur_col <= 0 then return end
				if cur_line:sub(cur_col, cur_col) ~= "@" then return end

				feed_completion_keys()
			end, 10)
		end,
	})
end

--- Tear down @ completion for a given buffer.
--- @param buf number Buffer handle
function M.teardown(buf)
	if not buf then return end
	if M._augroups and M._augroups[buf] then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroups[buf])
		M._augroups[buf] = nil
	end
end

return M

--- Image preview window for the chat input.
--- Shows an ANSI-rendered preview of a clipboard image using chafa.
--- The preview renders as a non-focusable floating window above the input.

local M = {}

local preview_buf = nil
local preview_win = nil
local preview_path = nil
local hl_cache = {}
local hl_counter = 0

local MAX_HEIGHT = 12

--- Parse ANSI true-color escape sequences from chafa output.
--- chafa with --colors=full outputs sequences like:
---   ESC[38;2;R;G;Bm  (foreground = top half of pixel)
---   ESC[48;2;R;G;Bm  (background = bottom half of pixel)
---   ESC[0m            (reset)
--- Returns a list of lines, each line being a list of segments:
---   { char = "...", fg = {r,g,b}|nil, bg = {r,g,b}|nil }
local function parse_chafa_output(output)
	if type(output) ~= "string" or output == "" then return {} end

	local lines = {}
	for line in vim.gsplit(output, "\n", { plain = true, trimempty = false }) do
		if line == "" then
			table.insert(lines, {})
		else
			local parsed = {}
			local fg, bg = nil, nil
			local i = 1

			while i <= #line do
				local byte = line:byte(i)

				if byte == 27 and i < #line and line:byte(i + 1) == 91 then
					-- ANSI escape: ESC[
					local seq_end = line:find("m", i + 2)
					if seq_end then
						local params = line:sub(i + 2, seq_end - 1)
						if params ~= "" then
							local parts = vim.split(params, ";")
							local j = 1
							while j <= #parts do
								if parts[j] == "0" then
									fg, bg = nil, nil
									j = j + 1
								elseif parts[j] == "1" or parts[j] == "22" or parts[j] == "27" then
									-- bold/normal/reverse, ignore
									j = j + 1
								elseif parts[j] == "38" and j + 4 <= #parts and parts[j + 1] == "2" then
									fg = { tonumber(parts[j + 2]), tonumber(parts[j + 3]), tonumber(parts[j + 4]) }
									j = j + 5
								elseif parts[j] == "48" and j + 4 <= #parts and parts[j + 1] == "2" then
									bg = { tonumber(parts[j + 2]), tonumber(parts[j + 3]), tonumber(parts[j + 4]) }
									j = j + 5
								else
									j = j + 1
								end
							end
						end
						i = seq_end + 1
					else
						i = i + 1
					end
				else
					-- Regular UTF-8 character
					local char_len = 1
					if byte >= 240 then
						char_len = 4
					elseif byte >= 224 then
						char_len = 3
					elseif byte >= 192 then
						char_len = 2
					end
					local char = line:sub(i, i + char_len - 1)
					-- Copy color tuples so they aren't shared references
					table.insert(parsed, {
						char = char,
						fg = fg and { fg[1], fg[2], fg[3] } or nil,
						bg = bg and { bg[1], bg[2], bg[3] } or nil,
					})
					i = i + char_len
				end
			end
			table.insert(lines, parsed)
		end
	end

	return lines
end

--- Get or create a Neovim highlight group for the given fg/bg colors.
--- Uses both foreground (top half of pixel) and background (bottom half of pixel)
--- to render chafa's half-block characters at 2x vertical resolution.
local function get_or_create_hl(fg, bg)
	local fg_key = fg and string.format("F%d,%d,%d", fg[1], fg[2], fg[3]) or "Fnil"
	local bg_key = bg and string.format("B%d,%d,%d", bg[1], bg[2], bg[3]) or "Bnil"
	local key = fg_key .. "_" .. bg_key
	if hl_cache[key] then
		return hl_cache[key]
	end

	hl_counter = hl_counter + 1
	local hl_name = "PiImgPrev_" .. hl_counter
	local hl_opts = {}
	if fg then
		hl_opts.fg = string.format("#%02x%02x%02x", fg[1], fg[2], fg[3])
	end
	if bg then
		hl_opts.bg = string.format("#%02x%02x%02x", bg[1], bg[2], bg[3])
	end
	vim.api.nvim_set_hl(0, hl_name, hl_opts)
	hl_cache[key] = hl_name
	return hl_name
end

--- Remove all dynamically-created highlight groups.
local function cleanup_hl_groups()
	for _, hl_name in pairs(hl_cache) do
		pcall(vim.api.nvim_set_hl, 0, hl_name, {})
	end
	hl_cache = {}
	hl_counter = 0
end

--- Open an image preview floating window above the parent window.
--- @param image_path string Path to the image file
--- @param opts table|nil Options: { parent_win = integer }
--- @return boolean success
function M.open(image_path, opts)
	M.close()
	opts = opts or {}

	-- chafa is optional; fall back silently
	if vim.fn.executable("chafa") ~= 1 then
		return false
	end
	if not image_path or vim.fn.filereadable(image_path) ~= 1 then
		return false
	end

	local parent_win = opts.parent_win
	if not parent_win or not vim.api.nvim_win_is_valid(parent_win) then
		return false
	end

	preview_path = image_path

	local parent_width = vim.api.nvim_win_get_width(parent_win)
	-- Leave 2 cols for the preview window border
	local chafa_width = math.max(16, parent_width - 2)
	chafa_width = math.min(chafa_width, 80)

	-- Run chafa to convert image to ANSI block art
	local cmd = string.format(
		"chafa --symbols=block --colors=full --color-space=rgb --size=%dx%d %s 2>/dev/null",
		chafa_width, MAX_HEIGHT, vim.fn.shellescape(image_path)
	)
	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 or output == "" then
		return false
	end

	local parsed_lines = parse_chafa_output(output)
	if #parsed_lines == 0 then
		return false
	end

	-- Trim empty trailing lines
	while #parsed_lines > 0 and #parsed_lines[#parsed_lines] == 0 do
		table.remove(parsed_lines)
	end
	if #parsed_lines == 0 then
		return false
	end

	local height = math.min(#parsed_lines, MAX_HEIGHT)
	local width = parent_width

	-- Create scratch buffer
	preview_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(preview_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(preview_buf, "modifiable", true)

	-- Fill buffer lines, padding to full width
	local buf_lines = {}
	for i = 1, height do
		local segs = {}
		local parsed = parsed_lines[i] or {}
		for _, seg in ipairs(parsed) do
			table.insert(segs, seg.char)
		end
		local line = table.concat(segs)
		-- Pad to display width with spaces; chafa output may use multibyte blocks.
		local line_width = vim.fn.strdisplaywidth(line)
		if line_width < width then
			line = line .. string.rep(" ", width - line_width)
		end
		table.insert(buf_lines, line)
	end
	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, buf_lines)
	vim.api.nvim_buf_set_option(preview_buf, "modifiable", false)

	-- Apply foreground/background highlights per character
	for i = 1, height do
		local parsed = parsed_lines[i] or {}
		local col = 0
		for _, seg in ipairs(parsed) do
			if seg.fg or seg.bg then
				local hl_name = get_or_create_hl(seg.fg, seg.bg)
				local end_col = col + vim.fn.strdisplaywidth(seg.char)
				pcall(vim.api.nvim_buf_add_highlight, preview_buf, -1, hl_name, i - 1, col, end_col)
			end
			col = col + vim.fn.strdisplaywidth(seg.char)
		end
	end

	-- Position above the parent (input) window
	local parent_pos = vim.api.nvim_win_get_position(parent_win)
	local parent_row = parent_pos[1]
	local parent_col = parent_pos[2]

	preview_win = vim.api.nvim_open_win(preview_buf, false, {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, parent_row - height - 2),
		col = parent_col,
		border = "single",
		title = " image ",
		title_pos = "left",
		focusable = false,
		noautocmd = true,
	})

	return true
end

--- Close the preview window and clean up resources.
function M.close()
	if preview_win and vim.api.nvim_win_is_valid(preview_win) then
		vim.api.nvim_win_close(preview_win, true)
	end
	if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
		vim.api.nvim_buf_delete(preview_buf, { force = true })
	end
	preview_win = nil
	preview_buf = nil
	preview_path = nil
	cleanup_hl_groups()
end

--- Check if the preview is currently open.
function M.is_open()
	return preview_win ~= nil and vim.api.nvim_win_is_valid(preview_win)
end

--- Reposition the preview window (e.g., on relayout).
--- @param parent_win integer The input window handle
function M.reposition(parent_win)
	if not M.is_open() then return end
	if not parent_win or not vim.api.nvim_win_is_valid(parent_win) then
		M.close()
		return
	end

	local parent_pos = vim.api.nvim_win_get_position(parent_win)
	local parent_width = vim.api.nvim_win_get_width(parent_win)
	local parent_row = parent_pos[1]
	local parent_col = parent_pos[2]
	local height = vim.api.nvim_win_get_height(preview_win)

	vim.api.nvim_win_set_config(preview_win, {
		relative = "editor",
		width = parent_width,
		height = height,
		row = math.max(0, parent_row - height - 2),
		col = parent_col,
	})
end

return M

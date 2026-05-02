local M = {}

local palette_buf = nil
local palette_win = nil
local palette_ns = vim.api.nvim_create_namespace("pi_chat_palette")
local palette_items = {}
local palette_selected_idx = 1

M.COMMAND_ITEMS = {
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

function M.is_open()
	return palette_win and vim.api.nvim_win_is_valid(palette_win) or false
end

function M.get_window()
	return palette_win
end

function M.close()
	if palette_win and vim.api.nvim_win_is_valid(palette_win) then
		vim.api.nvim_win_close(palette_win, true)
	end
	palette_win = nil
	palette_buf = nil
	palette_items = {}
	palette_selected_idx = 1
end

local function render()
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

local function move_selection(delta)
	if #palette_items == 0 then return end
	palette_selected_idx = math.max(1, math.min(#palette_items, palette_selected_idx + delta))
	render()
end

local function execute_item(item, ctx)
	if not item then return end
	M.close()

	local command = item.command
	if item.prompt then
		ctx.with_focus_lock_suspended(function()
			vim.ui.input({ prompt = item.prompt .. ": " }, function(value)
				if value == nil then return end
				local v = value:gsub("^%s+", ""):gsub("%s+$", "")
				if command == "/import" and v == "" then
					vim.notify("pi: import path is required", vim.log.levels.WARN)
					return
				end
				if v ~= "" then
					ctx.run_slash_command(command .. " " .. v)
				else
					ctx.run_slash_command(command)
				end
			end)
		end)
		return
	end
	ctx.run_slash_command(command)
end

--- Open/toggle the command palette.
--- @param ctx { ensure_focus_lock_autocmd: fun(), with_focus_lock_suspended: fun(function), map_window_stay_keys: fun(integer), run_slash_command: fun(string) }
function M.open(ctx)
	ctx.ensure_focus_lock_autocmd()
	if M.is_open() then
		M.close()
		return
	end

	palette_items = vim.deepcopy(M.COMMAND_ITEMS)
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
	vim.keymap.set("n", "q", function() M.close() end, km)
	vim.keymap.set("n", "<Esc>", function() M.close() end, km)
	vim.keymap.set("n", "j", function() move_selection(1) end, km)
	vim.keymap.set("n", "<Down>", function() move_selection(1) end, km)
	vim.keymap.set("n", "k", function() move_selection(-1) end, km)
	vim.keymap.set("n", "<Up>", function() move_selection(-1) end, km)
	vim.keymap.set("n", "<CR>", function()
		execute_item(palette_items[palette_selected_idx], ctx)
	end, km)

	for idx, item in ipairs(palette_items) do
		vim.keymap.set("n", item.key, function()
			palette_selected_idx = idx
			execute_item(item, ctx)
		end, km)
	end

	ctx.map_window_stay_keys(palette_buf)
	render()
end

return M

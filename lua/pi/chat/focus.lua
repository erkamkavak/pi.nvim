local M = {}

local pause_count = 0
local last_pi_focus_win = nil
local lock_group = vim.api.nvim_create_augroup("PiFocusLock", { clear = true })
local lock_registered = false

function M.is_pi_buffer(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
	local name = vim.api.nvim_buf_get_name(buf) or ""
	if name:sub(1, 5) == "pi://" then return true end
	local ft = vim.api.nvim_buf_get_option(buf, "filetype") or ""
	if ft:sub(1, 3) == "pi-" then return true end
	return false
end

function M.is_pi_window(win)
	if not win or not vim.api.nvim_win_is_valid(win) then return false end
	return M.is_pi_buffer(vim.api.nvim_win_get_buf(win))
end

function M.list_pi_windows()
	local wins = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if M.is_pi_window(win) then
			table.insert(wins, win)
		end
	end
	table.sort(wins, function(a, b) return a < b end)
	return wins
end

function M.with_lock_suspended(fn)
	pause_count = pause_count + 1
	local ok, res = pcall(fn)
	pause_count = math.max(0, pause_count - 1)
	if not ok then error(res) end
	return res
end

local function preferred_pi_focus_window(ctx)
	local palette_win = ctx.get_palette_window and ctx.get_palette_window() or nil
	if palette_win and vim.api.nvim_win_is_valid(palette_win) then return palette_win end
	if last_pi_focus_win and vim.api.nvim_win_is_valid(last_pi_focus_win) and M.is_pi_window(last_pi_focus_win) then
		return last_pi_focus_win
	end
	local input_win = ctx.get_input_window and ctx.get_input_window() or nil
	if input_win and vim.api.nvim_win_is_valid(input_win) then return input_win end
	local chat_win = ctx.get_chat_window and ctx.get_chat_window() or nil
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then return chat_win end
	local wins = M.list_pi_windows()
	return wins[1]
end

function M.ensure_lock(ctx)
	if lock_registered then return end
	lock_registered = true
	vim.api.nvim_create_autocmd("WinEnter", {
		group = lock_group,
		callback = function()
			if pause_count > 0 then return end
			local pi_wins = M.list_pi_windows()
			if #pi_wins == 0 then return end

			local cur = vim.api.nvim_get_current_win()
			if M.is_pi_window(cur) then
				last_pi_focus_win = cur
				return
			end

			local target = preferred_pi_focus_window(ctx)
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
	local pi_wins = M.list_pi_windows()
	if #pi_wins == 0 then return end
	local cur = vim.api.nvim_get_current_win()
	local idx = 1
	for i, win in ipairs(pi_wins) do
		if win == cur then idx = i break end
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

function M.map_window_stay_keys(buf)
	local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
	local next_fn = function() cycle_pi_window(1) end
	local prev_fn = function() cycle_pi_window(-1) end
	local first_fn = function()
		local pi_wins = M.list_pi_windows()
		if #pi_wins == 0 then return end
		vim.api.nvim_set_current_win(pi_wins[1])
		last_pi_focus_win = pi_wins[1]
	end
	local last_fn = function()
		local pi_wins = M.list_pi_windows()
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

local function find_preferred_editor_window()
	local cur = vim.api.nvim_get_current_win()
	if is_normal_editor_window(cur) then
		local buf = vim.api.nvim_win_get_buf(cur)
		if buf and vim.api.nvim_buf_is_valid(buf) then
			local ft = vim.api.nvim_buf_get_option(buf, "filetype") or ""
			local bt = vim.api.nvim_buf_get_option(buf, "buftype") or ""
			if not EXCLUDED_EDITOR_FILETYPES[ft] and not EXCLUDED_EDITOR_BUFTYPES[bt] then
				return cur
			end
		end
	end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_normal_editor_window(win) then
			local buf = vim.api.nvim_win_get_buf(win)
			if buf and vim.api.nvim_buf_is_valid(buf) then
				local ft = vim.api.nvim_buf_get_option(buf, "filetype") or ""
				local bt = vim.api.nvim_buf_get_option(buf, "buftype") or ""
				if not EXCLUDED_EDITOR_FILETYPES[ft] and not EXCLUDED_EDITOR_BUFTYPES[bt] then
					vim.api.nvim_set_current_win(win)
					return win
				end
			end
		end
	end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_normal_editor_window(win) then
			vim.api.nvim_set_current_win(win)
			return win
		end
	end

	vim.cmd("botright split")
	return vim.api.nvim_get_current_win()
end

function M.with_main_window_focus(fn)
	local win = find_preferred_editor_window()
	if win and vim.api.nvim_win_is_valid(win) then
		M.with_lock_suspended(function()
			vim.api.nvim_win_call(win, fn)
		end)
	else
		M.with_lock_suspended(fn)
	end
end

return M

local config = require("pi.config")
local client = require("pi.client")
local ui = require("pi.util.ui")
local store_mod = require("pi.sidebar.store")
local view = require("pi.sidebar.view")

local M = {}

local sidebar_buf = nil
local sidebar_win = nil
local store = store_mod.new(config)

local function run_refresh(cwd)
	store.load_pinned()
	store.scan_sessions(cwd or vim.fn.getcwd())
	store.ensure_initial_selection()
	local seq = store.bump_refresh_seq()
	store.enrich_sessions(
		seq,
		function()
			if sidebar_buf and vim.api.nvim_buf_is_valid(sidebar_buf) then
				vim.schedule(function()
					if seq == store.refresh_seq then
						M.render()
					end
				end)
			end
		end,
		function()
			vim.schedule(function()
				if seq == store.refresh_seq then
					M.render()
				end
			end)
		end
	)
end

function M.open(cwd)
	if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
		M.refresh(cwd)
		return
	end

	run_refresh(cwd)

	sidebar_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(sidebar_buf, "pi://sessions")
	vim.api.nvim_buf_set_option(sidebar_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(sidebar_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(sidebar_buf, "filetype", "pi-sidebar")

	local width = config.options.sidebar_width
	local mx, my = ui.get_margins(config)
	local height = math.max(8, vim.o.lines - 1 - (my * 2))
	sidebar_win = vim.api.nvim_open_win(sidebar_buf, true, {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = my,
		col = mx,
		border = "single",
	})

	M._set_keymaps()
	M.render()
end

function M.is_open()
	return sidebar_win ~= nil and vim.api.nvim_win_is_valid(sidebar_win)
end

function M.focus()
	if M.is_open() then
		vim.api.nvim_set_current_win(sidebar_win)
	end
end

function M.close()
	if M.is_open() then
		vim.api.nvim_win_close(sidebar_win, true)
		sidebar_win = nil
	end
end

function M.toggle(cwd)
	if M.is_open() then
		M.close()
	else
		M.open(cwd)
	end
end

function M.refresh(cwd)
	run_refresh(cwd)
end

function M.render()
	if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then return end
	view.render(sidebar_buf, sidebar_win, store, config)
end

function M.get_selected_path()
	return store.get_selected_path()
end

function M.select_session()
	local path = store.get_selected_path()
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

function M._set_keymaps()
	local opts = { buffer = sidebar_buf, noremap = true, silent = true }

	vim.keymap.set("n", config.options.keymaps.sidebar_select, function()
		M.select_session()
	end, opts)

	vim.keymap.set("n", config.options.keymaps.sidebar_toggle_pin, function()
		store.toggle_pin_selected()
		M.render()
	end, opts)

	vim.keymap.set("n", config.options.keymaps.sidebar_delete, function()
		local ok = vim.fn.confirm("Delete this session?", "&Yes\n&No")
		if ok == 1 then
			store.delete_selected_file()
			vim.notify("pi: session deleted", vim.log.levels.INFO)
			M.refresh()
		end
	end, opts)

	vim.keymap.set("n", config.options.keymaps.sidebar_rename, function()
		local path = store.get_selected_path()
		if not path then return end
		vim.ui.input({ prompt = "Session name: " }, function(name)
			if name and name ~= "" then
				client.set_session_name(name)
				vim.notify("pi: session renamed", vim.log.levels.INFO)
				M.refresh()
			end
		end)
	end, opts)

	local function move(delta)
		store.move_selection(delta)
		M.render()
	end

	vim.keymap.set("n", "<Down>", function() move(1) end, opts)
	vim.keymap.set("n", "j", function() move(1) end, opts)
	vim.keymap.set("n", "<Up>", function() move(-1) end, opts)
	vim.keymap.set("n", "k", function() move(-1) end, opts)

	vim.keymap.set("n", "<C-l>", function()
		require("pi.chat").focus()
	end, opts)
	vim.keymap.set("n", "<Right>", function()
		require("pi.chat").focus()
	end, opts)

	vim.keymap.set("n", "q", function()
		M.close()
		require("pi.chat").close()
	end, opts)
end

vim.api.nvim_create_autocmd("User", {
	pattern = "PiSessionChanged",
	callback = function()
		if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
			M.refresh()
		end
	end,
})

return M

local config = require("pi.config")
local client = require("pi.client")
local extract = require("pi.changes.extract")
local render = require("pi.changes.render")
local ui = require("pi.util.ui")

local M = {}

local changes_buf = nil
local changes_win = nil
local diff_popup_buf = nil
local diff_popup_win = nil
local is_open = false
local panel_mode = "summary" -- "summary" | "diff"
local current_diff = nil

local function footer_text()
	if panel_mode == "diff" then
		return " [=/-] zoom  [0] reset  [z] popup  [t] last turn  [q] close "
	end
	return " [=/-] zoom  [0] reset  [q] close panel  [r] refresh "
end

local function apply_footer()
	if not changes_win or not vim.api.nvim_win_is_valid(changes_win) then return end
	local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, changes_win)
	if not ok_cfg or type(cfg) ~= "table" then return end
	cfg.footer = footer_text()
	cfg.footer_pos = "left"
	pcall(vim.api.nvim_win_set_config, changes_win, cfg)
end

local function panel_width()
	return math.max((config.options.changes_width or 50) - 2, 20)
end

local function clamp_width(width)
	local min_width = tonumber(config.options.changes_width_min) or 30
	local max_width = tonumber(config.options.changes_width_max) or 120
	local editor_max = math.max(20, vim.o.columns - 4)
	max_width = math.min(max_width, editor_max)
	if max_width < min_width then min_width = max_width end
	return math.max(min_width, math.min(math.floor(width or config.options.changes_width or 50), max_width))
end

local function resize_and_rerender()
	if not changes_win or not vim.api.nvim_win_is_valid(changes_win) then return end
	config.options.changes_width = clamp_width(config.options.changes_width)
	local width = config.options.changes_width
	local mx, my = ui.get_margins(config)
	local col = math.max(0, vim.o.columns - mx - width)
	local height = math.max(8, vim.o.lines - 1 - (my * 2))
	local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, changes_win)
	if not ok_cfg or type(cfg) ~= "table" then return end
	cfg.relative = "editor"
	cfg.width = width
	cfg.height = height
	cfg.row = my
	cfg.col = col
	cfg.footer = footer_text()
	cfg.footer_pos = "left"
	pcall(vim.api.nvim_win_set_config, changes_win, cfg)
	M.refresh()
	local ok_chat, chat = pcall(require, "pi.chat")
	if ok_chat and chat and chat.relayout then chat.relayout() end
end

local function close_diff_popup()
	if diff_popup_win and vim.api.nvim_win_is_valid(diff_popup_win) then
		vim.api.nvim_win_close(diff_popup_win, true)
	end
	diff_popup_win = nil
	diff_popup_buf = nil
end

local function render_summary_response(response)
	if not response or not response.success or not response.data then
		return
	end
	local messages = response.data.messages or {}
	if #messages == 0 then
		render.empty(changes_buf, "  (no messages yet)")
		return
	end
	local last_turn = extract.last_turn(messages)
	if not last_turn then
		render.empty(changes_buf, "  (no user messages yet)")
		return
	end
	render.summary(changes_buf, panel_width(), last_turn)
end

function M.open()
	if changes_win and vim.api.nvim_win_is_valid(changes_win) then
		apply_footer()
		local ok_chat, chat = pcall(require, "pi.chat")
		if ok_chat and chat and chat.relayout then chat.relayout() end
		return
	end

	changes_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(changes_buf, "pi://changes")
	vim.api.nvim_buf_set_option(changes_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(changes_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(changes_buf, "filetype", "pi-changes")

	local width = clamp_width(config.options.changes_width)
	config.options.changes_width = width
	local mx, my = ui.get_margins(config)
	local col = vim.o.columns - mx - width
	local height = math.max(8, vim.o.lines - 1 - (my * 2))

	changes_win = vim.api.nvim_open_win(changes_buf, false, {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = my,
		col = col,
		border = "single",
	})

	is_open = true
	apply_footer()
	local ok_chat, chat = pcall(require, "pi.chat")
	if ok_chat and chat and chat.relayout then chat.relayout() end

	local km = { buffer = changes_buf, noremap = true, silent = true }
	vim.keymap.set("n", config.options.keymaps.changes_toggle, function() M.toggle() end, km)
	vim.keymap.set("n", "q", function() M.close() end, km)
	vim.keymap.set("n", "<Esc>", function()
		if panel_mode == "diff" then M.show_last_turn() else M.close() end
	end, km)
	vim.keymap.set("n", "r", function() M.refresh() end, km)
	vim.keymap.set("n", "t", function() M.show_last_turn() end, km)
	vim.keymap.set("n", config.options.keymaps.changes_zoom_in or "=", function() M.zoom_in() end, km)
	vim.keymap.set("n", config.options.keymaps.changes_zoom_out or "-", function() M.zoom_out() end, km)
	vim.keymap.set("n", config.options.keymaps.changes_zoom_reset or "0", function() M.zoom_reset() end, km)
	vim.keymap.set("n", config.options.keymaps.changes_diff_popup or "z", function() M.open_diff_popup() end, km)
	vim.keymap.set("n", "<C-h>", function() require("pi.chat").focus() end, km)
	vim.keymap.set("n", "<Left>", function() require("pi.chat").focus() end, km)

	client.on_event("agent_end", function()
		vim.schedule(function() M.refresh() end)
	end)

	M.show_last_turn()
end

function M.close()
	close_diff_popup()
	if changes_win and vim.api.nvim_win_is_valid(changes_win) then
		vim.api.nvim_win_close(changes_win, true)
		changes_win = nil
	end
	is_open = false
	local ok_chat, chat = pcall(require, "pi.chat")
	if ok_chat and chat and chat.relayout then chat.relayout() end
end

function M.toggle()
	if is_open then M.close() else M.open() end
end

function M.is_open()
	return is_open
end

function M.zoom_in()
	if not is_open then return end
	local step = tonumber(config.options.changes_zoom_step) or 5
	config.options.changes_width = clamp_width((config.options.changes_width or 50) + step)
	resize_and_rerender()
end

function M.zoom_out()
	if not is_open then return end
	local step = tonumber(config.options.changes_zoom_step) or 5
	config.options.changes_width = clamp_width((config.options.changes_width or 50) - step)
	resize_and_rerender()
end

function M.zoom_reset()
	if not is_open then return end
	config.options.changes_width = clamp_width(config.defaults and config.defaults.changes_width or 50)
	resize_and_rerender()
end

function M.focus()
	if changes_win and vim.api.nvim_win_is_valid(changes_win) then
		vim.api.nvim_set_current_win(changes_win)
	end
end

function M.refresh()
	if not changes_buf or not vim.api.nvim_buf_is_valid(changes_buf) then return end

	if panel_mode == "diff" then
		if current_diff and current_diff.text then
			render.diff(changes_buf, panel_width(), current_diff)
		end
		return
	end

	if not client.is_running() then return end

	client.get_messages(function(response)
		vim.schedule(function()
			if not changes_buf or not vim.api.nvim_buf_is_valid(changes_buf) then return end
			if panel_mode ~= "summary" then
				if current_diff and current_diff.text then
					render.diff(changes_buf, panel_width(), current_diff)
				end
				return
			end
			render_summary_response(response)
		end)
	end)
end

function M.show_last_turn()
	panel_mode = "summary"
	current_diff = nil
	apply_footer()
	M.refresh()
end

--- @param diff { title?: string, text: string, source?: string, tool?: string }
function M.show_diff(diff)
	if not diff or type(diff.text) ~= "string" or diff.text == "" then
		vim.notify("pi: no diff available for this tool call", vim.log.levels.INFO)
		return
	end

	if not is_open then
		M.open()
	end
	if changes_win and vim.api.nvim_win_is_valid(changes_win) then
		local cfg = vim.api.nvim_win_get_config(changes_win)
		vim.api.nvim_win_set_config(changes_win, cfg)
	end

	panel_mode = "diff"
	current_diff = {
		title = diff.title or "Diff",
		text = diff.text,
		source = diff.source,
		tool = diff.tool,
	}
	apply_footer()
	render.diff(changes_buf, panel_width(), current_diff)
end

function M.open_diff_popup()
	if not current_diff or type(current_diff.text) ~= "string" or current_diff.text == "" then
		vim.notify("pi: no diff open to expand", vim.log.levels.INFO)
		return
	end
	if diff_popup_win and vim.api.nvim_win_is_valid(diff_popup_win) then
		vim.api.nvim_set_current_win(diff_popup_win)
		return
	end

	diff_popup_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(diff_popup_buf, "pi://diff-popup")
	vim.api.nvim_buf_set_option(diff_popup_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(diff_popup_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(diff_popup_buf, "filetype", "pi-changes")

	local mx, my = ui.get_margins(config)
	local width = math.max(40, vim.o.columns - (mx * 2) - 6)
	local height = math.max(10, vim.o.lines - 1 - (my * 2) - 2)
	diff_popup_win = vim.api.nvim_open_win(diff_popup_buf, true, {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = my + 1,
		col = mx + 3,
		border = "single",
		title = " pi diff ",
		footer = " [q/Esc] close ",
		footer_pos = "left",
	})

	local km = { buffer = diff_popup_buf, noremap = true, silent = true }
	vim.keymap.set("n", "q", close_diff_popup, km)
	vim.keymap.set("n", "<Esc>", close_diff_popup, km)
	render.diff(diff_popup_buf, math.max(width - 2, 20), current_diff)
end

vim.api.nvim_create_autocmd("User", {
	pattern = "PiSessionChanged",
	callback = function()
		if is_open and changes_win and vim.api.nvim_win_is_valid(changes_win) then
			M.refresh()
		end
	end,
})

return M

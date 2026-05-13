local git = require("pi.util.git")

local M = {}

function M.new_state()
	return {
		tool_nav_mode = false,
		rendered_tool_entries = {},
		selected_tool_idx = nil,
		selected_tool_id = nil,
	}
end

function M.set_entries(state, entries)
	state.rendered_tool_entries = entries or {}
	if #state.rendered_tool_entries == 0 then
		state.selected_tool_idx = nil
		state.selected_tool_id = nil
		return
	end
	if state.selected_tool_id then
		for idx, entry in ipairs(state.rendered_tool_entries) do
			if entry.id == state.selected_tool_id then
				state.selected_tool_idx = idx
				break
			end
		end
	end
	state.selected_tool_idx = math.min(math.max(state.selected_tool_idx or 1, 1), #state.rendered_tool_entries)
	state.selected_tool_id = state.rendered_tool_entries[state.selected_tool_idx].id
end

function M.get_entries(state)
	return state.rendered_tool_entries
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

local function is_bash_tool(name)
	local n = type(name) == "string" and name:lower() or ""
	return n == "bash"
end

local function get_selected_tool_entry(state)
	if state.selected_tool_idx and state.rendered_tool_entries[state.selected_tool_idx] then
		return state.rendered_tool_entries[state.selected_tool_idx]
	end
	if #state.rendered_tool_entries == 0 then
		return nil
	end
	return state.rendered_tool_entries[1]
end

local function find_closest_tool_idx_to_cursor(state, chat_win)
	if #state.rendered_tool_entries == 0 or not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
		return nil
	end
	local cursor_row = vim.api.nvim_win_get_cursor(chat_win)[1] - 1
	local best_idx = 1
	local best_dist = math.huge
	for idx, entry in ipairs(state.rendered_tool_entries) do
		local dist = math.abs((entry.line or 0) - cursor_row)
		if dist < best_dist then
			best_dist = dist
			best_idx = idx
		end
	end
	return best_idx
end

function M.apply_selection_visual(state, chat_buf, chat_win, chat_sel_ns)
	if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then return end
	vim.api.nvim_buf_clear_namespace(chat_buf, chat_sel_ns, 0, -1)
	if not state.tool_nav_mode then return end
	if not state.selected_tool_idx or not state.rendered_tool_entries[state.selected_tool_idx] then return end
	local row = state.rendered_tool_entries[state.selected_tool_idx].line
	vim.api.nvim_buf_add_highlight(chat_buf, chat_sel_ns, "PiToolCallSelected", row, 0, -1)
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		vim.api.nvim_win_set_cursor(chat_win, { row + 1, 0 })
	end
end

function M.is_mode(state)
	return state.tool_nav_mode
end

function M.toggle_mode(state, chat_buf, chat_win, chat_sel_ns)
	state.tool_nav_mode = not state.tool_nav_mode
	if state.tool_nav_mode then
		local idx = find_closest_tool_idx_to_cursor(state, chat_win)
		if idx then
			state.selected_tool_idx = idx
			state.selected_tool_id = state.rendered_tool_entries[idx].id
		else
			state.selected_tool_idx = nil
			state.selected_tool_id = nil
		end
		M.apply_selection_visual(state, chat_buf, chat_win, chat_sel_ns)
	else
		if chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
			vim.api.nvim_buf_clear_namespace(chat_buf, chat_sel_ns, 0, -1)
		end
	end
	vim.notify("pi: tool navigation " .. (state.tool_nav_mode and "enabled" or "disabled"), vim.log.levels.INFO)
end

local function jump_to_idx(state, idx, chat_buf, chat_win, chat_sel_ns)
	if not idx or not state.rendered_tool_entries[idx] then return end
	state.selected_tool_idx = idx
	state.selected_tool_id = state.rendered_tool_entries[idx].id
	M.apply_selection_visual(state, chat_buf, chat_win, chat_sel_ns)
end

function M.select_next(state, chat_buf, chat_win, chat_sel_ns)
	if #state.rendered_tool_entries == 0 then
		vim.notify("pi: no tool calls in view", vim.log.levels.INFO)
		return
	end
	local next_idx = state.selected_tool_idx and math.min(state.selected_tool_idx + 1, #state.rendered_tool_entries) or 1
	jump_to_idx(state, next_idx, chat_buf, chat_win, chat_sel_ns)
end

function M.select_prev(state, chat_buf, chat_win, chat_sel_ns)
	if #state.rendered_tool_entries == 0 then
		vim.notify("pi: no tool calls in view", vim.log.levels.INFO)
		return
	end
	local prev_idx = state.selected_tool_idx and math.max(state.selected_tool_idx - 1, 1) or 1
	jump_to_idx(state, prev_idx, chat_buf, chat_win, chat_sel_ns)
end

function M.open_selected_file(state, opts)
	local entry = get_selected_tool_entry(state)
	if not entry then
		vim.notify("pi: no tool call selected", vim.log.levels.INFO)
		return
	end
	local name = type(entry.name) == "string" and entry.name:lower() or ""
	if name == "thinking" then
		return
	end
	local abs_path = resolve_tool_file_path(entry)
	if not abs_path then
		vim.notify("pi: selected tool call has no file path", vim.log.levels.WARN)
		return
	end
	opts.close_pi_ui()
	local escaped = vim.fn.fnameescape(abs_path)
	local target_win = opts.get_last_non_pi_win and opts.get_last_non_pi_win() or nil
	if target_win and vim.api.nvim_win_is_valid(target_win) and not opts.is_pi_window(target_win) then
		vim.api.nvim_set_current_win(target_win)
	end
	vim.cmd("edit " .. escaped)
end

function M.open_selected_diff(state, changes, opts)
	local entry = get_selected_tool_entry(state)
	if not entry then
		vim.notify("pi: no tool call selected", vim.log.levels.INFO)
		return
	end

	if is_bash_tool(entry.name) then
		if not changes or type(changes.show_terminal) ~= "function" then
			vim.notify("pi: terminal panel is not available", vim.log.levels.WARN)
			return
		end
		local input = type(entry.input) == "table" and entry.input or {}
		changes.show_terminal({
			title = "bash",
			command = input.command,
			output = entry.result_text,
			cwd = input.cwd or input.working_directory or input.workingDirectory,
			exit_code = (entry.details and (entry.details.exit_code or entry.details.exitCode or entry.details.code)) or nil,
		})
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
		local diff_text = git.get_diff_for_file(abs_path, { notify_no_diff = true })
		if not diff_text then return end
		changes.show_diff({
			title = vim.fn.fnamemodify(abs_path, ":t"),
			text = diff_text,
			source = abs_path,
			tool = entry.name,
		})
		return
	end

	vim.notify("pi: side panel is available for bash and write/write_file/edit tool calls", vim.log.levels.INFO)
end

function M.tool_enter_action(state, expanded_read_tools, expanded_bash_tools, opts)
	local entry = get_selected_tool_entry(state)
	if not entry then
		vim.notify("pi: no tool call selected", vim.log.levels.INFO)
		return
	end
	local name = type(entry.name) == "string" and entry.name:lower() or ""
	local rerender = opts.on_render_full or opts.on_render

	if name == "read" or name == "read_file" then
		local id = entry.id
		if id then
			if expanded_read_tools[id] then
				expanded_read_tools[id] = nil
			else
				expanded_read_tools[id] = true
			end
			rerender()
		end
	elseif name == "write" or name == "write_file" or name == "edit" then
		M.open_selected_diff(state, opts.changes, opts)
	elseif name == "bash" then
		local id = entry.id
		if id then
			if expanded_bash_tools[id] then
				expanded_bash_tools[id] = nil
			else
				expanded_bash_tools[id] = true
			end
			rerender()
		end
	elseif name == "thinking" then
		local id = entry.id
		if id and opts.expanded_thinking_tools then
			if opts.expanded_thinking_tools[id] then
				opts.expanded_thinking_tools[id] = nil
			else
				opts.expanded_thinking_tools[id] = true
			end
			rerender()
		end
	else
		opts.focus_input()
	end
end

return M

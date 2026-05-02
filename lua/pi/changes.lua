--- Changes Panel - shows the last turn (user prompt + assistant response + file changes)
---
--- Layout (right side):
--- ┌────────────────────────────────────────┐
--- │ 🔄 Last Turn Changes                   │
--- │                                        │
--- │ > You: Fix the auth bug                │
--- │                                        │
--- │ Assistant: I'll look at the auth...    │
--- │                                        │
--- │ ── Changes ─────────────────────────── │
--- │ ✎ src/auth.ts                          │
--- │ ✎ src/middleware.ts                    │
--- │ + src/auth.test.ts                     │
--- └────────────────────────────────────────┘

local config = require("pi.config")
local client = require("pi.client")

local M = {}

local changes_buf = nil
local changes_win = nil
local is_open = false
local panel_mode = "summary" -- "summary" | "diff"
local current_diff = nil

local function changes_footer_text()
	if panel_mode == "diff" then
		return " [t] last turn  [q] close panel  [Esc] back "
	end
	return " [q] close panel  [r] refresh "
end

local function apply_changes_footer()
	if not changes_win or not vim.api.nvim_win_is_valid(changes_win) then return end
	local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, changes_win)
	if not ok_cfg or type(cfg) ~= "table" then return end
	cfg.footer = changes_footer_text()
	cfg.footer_pos = "left"
	pcall(vim.api.nvim_win_set_config, changes_win, cfg)
end

local function resolve_git_base_for_path(path)
	local abs = vim.fn.fnamemodify(path, ":p")
	local dir = vim.fn.fnamemodify(abs, ":h")
	if not dir or dir == "" then return nil end
	local cmd = string.format("git -C %s rev-parse --show-toplevel 2>/dev/null", vim.fn.shellescape(dir))
	local out = vim.fn.systemlist(cmd)
	if vim.v.shell_error == 0 and out and out[1] and out[1] ~= "" then
		return out[1]
	end
	return nil
end

local function get_git_diff_for_file(path)
	if not path or path == "" then return nil end
	local abs = vim.fn.fnamemodify(path, ":p")

	local lines = nil
	local git_base = resolve_git_base_for_path(abs)
	if git_base and git_base ~= "" then
		local cmd_repo = string.format(
			"git -C %s --no-pager diff -- %s",
			vim.fn.shellescape(git_base),
			vim.fn.shellescape(abs)
		)
		lines = vim.fn.systemlist(cmd_repo)
		if vim.v.shell_error ~= 0 then
			lines = nil
		end
	end

	if not lines then
		local cmd = string.format(
			"git -C %s --no-pager diff -- %s",
			vim.fn.shellescape(vim.fn.getcwd()),
			vim.fn.shellescape(abs)
		)
		lines = vim.fn.systemlist(cmd)
		if vim.v.shell_error ~= 0 then
			lines = nil
		end
	end

	if lines and #lines > 0 then
		return table.concat(lines, "\n")
	end

	-- Handle untracked files: render as add-from-/dev/null style diff.
	if vim.fn.filereadable(abs) == 1 then
		local cmd_untracked = string.format(
			"git --no-pager diff --no-index -- /dev/null %s",
			vim.fn.shellescape(abs)
		)
		local added = vim.fn.systemlist(cmd_untracked)
		if added and #added > 0 then
			return table.concat(added, "\n")
		end
	end
	return nil
end

local function parse_written_path_from_tool_result(msg)
	if not msg or msg.role ~= "toolResult" then return nil end
	if not msg.content or type(msg.content) ~= "table" then return nil end
	for _, block in ipairs(msg.content) do
		if block.type == "text" and type(block.text) == "string" then
			local path = block.text:match("Successfully wrote %d+ bytes to%s+([^\n\r]+)")
			if path and path ~= "" then
				return path:gsub("%s+$", "")
			end
		end
	end
	return nil
end

local function get_ui_margins()
	local mx = tonumber(config.options.ui_margin_cols) or 0
	local my = tonumber(config.options.ui_margin_rows) or 0
	return math.max(0, math.floor(mx)), math.max(0, math.floor(my))
end

--- Open the changes panel
function M.open()
	if changes_win and vim.api.nvim_win_is_valid(changes_win) then
		apply_changes_footer()
		local ok_chat, chat = pcall(require, "pi.chat")
		if ok_chat and chat and chat.relayout then
			chat.relayout()
		end
		return
	end

	changes_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(changes_buf, "pi://changes")
	vim.api.nvim_buf_set_option(changes_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(changes_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(changes_buf, "filetype", "pi-changes")

	local width = config.options.changes_width
	local mx, my = get_ui_margins()
	local col = vim.o.columns - mx - width
	local height = math.max(8, vim.o.lines - 1 - (my * 2))

	local opts = {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = my,
		col = col,
		border = "single",
	}
	changes_win = vim.api.nvim_open_win(changes_buf, false, opts)
	is_open = true
	apply_changes_footer()
	local ok_chat, chat = pcall(require, "pi.chat")
	if ok_chat and chat and chat.relayout then
		chat.relayout()
	end

	-- Set keymaps
	local km = { buffer = changes_buf, noremap = true, silent = true }
	vim.keymap.set("n", config.options.keymaps.changes_toggle, function()
		M.toggle()
	end, km)
	vim.keymap.set("n", "q", function()
		M.close()
	end, km)
	vim.keymap.set("n", "<Esc>", function()
		if panel_mode == "diff" then
			M.show_last_turn()
		else
			M.close()
		end
	end, km)
	vim.keymap.set("n", "r", function()
		M.refresh()
	end, km)
	vim.keymap.set("n", "t", function()
		M.show_last_turn()
	end, km)
	-- Navigate to chat with C-h
	vim.keymap.set("n", "<C-h>", function()
		require("pi.chat").focus()
	end, km)
	vim.keymap.set("n", "<Left>", function()
		require("pi.chat").focus()
	end, km)

	-- Listen for agent_end to auto-update
	client.on_event("agent_end", function()
		vim.schedule(function()
			M.refresh()
		end)
	end)

	-- Initial refresh
	M.show_last_turn()
end

--- Close the changes panel
function M.close()
	if changes_win and vim.api.nvim_win_is_valid(changes_win) then
		vim.api.nvim_win_close(changes_win, true)
		changes_win = nil
	end
	is_open = false
	local ok_chat, chat = pcall(require, "pi.chat")
	if ok_chat and chat and chat.relayout then
		chat.relayout()
	end
end

--- Toggle the changes panel
function M.toggle()
	if is_open then
		M.close()
	else
		M.open()
	end
end

--- Check if the panel is open
--- @return boolean
function M.is_open()
	return is_open
end

--- Focus the changes window
function M.focus()
	if changes_win and vim.api.nvim_win_is_valid(changes_win) then
		vim.api.nvim_set_current_win(changes_win)
	end
end

--- Refresh the changes panel content
function M.refresh()
	if not changes_buf or not vim.api.nvim_buf_is_valid(changes_buf) then
		return
	end

	if panel_mode == "diff" then
		if current_diff and current_diff.text then
			M._render_diff(current_diff)
		end
		return
	end

	if not client.is_running() then
		return
	end

	client.get_messages(function(response)
		vim.schedule(function()
			if not changes_buf or not vim.api.nvim_buf_is_valid(changes_buf) then
				return
			end
			if panel_mode ~= "summary" then
				if current_diff and current_diff.text then
					M._render_diff(current_diff)
				end
				return
			end
			M._render_messages(response)
		end)
	end)
end

function M.show_last_turn()
	panel_mode = "summary"
	current_diff = nil
	apply_changes_footer()
	M.refresh()
end

--- Show/update single persistent diff view in the right panel.
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
		-- Re-apply config to keep this panel on top of sibling floats.
		local cfg = vim.api.nvim_win_get_config(changes_win)
		vim.api.nvim_win_set_config(changes_win, cfg)
	end
	panel_mode = "diff"
	apply_changes_footer()
	current_diff = {
		title = diff.title or "Diff",
		text = diff.text,
		source = diff.source,
		tool = diff.tool,
	}
	M._render_diff(current_diff)
end

--- Render the messages in the changes panel
--- @param response table
function M._render_messages(response)
	if not response or not response.success or not response.data then
		return
	end

	local messages = response.data.messages or {}
	if #messages == 0 then
		M._set_content({ "  (no messages yet)" })
		return
	end

	-- Find the last user message and assistant response
	local last_user_msg = nil
	local last_user_idx = nil
	for i = #messages, 1, -1 do
		local msg = messages[i]
		if msg and msg.role == "user" then
			last_user_msg = msg
			last_user_idx = i
			break
		end
	end

	if not last_user_idx then
		M._set_content({ "  (no user messages yet)" })
		return
	end

	local function extract_tool_calls(msg)
		local out = {}
		if not msg then return out end
		if msg.tool_calls and type(msg.tool_calls) == "table" then
			for _, tc in ipairs(msg.tool_calls) do
				local input = tc.input or tc.parameters or tc.arguments or {}
				if type(input) == "string" then
					local ok, parsed = pcall(vim.fn.json_decode, input)
					if ok and type(parsed) == "table" then input = parsed end
				end
				table.insert(out, {
					id = tc.id or tc.toolCallId,
					name = tc.name or tc.tool or "?",
					input = input,
					file = input.file_path or input.path or input.file or input.filename,
				})
			end
		end
		if msg.content and type(msg.content) == "table" then
			for _, block in ipairs(msg.content) do
				if block.type == "toolCall" then
					local args = block.arguments or {}
					if type(args) == "string" then
						local ok, parsed = pcall(vim.fn.json_decode, args)
						if ok and type(parsed) == "table" then args = parsed end
					end
					table.insert(out, {
						id = block.id,
						name = block.name or "?",
						input = args,
						file = args.file_path or args.path or args.file or args.filename,
					})
				end
			end
		end
		return out
	end

	local lines = {}
	local highlights = {}
	local width = math.max((config.options.changes_width or 50) - 2, 20)
	local user_text = M._extract_text(last_user_msg)

	table.insert(lines, " 🔄 Last Turn Edits")
	table.insert(highlights, { #lines - 1, "PiChangesHeader", 0, -1 })
	if user_text and user_text ~= "" then
		local prompt = user_text:gsub("%s+", " ")
		if vim.api.nvim_strwidth(prompt) > width - 8 then
			prompt = vim.fn.strcharpart(prompt, 0, width - 10) .. "…"
		end
		table.insert(lines, " prompt: " .. prompt)
		table.insert(highlights, { #lines - 1, "PiChangesPrompt", 0, -1 })
	end
	table.insert(lines, " " .. string.rep("─", width))
	table.insert(highlights, { #lines - 1, "PiSeparator", 0, -1 })

	local tool_by_id = {}
	local turn_diffs = {}
	for i = last_user_idx + 1, #messages do
		local msg = messages[i]
		if not msg then goto continue end
		if msg.role == "user" then break end
		if msg.role == "assistant" then
			for _, tc in ipairs(extract_tool_calls(msg)) do
				if tc.id then
					tool_by_id[tc.id] = tc
				end
			end
		elseif msg.role == "toolResult" then
			local details = msg.details
			if type(details) == "table" and type(details.diff) == "string" and details.diff ~= "" then
				local info = tool_by_id[msg.toolCallId] or {}
				local source = info.file
				if source and source ~= "" then
					source = vim.fn.fnamemodify(source, ":p")
				end
				table.insert(turn_diffs, {
					tool = msg.toolName or info.name or "tool",
					source = source,
					diff = details.diff,
				})
			else
				local tool_name = (msg.toolName or ""):lower()
				if tool_name == "write" or tool_name == "write_file" then
					local info = tool_by_id[msg.toolCallId] or {}
					local source = info.file or parse_written_path_from_tool_result(msg)
					if source and source ~= "" then
						local diff_text = get_git_diff_for_file(source)
						if diff_text and diff_text ~= "" then
							table.insert(turn_diffs, {
								tool = msg.toolName or info.name or "write",
								source = vim.fn.fnamemodify(source, ":p"),
								diff = diff_text,
							})
						end
					end
				end
			end
		end
		::continue::
	end

	if #turn_diffs == 0 then
		table.insert(lines, "")
		table.insert(lines, " (no edit diffs in last turn)")
		table.insert(highlights, { #lines - 1, "Comment", 0, -1 })
		M._set_content(lines, highlights)
		return
	end

	for idx, d in ipairs(turn_diffs) do
		table.insert(lines, "")
		local label = string.format(" [%d] %s", idx, d.tool or "tool")
		if d.source and d.source ~= "" then
			label = label .. "  " .. d.source
		end
		table.insert(lines, label)
		table.insert(highlights, { #lines - 1, "PiChangesFile", 0, -1 })
		table.insert(lines, " " .. string.rep("─", width))
		table.insert(highlights, { #lines - 1, "PiSeparator", 0, -1 })

		for _, raw in ipairs(vim.split(d.diff, "\n", { plain = true })) do
			local line = raw:gsub("\x1b%[[%d;]*m", "")
			table.insert(lines, line)
			local row = #lines - 1
			if vim.startswith(line, "diff ") or vim.startswith(line, "@@") then
				table.insert(highlights, { row, "PiChangesHeader", 0, -1 })
			elseif vim.startswith(line, "+++ ") or vim.startswith(line, "--- ") then
				table.insert(highlights, { row, "PiChangesFile", 0, -1 })
			elseif vim.startswith(line, "+") then
				table.insert(highlights, { row, "DiagnosticOk", 0, -1 })
			elseif vim.startswith(line, "-") then
				table.insert(highlights, { row, "DiagnosticError", 0, -1 })
			end
		end
	end

	M._set_content(lines, highlights)
end

--- Render diff mode content
--- @param diff { title?: string, text: string, source?: string, tool?: string }
function M._render_diff(diff)
	if not changes_buf or not vim.api.nvim_buf_is_valid(changes_buf) then
		return
	end
	local width = math.max((config.options.changes_width or 50) - 2, 20)
	local lines = {}
	local highlights = {}

	local header = " 🔀 " .. (diff.title or "Diff")
	table.insert(lines, header)
	table.insert(highlights, { #lines - 1, "PiChangesHeader", 0, -1 })

	local info_parts = {}
	if diff.tool and diff.tool ~= "" then table.insert(info_parts, "tool: " .. diff.tool) end
	if diff.source and diff.source ~= "" then table.insert(info_parts, "file: " .. diff.source) end
	if #info_parts > 0 then
		table.insert(lines, " " .. table.concat(info_parts, "  |  "))
		table.insert(highlights, { #lines - 1, "Comment", 0, -1 })
	end
	table.insert(lines, " " .. string.rep("─", width))
	table.insert(highlights, { #lines - 1, "PiSeparator", 0, -1 })

	for _, raw in ipairs(vim.split(diff.text, "\n", { plain = true })) do
		-- strip ANSI sequences that may come from tool output
		local line = raw:gsub("\x1b%[[%d;]*m", "")
		table.insert(lines, line)
		local row = #lines - 1
		if vim.startswith(line, "diff ") or vim.startswith(line, "@@") then
			table.insert(highlights, { row, "PiChangesHeader", 0, -1 })
		elseif vim.startswith(line, "+++ ") or vim.startswith(line, "--- ") then
			table.insert(highlights, { row, "PiChangesFile", 0, -1 })
		elseif vim.startswith(line, "+") then
			table.insert(highlights, { row, "DiagnosticOk", 0, -1 })
		elseif vim.startswith(line, "-") then
			table.insert(highlights, { row, "DiagnosticError", 0, -1 })
		end
	end

	M._set_content(lines, highlights)
end

--- Extract text from a message
--- @param msg table
--- @return string|nil
function M._extract_text(msg)
	if not msg then return nil end
	local content = msg.content
	if not content then return nil end

	if type(content) == "string" then
		return content
	end

	if type(content) == "table" then
		local parts = {}
		for _, block in ipairs(content) do
			if block.type == "text" then
				table.insert(parts, block.text)
			elseif block.type == "tool_use" and block.name then
				table.insert(parts, "[" .. block.name .. "]")
			end
		end
		return table.concat(parts, "\n")
	end

	return nil
end

--- Extract file change info from a tool call
--- @param tool_call table
--- @return { file: string, action: string, icon: string }|nil
function M._extract_file_change(tool_call)
	if not tool_call then return nil end

	local name = tool_call.name or tool_call.tool or ""
	local input = tool_call.input or tool_call.parameters or {}

	-- Handle string input (JSON)
	if type(input) == "string" then
		local ok, parsed = pcall(vim.fn.json_decode, input)
		if ok then
			input = parsed
		else
			return nil
		end
	end

	local file = input.file_path or input.path or input.file or input.filename
	if not file then return nil end

	-- Normalize file path (relative to cwd)
	local cwd = vim.fn.getcwd()
	if file:sub(1, #cwd) == cwd then
		file = file:sub(#cwd + 2) -- +2 for the separator
	end

	local action = "unknown"
	local icon = "?"

	if name == "write" or name == "write_file" then
		action = "write"
		icon = "+"
	elseif name == "edit" then
		action = "edit"
		icon = "✎"
	elseif name == "read" or name == "read_file" then
		action = "read"
		icon = "📄"
	elseif name == "bash" then
		-- For bash, try to extract file from command
		action = "bash"
		icon = "⚡"
		local cmd = input.command or ""
		-- If it's a git command, extract changed files
		if cmd:match("^git") then
			file = cmd
			icon = "⚡"
		end
	end

	return { file = file, action = action, icon = icon }
end

--- Wrap text to given width
--- @param text string
--- @param width number
--- @return string[]
function M._wrap_text(text, width)
	if not text or text == "" then return { "" } end

	local lines = {}
	for _, raw_line in ipairs(vim.split(text, "\n")) do
		-- Strip ANSI escape codes
		local line = raw_line:gsub("\x1b%[[%d;]*m", ""):gsub("\x1b%]8;;.-\x07", "")

		if #line == 0 then
			table.insert(lines, "")
		elseif #line <= width then
			table.insert(lines, line)
		else
			-- Word wrap
			local remaining = line
			while #remaining > 0 do
				if #remaining <= width then
					table.insert(lines, remaining)
					break
				end
				-- Find last space within width
				local split_pos = width
				for i = width, 1, -1 do
					if remaining:sub(i, i) == " " then
						split_pos = i
						break
					end
				end
				table.insert(lines, remaining:sub(1, split_pos))
				remaining = remaining:sub(split_pos + 1)
			end
		end
	end

	return lines
end

--- Set buffer content with highlights
--- @param lines string[]
--- @param highlights? table
function M._set_content(lines, highlights)
	if not changes_buf or not vim.api.nvim_buf_is_valid(changes_buf) then
		return
	end
	vim.api.nvim_buf_set_option(changes_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(changes_buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(changes_buf, "modifiable", false)

	if highlights then
		-- Clear old highlights
		vim.api.nvim_buf_clear_namespace(changes_buf, -1, 0, -1)
		for _, hl in ipairs(highlights) do
			local row, group, col, end_col = hl[1], hl[2], hl[3], hl[4]
			local line_len = vim.api.nvim_strwidth(lines[row + 1] or "")
			if end_col == -1 or end_col > line_len then
				end_col = line_len
			end
			if col < line_len then
				vim.api.nvim_buf_add_highlight(changes_buf, -1, group, row, col, end_col)
			end
		end
	end
end

-- Auto-refresh on session change
vim.api.nvim_create_autocmd("User", {
	pattern = "PiSessionChanged",
	callback = function()
		if is_open and changes_win and vim.api.nvim_win_is_valid(changes_win) then
			M.refresh()
		end
	end,
})

return M

local M = {}

local function set_content(buf, lines, highlights)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	if highlights then
		vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
		for _, hl in ipairs(highlights) do
			local row, group, col, end_col = hl[1], hl[2], hl[3], hl[4]
			local line_len = vim.api.nvim_strwidth(lines[row + 1] or "")
			if end_col == -1 or end_col > line_len then
				end_col = line_len
			end
			if col < line_len then
				vim.api.nvim_buf_add_highlight(buf, -1, group, row, col, end_col)
			end
		end
	end
end

function M.empty(buf, text)
	set_content(buf, { text or "  (no messages yet)" })
end

--- Render summary from extracted last-turn data.
--- @param buf integer
--- @param width number
--- @param data { user_text: string|nil, turn_diffs: table[] }
function M.summary(buf, width, data)
	local lines = {}
	local highlights = {}

	table.insert(lines, " 🔄 Last Turn Edits")
	table.insert(highlights, { #lines - 1, "PiChangesHeader", 0, -1 })

	if data.user_text and data.user_text ~= "" then
		local prompt = data.user_text:gsub("%s+", " ")
		if vim.api.nvim_strwidth(prompt) > width - 8 then
			prompt = vim.fn.strcharpart(prompt, 0, width - 10) .. "…"
		end
		table.insert(lines, " prompt: " .. prompt)
		table.insert(highlights, { #lines - 1, "PiChangesPrompt", 0, -1 })
	end
	table.insert(lines, " " .. string.rep("─", width))
	table.insert(highlights, { #lines - 1, "PiSeparator", 0, -1 })

	if not data.turn_diffs or #data.turn_diffs == 0 then
		table.insert(lines, "")
		table.insert(lines, " (no edit diffs in last turn)")
		table.insert(highlights, { #lines - 1, "Comment", 0, -1 })
		set_content(buf, lines, highlights)
		return
	end

	for idx, d in ipairs(data.turn_diffs) do
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

	set_content(buf, lines, highlights)
end

--- Render single diff panel.
--- @param buf integer
--- @param width number
--- @param diff { title?: string, text: string, source?: string, tool?: string }
function M.diff(buf, width, diff)
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

	set_content(buf, lines, highlights)
end

return M

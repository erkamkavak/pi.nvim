local M = {}

--- Render sidebar list and footer.
--- @param buf integer
--- @param win integer|nil
--- @param store table
--- @param config table
function M.render(buf, win, store, config)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

	local lines = {}
	local highlights = {}
	local pinned_sessions, regular_sessions = store.partition_sessions()
	local idx = 0

	if #pinned_sessions > 0 then
		table.insert(lines, " 📌 Pinned Sessions")
		table.insert(highlights, { idx, "PiSidebarHeader" })
		idx = idx + 1
		for _, s in ipairs(pinned_sessions) do
			idx = idx + 1
			local display = store.format_session_line(s, config.options.sidebar_width)
			table.insert(lines, display.text)
			for _, hl in ipairs(display.highlights) do
				table.insert(highlights, { idx - 1, hl.group, hl.col, hl.end_col })
			end
		end
		table.insert(lines, "")
		idx = idx + 1
	end

	table.insert(lines, " ── Sessions")
	table.insert(highlights, { idx, "PiSidebarHeader" })
	idx = idx + 1

	if #regular_sessions == 0 and #pinned_sessions == 0 then
		table.insert(lines, "  (no sessions)")
		table.insert(highlights, { idx, "PiSidebarTime", 0, -1 })
	else
		for _, s in ipairs(regular_sessions) do
			idx = idx + 1
			local display = store.format_session_line(s, config.options.sidebar_width)
			table.insert(lines, display.text)
			for _, hl in ipairs(display.highlights) do
				table.insert(highlights, { idx - 1, hl.group, hl.col, hl.end_col })
			end
		end
	end

	local win_h = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_height(win) or (vim.o.lines - 1)
	local footer_h = win_h - #lines - 5
	if footer_h > 0 then
		for _ = 1, footer_h do
			table.insert(lines, "")
		end
	end
	table.insert(lines, " ────────────────")
	table.insert(highlights, { #lines - 1, "PiSidebarHeader" })
	table.insert(lines, " P pin  d delete  r name")
	table.insert(highlights, { #lines - 1, "PiSidebarTime" })
	table.insert(lines, " * running")
	table.insert(highlights, { #lines - 1, "PiSidebarTime" })

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	for _, hl in ipairs(highlights) do
		local row, group = hl[1], hl[2]
		if not row or not group then goto continue end
		local col = hl[3] or 0
		local end_col = hl[4] or -1
		local line_text = lines[row + 1] or ""
		local len = vim.api.nvim_strwidth(line_text)
		if end_col == -1 or end_col > len then end_col = len end
		if col < 0 then col = 0 end
		if col < len and end_col > col then
			vim.api.nvim_buf_add_highlight(buf, -1, group, row, col, end_col)
		end
		::continue::
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

return M

local M = {}

-- ---------------------------------------------------------------------------
-- Highlight group mapping (matches TUI MarkdownTheme)
-- ---------------------------------------------------------------------------
M.hl_groups = {
	heading         = "PiMdHeading",
	bold            = "PiMdBold",
	italic          = "PiMdItalic",
	strikethrough   = "PiMdStrikethrough",
	underline       = "PiMdUnderline",
	code            = "PiMdCode",
	link            = "PiMdLink",
	link_url        = "PiMdLinkUrl",
	code_block      = "PiMdCodeBlock",
	code_block_border = "PiMdCodeBlockBorder",
	quote           = "PiMdQuote",
	quote_border    = "PiMdQuoteBorder",
	hr              = "PiMdHr",
	list_bullet     = "PiMdListBullet",
}

-- ---------------------------------------------------------------------------
-- Inline markdown processor
-- Parses inline formatting within a single block of text.
-- Returns: plain_text, highlights[] where highlights are {col_start, col_end, type, url?}
-- ---------------------------------------------------------------------------
local function process_inline(text)
	if not text or text == "" then
		return "", {}
	end

	local out_parts = {}
	local out_len = 0
	local hls = {}
	local i = 1
	local n = #text
	local stack = {} -- { type = "bold|italic|strikethrough", out_pos = number }

	local function append(chunk)
		if not chunk or chunk == "" then return end
		table.insert(out_parts, chunk)
		out_len = out_len + #chunk
	end

	while i <= n do
		local c = text:sub(i, i)
		local two = text:sub(i, i + 1)

		-- Code span: `text` or ```text```
		if c == "`" then
			local tick_count = 0
			local j = i
			while j <= n and text:sub(j, j) == "`" do
				tick_count = tick_count + 1
				j = j + 1
			end
			local close_pattern = string.rep("`", tick_count)
			local close_pos = text:find(close_pattern, j, true)
			if close_pos then
				local content = text:sub(j, close_pos - 1)
				local start_pos = out_len + 1
				append(content)
				table.insert(hls, { start_pos, out_len, "code" })
				i = close_pos + tick_count
			else
				append(text:sub(i, j - 1))
				i = j
			end
		-- Link: [text](url)
		elseif c == "[" then
			local rest = text:sub(i)
			local link_text, url, end_pos = rest:match("^%[(.-)%]%((.-)%)()")
			if link_text and url then
				local start_pos = out_len + 1
				append(link_text)
				table.insert(hls, { start_pos, out_len, "link", url = url })
				i = i + end_pos - 1
			else
				append(c)
				i = i + 1
			end
		-- Bold: **text** or __text__
		elseif two == "**" or two == "__" then
			if #stack > 0 and stack[#stack].type == "bold" then
				local opener = table.remove(stack)
				table.insert(hls, { opener.out_pos, out_len, "bold" })
			else
				table.insert(stack, { type = "bold", out_pos = out_len + 1 })
			end
			i = i + 2
		-- Strikethrough: ~~text~~
		elseif two == "~~" then
			if #stack > 0 and stack[#stack].type == "strikethrough" then
				local opener = table.remove(stack)
				table.insert(hls, { opener.out_pos, out_len, "strikethrough" })
			else
				table.insert(stack, { type = "strikethrough", out_pos = out_len + 1 })
			end
			i = i + 2
		-- Italic: *text* or _text_
		elseif c == "*" or c == "_" then
			if #stack > 0 and stack[#stack].type == "italic" then
				local opener = table.remove(stack)
				table.insert(hls, { opener.out_pos, out_len, "italic" })
			else
				table.insert(stack, { type = "italic", out_pos = out_len + 1 })
			end
			i = i + 1
		else
			append(c)
			i = i + 1
		end
	end

	return table.concat(out_parts), hls
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Wrap text to a max display width, preserving inline highlights.
-- Words are not split; long words overflow (same behavior as render.wrap_text).
-- Highlights that span wrap boundaries are truncated to line boundaries.
-- ---------------------------------------------------------------------------
local function wrap_with_highlights(text, inline_hls, width)
	if not text or text == "" then
		return { "" }, {}
	end
	if width <= 0 then
		width = 1
	end

	-- Split into words and spaces, tracking byte ranges
	local tokens = {}
	local word_start = 1
	local in_word = false

	for idx = 1, #text do
		local c = text:sub(idx, idx)
		if c == " " then
			if in_word then
				table.insert(tokens, {
					text = text:sub(word_start, idx - 1),
					start = word_start,
					finish = idx - 1,
					is_space = false,
				})
				in_word = false
			end
			table.insert(tokens, { text = " ", start = idx, finish = idx, is_space = true })
		elseif c == "\t" then
			if in_word then
				table.insert(tokens, {
					text = text:sub(word_start, idx - 1),
					start = word_start,
					finish = idx - 1,
					is_space = false,
				})
				in_word = false
			end
			table.insert(tokens, { text = "   ", start = idx, finish = idx, is_space = true })
		else
			if not in_word then
				word_start = idx
				in_word = true
			end
			if idx == #text then
				table.insert(tokens, {
					text = text:sub(word_start, idx),
					start = word_start,
					finish = idx,
					is_space = false,
				})
				in_word = false
			end
		end
	end

	-- Wrap tokens to lines
	local lines = {}
	local line_hls = {} -- keyed by line index, array of {col_start, col_end, type}
	local current_parts = {}
	local current_line = ""
	local current_line_width = 0

	local function flush_line()
		current_line = table.concat(current_parts)
		table.insert(lines, current_line)
		local line_idx = #lines
		line_hls[line_idx] = line_hls[line_idx] or {}
		current_parts = {}
		current_line = ""
		current_line_width = 0
	end

	for _, tok in ipairs(tokens) do
		local tok_width = vim.fn.strdisplaywidth(tok.text)

		if tok.is_space then
			if current_line_width + tok_width > width and current_line_width > 0 then
				flush_line()
			else
				table.insert(current_parts, tok.text)
				current_line_width = current_line_width + tok_width
			end
		else
			if current_line_width + tok_width > width and current_line_width > 0 then
				flush_line()
			end
			local col_start = current_line_width
			table.insert(current_parts, tok.text)
			current_line_width = current_line_width + tok_width

			-- Find inline highlights overlapping this token
			for _, hl in ipairs(inline_hls) do
				local hl_start = hl[1]
				local hl_end = hl[2]
				local hl_type = hl[3]
				if hl_start <= tok.finish and hl_end >= tok.start then
					local overlap_start = math.max(hl_start, tok.start)
					local overlap_end = math.min(hl_end, tok.finish)
					local hl_col_start = col_start + vim.fn.strdisplaywidth(text:sub(tok.start, overlap_start - 1))
					local hl_col_end = hl_col_start + vim.fn.strdisplaywidth(text:sub(overlap_start, overlap_end))
					local line_idx = #lines + 1
					line_hls[line_idx] = line_hls[line_idx] or {}
					table.insert(line_hls[line_idx], { hl_col_start, hl_col_end, hl_type })
				end
			end
		end
	end

	if #current_parts > 0 or #lines == 0 then
		flush_line()
	end

	-- Build final highlights array in the format {line_offset, hl_group, col_start, col_end}
	local highlights = {}
	for line_idx, hls_for_line in pairs(line_hls) do
		for _, hl in ipairs(hls_for_line) do
			local hl_group = M.hl_groups[hl[3]]
			if hl_group then
				table.insert(highlights, { line_idx - 1, hl_group, hl[1], hl[2] })
			end
		end
	end

	return lines, highlights
end

local function split_table_cells(line)
	local s = line or ""
	s = s:gsub("^%s*|", ""):gsub("|%s*$", "")
	local cells = {}
	local cur = {}
	local escaped = false
	for i = 1, #s do
		local ch = s:sub(i, i)
		if escaped then
			table.insert(cur, ch)
			escaped = false
		elseif ch == "\\" then
			escaped = true
		elseif ch == "|" then
			table.insert(cells, trim(table.concat(cur)))
			cur = {}
		else
			table.insert(cur, ch)
		end
	end
	table.insert(cells, trim(table.concat(cur)))
	return cells
end

local function is_table_delimiter(line)
	if not line or line == "" then return false end
	if not line:find("|", 1, true) then return false end
	local parts = split_table_cells(line)
	if #parts == 0 then return false end
	for _, part in ipairs(parts) do
		if not part:match("^:?-+:?$") then
			return false
		end
	end
	return true
end

local function is_list_start(line)
	return line:match("^%s*[-*+] ") or line:match("^%s*%d+%. ")
end

local function parse_heading(line)
	local hashes, heading_text = line:match("^(#+)%s+(.+)$")
	if not hashes or #hashes > 6 then return nil, nil end
	return #hashes, heading_text
end

local function is_horizontal_rule(line)
	return line:match("^%s*%-%-%-+%s*$")
		or line:match("^%s*%*%*%*+%s*$")
		or line:match("^%s*___+%s*$")
end

local function is_block_start(raw_lines, idx)
	local line = raw_lines[idx]
	if not line or line == "" then return false end
	if line:match("^%s*```") then return true end
	if parse_heading(line) then return true end
	if is_horizontal_rule(line) then return true end
	if idx < #raw_lines and line:find("|", 1, true) and is_table_delimiter(raw_lines[idx + 1]) then
		return true
	end
	if line:match("^>") then return true end
	if is_list_start(line) then return true end
	return false
end

-- ---------------------------------------------------------------------------
-- Render markdown text into lines + highlights.
-- @param text string  Raw markdown text
-- @param opts table   { width = number, base_line = number }
-- @return lines string[]
-- @return highlights table[] {line_offset, hl_group, col_start, col_end}
-- ---------------------------------------------------------------------------
function M.render(text, opts)
	opts = opts or {}
	local width = math.max(opts.width or 78, 10)
	local base_line = opts.base_line or 0

	local lines = {}
	local highlights = {}
	local line_offset = 0

	local function add_line(line_text, line_hls)
		table.insert(lines, line_text)
		if line_hls then
			for _, hl in ipairs(line_hls) do
				table.insert(highlights, { line_offset, hl[1], hl[2], hl[3] })
			end
		end
		line_offset = line_offset + 1
	end

	local function add_highlight(line_off, hl_group, col_start, col_end)
		table.insert(highlights, { line_off, hl_group, col_start, col_end })
	end

	if not text or text == "" then
		return lines, highlights
	end

	local raw_lines = vim.split(text, "\n")
	local i = 1

	while i <= #raw_lines do
		local line = raw_lines[i]

		-- Code fence ---------------------------------------------------------
		if line:match("^%s*```") then
			local lang = line:match("^%s*```(%S*)") or ""
			local code_lines = {}
			i = i + 1
			while i <= #raw_lines and not raw_lines[i]:match("^%s*```") do
				table.insert(code_lines, raw_lines[i])
				i = i + 1
			end
			i = i + 1 -- skip closing ```

			local border = "```" .. lang
			add_line(border, { { M.hl_groups.code_block_border, 0, vim.fn.strdisplaywidth(border) } })
			for _, cl in ipairs(code_lines) do
				add_line(cl, { { M.hl_groups.code_block, 0, vim.fn.strdisplaywidth(cl) } })
			end
			add_line("```", { { M.hl_groups.code_block_border, 0, 3 } })
			if i <= #raw_lines and raw_lines[i] ~= "" then
				add_line("")
			end

		-- Heading ------------------------------------------------------------
		elseif parse_heading(line) then
			if #lines > 0 and lines[#lines] ~= "" then
				add_line("")
			end
			local level, heading_text = parse_heading(line)
			if heading_text then
				local heading_prefix = ""
				if level >= 3 then
					heading_prefix = string.rep("#", level) .. " "
				end
				local plain, inline_hls = process_inline(heading_text)
				if heading_prefix ~= "" then
					local prefix_w = vim.fn.strdisplaywidth(heading_prefix)
					plain = heading_prefix .. plain
					for _, hl in ipairs(inline_hls) do
						hl[1] = hl[1] + prefix_w
						hl[2] = hl[2] + prefix_w
					end
				end
				local wlines, whls = wrap_with_highlights(plain, inline_hls, width)
				for idx, wl in ipairs(wlines) do
					add_line(wl)
					if idx == 1 then
						add_highlight(line_offset - 1, M.hl_groups.heading, 0, vim.fn.strdisplaywidth(wl))
					end
				end
				-- Add inline highlights
				for _, hl in ipairs(whls) do
					add_highlight(line_offset - #wlines + hl[1], hl[2], hl[3], hl[4])
				end
			end
			i = i + 1
			if i <= #raw_lines and raw_lines[i] ~= "" then
				add_line("")
			end

		-- Horizontal rule ----------------------------------------------------
		elseif is_horizontal_rule(line) then
			local hr_text = string.rep("─", math.min(width, 80))
			add_line(hr_text, { { M.hl_groups.hr, 0, vim.fn.strdisplaywidth(hr_text) } })
			i = i + 1
			if i <= #raw_lines and raw_lines[i] ~= "" then
				add_line("")
			end

		-- Table --------------------------------------------------------------
		elseif i < #raw_lines and line:find("|", 1, true) and is_table_delimiter(raw_lines[i + 1]) then
			local start_i = i
			local header_cells = split_table_cells(raw_lines[i])
			local delim_cells = split_table_cells(raw_lines[i + 1])
			local num_cols = math.max(#header_cells, #delim_cells)
			if num_cols == 0 then
				i = i + 1
			else
				for col = #header_cells + 1, num_cols do
					header_cells[col] = ""
				end

				i = i + 2
				local data_rows = {}
				while i <= #raw_lines do
					local row_line = raw_lines[i]
					if row_line == "" then break end
					if not row_line:find("|", 1, true) then break end
					local row_cells = split_table_cells(row_line)
					for col = #row_cells + 1, num_cols do
						row_cells[col] = ""
					end
					table.insert(data_rows, row_cells)
					i = i + 1
				end

				local border_overhead = 3 * num_cols + 1
				local available_cells = width - border_overhead
				if available_cells < num_cols then
					local fallback_lines = {}
					for j = start_i, i - 1 do
						table.insert(fallback_lines, raw_lines[j])
					end
					local plain = table.concat(fallback_lines, "\n")
					local wlines = vim.split(plain, "\n")
					for _, wl in ipairs(wlines) do
						local wrapped_lines = wrap_with_highlights(wl, {}, width)
						for _, out in ipairs(wrapped_lines) do
							add_line(out)
						end
					end
				else
					local col_widths = {}
					for col = 1, num_cols do col_widths[col] = 1 end

					local rows_for_width = { header_cells }
					for _, row in ipairs(data_rows) do
						table.insert(rows_for_width, row)
					end
					for _, row in ipairs(rows_for_width) do
						for col = 1, num_cols do
							local plain = process_inline(row[col] or "")
							local w = vim.fn.strdisplaywidth(plain)
							if w > col_widths[col] then col_widths[col] = w end
						end
					end

					local total_cells = 0
					for _, w in ipairs(col_widths) do total_cells = total_cells + w end
					if total_cells > available_cells then
						local min_w = math.max(1, math.floor(available_cells / num_cols))
						for col = 1, num_cols do
							col_widths[col] = math.max(1, math.min(col_widths[col], min_w))
						end
					else
						local remaining = available_cells - total_cells
						local col = 1
						while remaining > 0 do
							col_widths[col] = col_widths[col] + 1
							remaining = remaining - 1
							col = (col % num_cols) + 1
						end
					end

					local function border(left, mid, right)
						local chunks = {}
						for col = 1, num_cols do
							table.insert(chunks, string.rep("─", col_widths[col]))
						end
						return left .. "─" .. table.concat(chunks, "─" .. mid .. "─") .. "─" .. right
					end

					add_line(border("┌", "┬", "┐"))

					local function render_table_row(row, is_header)
						local cell_blocks = {}
						local row_height = 1
						for col = 1, num_cols do
							local plain, inline_hls = process_inline(row[col] or "")
							local wlines, whls = wrap_with_highlights(plain, inline_hls, col_widths[col])
							cell_blocks[col] = { lines = wlines, hls = whls }
							if #wlines > row_height then row_height = #wlines end
						end

						local row_start = line_offset
						for r = 1, row_height do
							local parts = {}
							for col = 1, num_cols do
								local txt = cell_blocks[col].lines[r] or ""
								local pad = col_widths[col] - vim.fn.strdisplaywidth(txt)
								if pad > 0 then
									txt = txt .. string.rep(" ", pad)
								end
								table.insert(parts, txt)
							end
							add_line("│ " .. table.concat(parts, " │ ") .. " │")
						end

						for col = 1, num_cols do
							local cell = cell_blocks[col]
							local col_offset = 2
							for c = 1, col - 1 do
								col_offset = col_offset + col_widths[c] + 3
							end
							for _, hl in ipairs(cell.hls) do
								local h_line = row_start + hl[1]
								local h_group = hl[2]
								local h_start = col_offset + hl[3]
								local h_end = col_offset + hl[4]
								add_highlight(h_line, h_group, h_start, h_end)
							end
						end

						if is_header then
							for r = 0, row_height - 1 do
								add_highlight(row_start + r, M.hl_groups.bold, 2, math.max(2, width - 2))
							end
						end
					end

					render_table_row(header_cells, true)
					add_line(border("├", "┼", "┤"))
					for ridx, row in ipairs(data_rows) do
						render_table_row(row, false)
						if ridx < #data_rows then
							add_line(border("├", "┼", "┤"))
						end
					end
					add_line(border("└", "┴", "┘"))
				end

				if i <= #raw_lines and raw_lines[i] ~= "" then
					add_line("")
				end
			end

		-- Blockquote ---------------------------------------------------------
		elseif line:match("^>") then
			local quote_lines = {}
			while i <= #raw_lines do
				local ql = raw_lines[i]
				if ql:match("^>") then
					local qtext = ql:gsub("^>%s?", "")
					table.insert(quote_lines, qtext)
					i = i + 1
				elseif ql == "" and i < #raw_lines and raw_lines[i + 1]:match("^>") then
					i = i + 1
					-- continue
				else
					break
				end
			end

			for _, qtext in ipairs(quote_lines) do
				local plain, inline_hls = process_inline(qtext)
				local wlines, whls = wrap_with_highlights(plain, inline_hls, width - 2)
				for idx, wl in ipairs(wlines) do
					add_line("│ " .. wl)
					-- Border highlight
					add_highlight(line_offset - 1, M.hl_groups.quote_border, 0, vim.fn.strdisplaywidth("│ "))
					-- Quote text highlight (whole line for simplicity)
					add_highlight(line_offset - 1, M.hl_groups.quote, 2, vim.fn.strdisplaywidth("│ " .. wl))
				end
				for _, hl in ipairs(whls) do
					add_highlight(line_offset - #wlines + hl[1], hl[2], 2 + hl[3], 2 + hl[4])
				end
			end
			if i <= #raw_lines and raw_lines[i] ~= "" then
				add_line("")
			end

		-- List ---------------------------------------------------------------
		elseif is_list_start(line) then
			local list_indent = #(line:match("^(%s*)") or "")
			local list_items = {}
			local current_item_lines = {}
			local current_item_indent = list_indent

			while i <= #raw_lines do
				local current = raw_lines[i]
				if current == "" then
					i = i + 1
					break
				end
				local cur_indent = #(current:match("^(%s*)") or "")
				local is_new_item = current:match("^%s*[-*+] ") or current:match("^%s*%d+%. ")

				if is_new_item and cur_indent <= list_indent then
					if #current_item_lines > 0 then
						table.insert(list_items, current_item_lines)
					end
					current_item_lines = {}
					current_item_indent = cur_indent
				elseif cur_indent < list_indent and not is_new_item then
					break
				end

				table.insert(current_item_lines, current)
				i = i + 1
			end
			if #current_item_lines > 0 then
				table.insert(list_items, current_item_lines)
			end

			for _, item_lines in ipairs(list_items) do
				local bullet = item_lines[1]:match("^%s*([-*+] )") or item_lines[1]:match("^%s*(%d+%. )")
				local bullet_indent = #(item_lines[1]:match("^(%s*)") or "")
				local content_lines = {}
				for idx, il in ipairs(item_lines) do
						if idx == 1 then
							table.insert(content_lines, (il:gsub("^%s*[-*+] ", ""):gsub("^%s*%d+%. ", "")))
						else
							local line_indent = #(il:match("^(%s*)") or "")
							if line_indent > bullet_indent then
								table.insert(content_lines, il:sub(bullet_indent + 1))
							else
								table.insert(content_lines, (il:gsub("^%s*", "")))
							end
						end
				end

				local content = table.concat(content_lines, " ")
				local plain, inline_hls = process_inline(content)
				local wlines, whls = wrap_with_highlights(plain, inline_hls, width - 2)

				for idx, wl in ipairs(wlines) do
					local prefix = (idx == 1 and bullet or "  ")
					add_line(prefix .. wl)
					if idx == 1 and bullet then
						add_highlight(line_offset - 1, M.hl_groups.list_bullet, 0, vim.fn.strdisplaywidth(bullet))
					end
				end
				for _, hl in ipairs(whls) do
					local prefix_len = (hl[1] == 0 and (bullet and vim.fn.strdisplaywidth(bullet) or 2) or 2)
					add_highlight(line_offset - #wlines + hl[1], hl[2], prefix_len + hl[3], prefix_len + hl[4])
				end
			end
			if i <= #raw_lines and raw_lines[i] ~= "" then
				add_line("")
			end

		-- Paragraph ----------------------------------------------------------
			elseif line ~= "" then
				local para_lines = {}
				while i <= #raw_lines and raw_lines[i] ~= "" do
					if #para_lines > 0 and is_block_start(raw_lines, i) then break end
					table.insert(para_lines, raw_lines[i])
					i = i + 1
				end

			local para_text = table.concat(para_lines, " ")
			local plain, inline_hls = process_inline(para_text)
			local wlines, whls = wrap_with_highlights(plain, inline_hls, width)

			for _, wl in ipairs(wlines) do
				add_line(wl)
			end
			for _, hl in ipairs(whls) do
				add_highlight(line_offset - #wlines + hl[1], hl[2], hl[3], hl[4])
			end
				if i <= #raw_lines and raw_lines[i] ~= "" and not is_list_start(raw_lines[i]) then
					add_line("")
				end
		else
			-- Explicit blank lines from source
			add_line("")
			i = i + 1
		end

		-- Skip blank lines between blocks
		while i <= #raw_lines and raw_lines[i] == "" do i = i + 1 end
	end

	return lines, highlights
end

return M

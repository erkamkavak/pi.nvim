local text = require("pi.util.text")
local markdown = require("pi.chat.markdown")

local M = {}

--- Extract tool calls from a message (legacy + content blocks).
function M.extract_tool_calls(msg)
	local calls = {}
	if not msg then return calls end

	if msg.tool_calls and type(msg.tool_calls) == "table" then
		for _, tc in ipairs(msg.tool_calls) do
			local input = tc.input or tc.parameters or tc.arguments or {}
			if type(input) == "string" then
				local ok, p = pcall(vim.fn.json_decode, input)
				if ok then input = p end
			end
			table.insert(calls, {
				id = tc.id or tc.toolCallId,
				name = tc.name or tc.tool or "?",
				input = input,
				file = input.file_path or input.path or input.file or "",
				command = input.command or "",
				details = tc.details,
				result = tc.result,
			})
		end
	end

	if msg.content and type(msg.content) == "table" then
		for _, block in ipairs(msg.content) do
			if block.type == "toolCall" then
				local args = block.arguments or {}
				if type(args) == "string" then
					local ok, p = pcall(vim.fn.json_decode, args)
					if ok then args = p end
				end
				table.insert(calls, {
					id = block.id,
					name = block.name or "?",
					input = args,
					file = args.file_path or args.path or args.file or "",
					command = args.command or "",
					details = block.details,
				})
			end
		end
	end

	return calls
end

function M.is_diff_capable_tool(name)
	local n = type(name) == "string" and name:lower() or ""
	return n == "write" or n == "write_file" or n == "edit"
end

function M.diff_stats(diff_text)
	if not diff_text or diff_text == "" then return nil end
	local added, removed = 0, 0
	for _, ln in ipairs(vim.split(diff_text, "\n")) do
		if vim.startswith(ln, "+") and not vim.startswith(ln, "+++") then
			added = added + 1
		elseif vim.startswith(ln, "-") and not vim.startswith(ln, "---") then
			removed = removed + 1
		end
	end
	if added == 0 and removed == 0 then return nil end
	return "+" .. added .. " -" .. removed
end

function M.format_read_interval(input)
	if type(input) ~= "table" then return "" end
	local start_line = input.start_line or input.startLine or input.line_start or input.lineStart
		or input.from_line or input.fromLine
	local end_line = input.end_line or input.endLine or input.line_end or input.lineEnd
		or input.to_line or input.toLine
	if start_line and end_line then
		return "L" .. start_line .. "-" .. end_line
	elseif start_line then
		return "L" .. start_line
	elseif input.offset and input.limit then
		local from = tonumber(input.offset) or 0
		local to = from + tonumber(input.limit)
		return "L" .. from .. "-" .. to
	elseif input.line then
		return "L" .. input.line
	end
	return ""
end

function M.truncate_text(text, width)
	if not text then return "" end
	if width <= 0 then return "" end
	if vim.fn.strdisplaywidth(text) <= width then return text end
	local out = text
	while #out > 0 and vim.fn.strdisplaywidth(out .. "…") > width do
		out = out:sub(1, -2)
	end
	if out == "" then return "…" end
	return out .. "…"
end

function M.wrap_text(text, width)
	if not text or text == "" then return { "" } end
	local result = {}
	for _, raw in ipairs(vim.split(text, "\n")) do
		local line = raw:gsub("\x1b%[[%d;]*m", "")
		if line == "" then
			table.insert(result, "")
		elseif vim.fn.strdisplaywidth(line) <= width then
			table.insert(result, line)
		else
			local r = line
			while r ~= "" do
				if vim.fn.strdisplaywidth(r) <= width then
					table.insert(result, r)
					break
				end
				local best_char = 0
				local split_char = 0
				local char_count = vim.fn.strchars(r)
				for i = 1, char_count do
					local chunk = vim.fn.strcharpart(r, 0, i)
					if vim.fn.strdisplaywidth(chunk) > width then break end
					best_char = i
					if vim.fn.strcharpart(r, i - 1, 1) == " " then
						split_char = i
					end
				end
				local split_at = split_char > 0 and split_char or math.max(best_char, 1)
				local head = vim.fn.strcharpart(r, 0, split_at)
				head = head:gsub("%s+$", "")
				table.insert(result, head)
				r = vim.fn.strcharpart(r, split_at):gsub("^%s+", "")
			end
		end
	end
	return result
end

function M.extract_text(msg)
	if not msg then return nil end
	local content = msg.content
	if not content then return nil end
	if type(content) == "string" then
		return content
	end
	if type(content) == "table" then
		local parts = {}
		for _, block in ipairs(content) do
			if block.type == "text" and type(block.text) == "string" then
				table.insert(parts, block.text)
			end
		end
		if #parts == 0 then return nil end
		return table.concat(parts, "\n")
	end
	return nil
end

function M.extract_thinking_blocks(msg)
	local thoughts = {}
	if not msg or type(msg.content) ~= "table" then return thoughts end
	for _, block in ipairs(msg.content) do
		if block.type == "thinking" and type(block.thinking) == "string" and block.thinking ~= "" then
			table.insert(thoughts, block.thinking)
		end
	end
	return thoughts
end

local function thinking_summary(thought)
	local chars = vim.fn.strchars(thought or "")
	return "thinking process (" .. tostring(chars) .. " chars)"
end

--- Build chat lines/highlights/tool entries from state.
--- @param opts table
--- @return string[], table[], table[]
function M.render(opts)
	local lines = {}
	local highlights = {}
	local tool_entries = {}
	local line_idx = 0

	local section_width = math.max(opts.section_width or 20, 20)
	local text_width = math.max(opts.text_width or 18, 18)
	local separator = "  " .. string.rep("━", section_width)
	local expanded_bash = opts.expanded_bash_tools or {}
	local expanded_read = opts.expanded_read_tools or {}
	local expanded_thinking = opts.expanded_thinking_tools or {}

	local function add_line(value, hl_group)
		table.insert(lines, text.sanitize_line(value))
		if hl_group then
			table.insert(highlights, { line_idx, hl_group })
		end
		line_idx = line_idx + 1
	end

	local function add_tool_entry(entry)
		table.insert(tool_entries, entry)
	end

	if #opts.messages == 0 then
		add_line("")
		add_line("  No messages yet. Type in the input bar below.", "Comment")
		return lines, highlights, tool_entries
	end

	local model_text = "  pi"
	if opts.current_model and opts.current_model ~= "" then
		model_text = model_text .. "  " .. opts.current_model
	end
	add_line(model_text, "Title")
	if opts.start_idx and opts.start_idx > 1 then
		add_line("  [showing last " .. tostring(#opts.messages) .. " of " .. tostring(opts.total_messages) .. " messages]", "Comment")
	end
	add_line("")

	local pending_tools = {}
	local pending_tool_order = {}
	local tool_call_info = {}
	local assistant_section_open = false
	local last_render_kind = nil
	local last_tool_kind = nil

	local function open_user_section()
		add_line("")
		add_line(separator, "PiSeparator")
		add_line("  You", "PiUserHeader")
		add_line(separator, "PiSeparator")
			assistant_section_open = false
			pending_tools = {}
			pending_tool_order = {}
			last_render_kind = nil
			last_tool_kind = nil
		end

	local function open_assistant_section(header_text)
		if assistant_section_open then return end
		add_line("")
		add_line(separator, "PiSeparator")
		add_line("  " .. header_text, "PiAssistantHeader")
		add_line(separator, "PiSeparator")
		assistant_section_open = true
	end

	for msg_idx, msg in ipairs(opts.messages) do
		if msg.role == "user" then
			local content = M.extract_text(msg)
			if content and content ~= "" then
				open_user_section()
				local md_lines, md_hls = markdown.render(content, { width = text_width })
				for _, ml in ipairs(md_lines) do
					add_line("  " .. ml)
				end
				for _, hl in ipairs(md_hls) do
					table.insert(highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
				end
				last_render_kind = "text"
			end
		elseif msg.role == "assistant" then
			open_assistant_section("Assistant")

			local thinking_blocks = M.extract_thinking_blocks(msg)
			if #thinking_blocks > 0 then
				if last_render_kind == "text" then add_line("") end
				for idx, thought in ipairs(thinking_blocks) do
					local thinking_id = "thinking_" .. tostring(msg.timestamp or msg_idx) .. "_" .. tostring(idx)
					add_line("  ◇ " .. thinking_summary(thought), "PiToolCall")
					add_tool_entry({
						id = thinking_id,
						name = "thinking",
						kind = "thinking",
						line = line_idx - 1,
						result_text = thought,
					})
					if expanded_thinking[thinking_id] then
						for _, l in ipairs(M.wrap_text(thought, text_width)) do
							add_line("  │ " .. l, "PiToolResult")
						end
					end
					end
					last_render_kind = "tool"
					last_tool_kind = "thinking"
				end

				local content = M.extract_text(msg)
				if content and content ~= "" then
					if last_render_kind == "tool" then add_line("") end
					local md_lines, md_hls = markdown.render(content, { width = text_width })
				for _, ml in ipairs(md_lines) do
					add_line("  " .. ml)
				end
				for _, hl in ipairs(md_hls) do
					table.insert(highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
					end
					last_render_kind = "text"
					last_tool_kind = nil
				end

				local tcalls = M.extract_tool_calls(msg)
				if #tcalls > 0 then
					if last_render_kind == "text" then add_line("") end
				for _, tc in ipairs(tcalls) do
					local file = tc.file or ""
					local cmd = tc.command or ""
					local tool_id = tc.id or ("tool_" .. tostring(#pending_tool_order + 1))
					local tname_lower = type(tc.name) == "string" and tc.name:lower() or ""
					if file ~= "" then
						local body = tc.name .. "  " .. file
						local interval = ""
						if tname_lower == "read" or tname_lower == "read_file" then
							interval = M.format_read_interval(tc.input)
							if interval ~= "" then
								body = body .. "  " .. interval
							end
						end
						tool_call_info[tool_id] = { line_idx = line_idx, body = body, file = file }
						local line_text = "  ▶ " .. M.truncate_text(body, section_width - 2)
						local fstart = string.find(line_text, file, 1, true)
						if fstart then
							table.insert(highlights, { line_idx, "MoreMsg", fstart - 1, fstart + string.len(file) - 1 })
						end
						if interval ~= "" then
							local istart = string.find(line_text, "  " .. interval, 1, true)
							if istart then
								table.insert(highlights, { line_idx, "WarningMsg", istart - 1, istart + string.len("  " .. interval) - 1 })
							end
						end
						add_line(line_text, "PiToolCall")
					elseif cmd ~= "" then
						local cmd_display = cmd:gsub("\n", " ")
						if vim.fn.strdisplaywidth(cmd_display) > 100 then
							cmd_display = vim.fn.strcharpart(cmd_display, 0, 97) .. "…"
						end
						local body = tc.name .. "  " .. cmd_display
						tool_call_info[tool_id] = { line_idx = line_idx, body = body, file = file }
						add_line("  ▶ " .. M.truncate_text(body, section_width - 2), "PiToolCall")
					else
						tool_call_info[tool_id] = { line_idx = line_idx, body = tc.name }
						add_line("  ▶ " .. tc.name, "PiToolCall")
					end
					pending_tools[tool_id] = tc
					table.insert(pending_tool_order, tool_id)
					add_tool_entry({
						id = tool_id,
						name = tc.name,
						kind = "tool",
						input = tc.input,
						line = line_idx - 1,
						details = tc.details,
						result_text = tc.result,
					})
					end
					last_render_kind = "tool"
					last_tool_kind = "tool"
				end
		elseif msg.role == "toolResult" then
			open_assistant_section("Assistant")
			local text = M.extract_text(msg)
			if text then
				local tool_data = msg.toolCallId and pending_tools[msg.toolCallId] or nil
				if not tool_data and #pending_tool_order > 0 then
					local last_id = pending_tool_order[#pending_tool_order]
					tool_data = pending_tools[last_id]
				end
				local tool_name = (tool_data and tool_data.name) or (msg.toolName or "tool")
				local tname_lower = type(tool_name) == "string" and tool_name:lower() or ""

				if msg.toolCallId and pending_tools[msg.toolCallId] then
					pending_tools[msg.toolCallId].details = msg.details
					pending_tools[msg.toolCallId].result_text = text
					for i = #tool_entries, 1, -1 do
						if tool_entries[i].id == msg.toolCallId then
							tool_entries[i].details = msg.details
							tool_entries[i].result_text = text
							break
						end
					end
				end

				if tname_lower == "read" or tname_lower == "read_file" then
					if msg.toolCallId and expanded_read[msg.toolCallId] then
						local lines_shown = 0
						local max_lines = 10
							for _, l in ipairs(vim.split(text, "\n")) do
								if lines_shown >= max_lines then
									add_line("  │ ...", "Comment")
									break
								end
								add_line("  │ " .. l, "PiToolResult")
								lines_shown = lines_shown + 1
							end
							last_render_kind = "tool"
							last_tool_kind = "tool"
						end
					elseif tname_lower == "bash" then
					if msg.toolCallId and expanded_bash[msg.toolCallId] then
						local command = (tool_data and tool_data.input and tool_data.input.command) or ""
						if command ~= "" then
							for _, l in ipairs(vim.split(command, "\n")) do
								add_line("  │ $ " .. l, "PiToolResult")
							end
						end
							for _, l in ipairs(vim.split(text, "\n")) do
								add_line("  │ " .. l, "PiToolResult")
							end
							last_render_kind = "tool"
							last_tool_kind = "tool"
						end
				elseif tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit" then
					local diff_text = msg.details and msg.details.diff
					local stats = M.diff_stats(diff_text)
					local info = msg.toolCallId and tool_call_info[msg.toolCallId] or nil
					if info and stats then
						local new_body = info.body .. "  " .. stats
						local line_text = "  ▶ " .. M.truncate_text(new_body, section_width - 2)
						lines[info.line_idx + 1] = line_text
						local sstart = string.find(line_text, "  " .. stats, 1, true)
						if sstart then
							local plus_start, plus_end = string.find(stats, "%+%d+")
							if plus_start then
								table.insert(highlights, { info.line_idx, "DiagnosticOk", sstart + plus_start, sstart + 1 + plus_end })
							end
							local minus_start, minus_end = string.find(stats, "%-%d+")
							if minus_start then
								table.insert(highlights, { info.line_idx, "DiagnosticError", sstart + minus_start, sstart + 1 + minus_end })
							end
						end
						local fstart = string.find(line_text, info.file or "", 1, true)
						if fstart then
							table.insert(highlights, { info.line_idx, "MoreMsg", fstart - 1, fstart + string.len(info.file or "") - 1 })
						end
						end
						last_render_kind = "tool"
						last_tool_kind = "tool"
					else
					local preview = text:gsub("\n", " ")
					local prefix = "◀ " .. tool_name .. ": "
					local available = math.max(section_width - 2 - vim.fn.strdisplaywidth(prefix), 12)
						preview = M.truncate_text(preview, available)
						add_line("  ◀ " .. tool_name .. ": " .. preview, "PiToolResult")
						last_render_kind = "tool"
						last_tool_kind = "tool"
					end
			end
		end
	end

	local streaming_start_idx = line_idx


		if opts.is_streaming then
			open_assistant_section("Assistant  (typing...)")
			if opts.streaming_pre_tool_text ~= "" then
				if last_render_kind == "tool" then add_line("") end
				local md_lines, md_hls = markdown.render(opts.streaming_pre_tool_text, { width = text_width })
			for _, ml in ipairs(md_lines) do
				add_line("  " .. ml)
			end
			for _, hl in ipairs(md_hls) do
				table.insert(highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
				end
				last_render_kind = "text"
				last_tool_kind = nil
			end

		for _, tb in ipairs(opts.streaming_thinking_blocks or {}) do
			local thought = type(tb.text) == "string" and tb.text or ""
			if thought ~= "" then
				add_line("  ◇ " .. thinking_summary(thought), "PiToolCall")
				add_tool_entry({
					id = tb.id,
					name = "thinking",
					kind = "thinking",
					line = line_idx - 1,
					result_text = thought,
				})
				if (opts.expanded_thinking_tools or {})[tb.id] then
					for _, l in ipairs(M.wrap_text(thought, text_width)) do
						add_line("  │ " .. l, "PiToolResult")
					end
					end
					last_render_kind = "tool"
					last_tool_kind = "thinking"
				end
			end

			if opts.streaming_live_thinking and opts.streaming_live_thinking ~= "" then
				if last_render_kind == "tool" then add_line("") end
				add_line("  ◇ thinking...", "PiToolCall")
				for _, l in ipairs(M.wrap_text(opts.streaming_live_thinking, text_width)) do
					add_line("  │ " .. l, "PiToolResult")
				end
				last_render_kind = "tool"
				last_tool_kind = "thinking"
			end

		for _, tool_id in ipairs(opts.streaming_tool_order or {}) do
			local tc = opts.streaming_tools_by_id and opts.streaming_tools_by_id[tool_id] or nil
			if tc then
				local file = tc.file or ""
				local cmd = tc.command or ""
				local suffix = tc.running and "  (running...)" or ""
				local tname_lower = type(tc.name) == "string" and tc.name:lower() or ""
				local body = tc.name

				if cmd ~= "" then
					local cmd_display = cmd:gsub("\n", " ")
					if vim.fn.strdisplaywidth(cmd_display) > 100 then
						cmd_display = vim.fn.strcharpart(cmd_display, 0, 97) .. "…"
					end
					body = tc.name .. "  " .. cmd_display
				elseif file ~= "" then
					body = tc.name .. "  " .. file
					if tname_lower == "read" or tname_lower == "read_file" then
						local interval = M.format_read_interval(tc.input)
						if interval ~= "" then
							body = body .. "  " .. interval
						end
					end
				end

				if (tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit")
					and tc.result and tc.result ~= "" then
					local diff_text = tc.details and tc.details.diff
					local stats = M.diff_stats(diff_text)
					if stats then
						body = body .. "  " .. stats
					end
				end

				local line_text = "  ▶ " .. M.truncate_text(body, section_width - 2) .. suffix
				local fstart = string.find(line_text, file, 1, true)
				if fstart then
					table.insert(highlights, { line_idx, "MoreMsg", fstart - 1, fstart + string.len(file) - 1 })
				end
				if tname_lower == "read" or tname_lower == "read_file" then
					local interval = M.format_read_interval(tc.input)
					if interval ~= "" then
						local istart = string.find(line_text, "  " .. interval, 1, true)
						if istart then
							table.insert(highlights, { line_idx, "WarningMsg", istart - 1, istart + string.len("  " .. interval) - 1 })
						end
					end
				elseif tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit" then
					local diff_text = tc.details and tc.details.diff
					local stats = M.diff_stats(diff_text)
					if stats then
						local sstart = string.find(line_text, "  " .. stats, 1, true)
						if sstart then
							local plus_start, plus_end = string.find(stats, "%+%d+")
							if plus_start then
								table.insert(highlights, { line_idx, "DiagnosticOk", sstart + plus_start, sstart + 1 + plus_end })
							end
							local minus_start, minus_end = string.find(stats, "%-%d+")
							if minus_start then
								table.insert(highlights, { line_idx, "DiagnosticError", sstart + minus_start, sstart + 1 + minus_end })
							end
						end
					end
				end
				add_line(line_text, "PiToolCall")
				add_tool_entry({
					id = tool_id,
					name = tc.name,
					kind = "tool",
					input = tc.input,
					line = line_idx - 1,
					details = tc.details,
					result_text = tc.result,
				})

				if tc.result and tc.result ~= "" then
					if tname_lower == "read" or tname_lower == "read_file" then
						if tc.id and expanded_read[tc.id] then
							local lines_shown = 0
							local max_lines = 10
							for _, l in ipairs(vim.split(tc.result, "\n")) do
								if lines_shown >= max_lines then
									add_line("  │ ...", "Comment")
									break
								end
								add_line("  │ " .. l, "PiToolResult")
								lines_shown = lines_shown + 1
							end
						end
					elseif tname_lower == "bash" then
						if tc.id and expanded_bash[tc.id] then
							local command = (tc.input and tc.input.command) or ""
							if command ~= "" then
								for _, l in ipairs(vim.split(command, "\n")) do
									add_line("  │ $ " .. l, "PiToolResult")
								end
							end
							for _, l in ipairs(vim.split(tc.result, "\n")) do
								add_line("  │ " .. l, "PiToolResult")
							end
						end
					elseif tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit" then
						local diff_text = tc.details and tc.details.diff
						local stats = M.diff_stats(diff_text)
						if not stats then
							local preview = tc.result:gsub("\n", " ")
							local marker = tc.is_partial_result and "◀~ " or "◀ "
							local prefix = marker .. tc.name .. ": "
							local available = math.max(section_width - 2 - vim.fn.strdisplaywidth(prefix), 12)
							preview = M.truncate_text(preview, available)
							add_line("  " .. marker .. tc.name .. ": " .. preview, "PiToolResult")
						end
					else
						local preview = tc.result:gsub("\n", " ")
						local marker = tc.is_partial_result and "◀~ " or "◀ "
						local prefix = marker .. tc.name .. ": "
						local available = math.max(section_width - 2 - vim.fn.strdisplaywidth(prefix), 12)
						preview = M.truncate_text(preview, available)
						add_line("  " .. marker .. tc.name .. ": " .. preview, "PiToolResult")
					end
				end
					last_render_kind = "tool"
					last_tool_kind = "tool"
				end
			end

			if opts.streaming_post_tool_text ~= "" then
				if last_render_kind == "tool" then add_line("") end
				local md_lines, md_hls = markdown.render(opts.streaming_post_tool_text, { width = text_width })
			for _, ml in ipairs(md_lines) do
				add_line("  " .. ml)
			end
			for _, hl in ipairs(md_hls) do
				table.insert(highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
			end
				last_render_kind = "text"
				last_tool_kind = nil
			end
	end

	return lines, highlights, tool_entries, streaming_start_idx
end

--- Render only the streaming section (assistant header + text + tools).
--- Used for incremental updates during streaming.
--- @param opts table Streaming state options
--- @param base_line_idx number Starting line index for highlights
--- @return table[], table[], table[] lines (array of {text, hl}), highlights, tool_entries
function M._render_streaming_section(opts, base_line_idx)
	local s_lines = {}
	local s_highlights = {}
	local s_tool_entries = {}
	local line_idx = base_line_idx or 0

	local section_width = math.max(opts.section_width or 20, 20)
	local text_width = math.max(opts.text_width or 18, 18)
	local separator = opts.separator or ("  " .. string.rep("━", section_width))
	local last_render_kind = opts.last_render_kind or "text"
	local last_tool_kind = opts.last_tool_kind
	local expanded_bash = opts.expanded_bash or {}
	local expanded_read = opts.expanded_read or {}
	local expanded_thinking = opts.expanded_thinking or {}

	local function add_line(value, hl_group)
		table.insert(s_lines, { value, hl_group })
		if hl_group then
			table.insert(s_highlights, { line_idx, hl_group })
		end
		line_idx = line_idx + 1
	end

	-- Assistant section header
	add_line("")
	add_line(separator, "PiSeparator")
	add_line("  Assistant  (typing...)", "PiAssistantHeader")
	add_line(separator, "PiSeparator")

	if opts.pre_tool_text ~= "" then
		if last_render_kind == "tool" then add_line("") end
		local md_lines, md_hls = markdown.render(opts.pre_tool_text, { width = text_width })
		for _, ml in ipairs(md_lines) do
			add_line("  " .. ml)
		end
		for _, hl in ipairs(md_hls) do
			table.insert(s_highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
		end
		last_render_kind = "text"
		last_tool_kind = nil
	end

	for _, tb in ipairs(opts.thinking_blocks or {}) do
		local thought = type(tb.text) == "string" and tb.text or ""
		if thought ~= "" then
			add_line("  ◇ " .. thinking_summary(thought), "PiToolCall")
			table.insert(s_tool_entries, {
				id = tb.id,
				name = "thinking",
				kind = "thinking",
				line = line_idx - 1,
				result_text = thought,
			})
			if tb.id and expanded_thinking[tb.id] then
				for _, l in ipairs(M.wrap_text(thought, text_width)) do
					add_line("  │ " .. l, "PiToolResult")
				end
			end
			last_render_kind = "tool"
			last_tool_kind = "thinking"
		end
	end

	if opts.live_thinking and opts.live_thinking ~= "" then
		if last_render_kind == "tool" then add_line("") end
		add_line("  ◇ thinking...", "PiToolCall")
		for _, l in ipairs(M.wrap_text(opts.live_thinking, text_width)) do
			add_line("  │ " .. l, "PiToolResult")
		end
		last_render_kind = "tool"
		last_tool_kind = "thinking"
	end

	for _, tool_id in ipairs(opts.tool_order or {}) do
		local tc = opts.tools_by_id[tool_id]
		if tc then
			local file = tc.file or ""
			local cmd = tc.command or ""
			local suffix = tc.running and "  (running...)" or ""
			local tname_lower = type(tc.name) == "string" and tc.name:lower() or ""
			local body = tc.name

			if cmd ~= "" then
				local cmd_display = cmd:gsub("\n", " ")
				if vim.fn.strdisplaywidth(cmd_display) > 100 then
					cmd_display = vim.fn.strcharpart(cmd_display, 0, 97) .. "…"
				end
				body = tc.name .. "  " .. cmd_display
			elseif file ~= "" then
				body = tc.name .. "  " .. file
				if tname_lower == "read" or tname_lower == "read_file" then
					local interval = M.format_read_interval(tc.input)
					if interval ~= "" then
						body = body .. "  " .. interval
					end
				end
			end

			if (tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit")
				and tc.result and tc.result ~= "" then
				local diff_text = tc.details and tc.details.diff
				local stats = M.diff_stats(diff_text)
				if stats then
					body = body .. "  " .. stats
				end
			end

			local line_text = "  ▶ " .. M.truncate_text(body, section_width - 2) .. suffix
			local fstart = string.find(line_text, file, 1, true)
			if fstart then
				table.insert(s_highlights, { line_idx, "MoreMsg", fstart - 1, fstart + string.len(file) - 1 })
			end
			if tname_lower == "read" or tname_lower == "read_file" then
				local interval = M.format_read_interval(tc.input)
				if interval ~= "" then
					local istart = string.find(line_text, "  " .. interval, 1, true)
					if istart then
						table.insert(s_highlights, { line_idx, "WarningMsg", istart - 1, istart + string.len("  " .. interval) - 1 })
					end
				end
			elseif tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit" then
				local diff_text = tc.details and tc.details.diff
				local stats = M.diff_stats(diff_text)
				if stats then
					local sstart = string.find(line_text, "  " .. stats, 1, true)
					if sstart then
						local plus_start, plus_end = string.find(stats, "%+%d+")
						if plus_start then
							table.insert(s_highlights, { line_idx, "DiagnosticOk", sstart + plus_start, sstart + 1 + plus_end })
						end
						local minus_start, minus_end = string.find(stats, "%-%d+")
						if minus_start then
							table.insert(s_highlights, { line_idx, "DiagnosticError", sstart + minus_start, sstart + 1 + minus_end })
						end
					end
				end
			end
			add_line(line_text, "PiToolCall")
			table.insert(s_tool_entries, {
				id = tool_id,
				name = tc.name,
				kind = "tool",
				input = tc.input,
				line = line_idx - 1,
				details = tc.details,
				result_text = tc.result,
			})

			if tc.result and tc.result ~= "" then
				if tname_lower == "read" or tname_lower == "read_file" then
					if tc.id and expanded_read[tc.id] then
						local lines_shown = 0
						local max_lines = 10
						for _, l in ipairs(vim.split(tc.result, "\n")) do
							if lines_shown >= max_lines then
								add_line("  │ ...", "Comment")
								break
							end
							add_line("  │ " .. l, "PiToolResult")
							lines_shown = lines_shown + 1
						end
					end
				elseif tname_lower == "bash" then
					if tc.id and expanded_bash[tc.id] then
						local command = (tc.input and tc.input.command) or ""
						if command ~= "" then
							for _, l in ipairs(vim.split(command, "\n")) do
								add_line("  │ $ " .. l, "PiToolResult")
							end
						end
						for _, l in ipairs(vim.split(tc.result, "\n")) do
							add_line("  │ " .. l, "PiToolResult")
						end
					end
				elseif tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit" then
					local diff_text = tc.details and tc.details.diff
					local stats = M.diff_stats(diff_text)
					if not stats then
						local preview = tc.result:gsub("\n", " ")
						local marker = tc.is_partial_result and "◀~ " or "◀ "
						local prefix = marker .. tc.name .. ": "
						local available = math.max(section_width - 2 - vim.fn.strdisplaywidth(prefix), 12)
						preview = M.truncate_text(preview, available)
						add_line("  " .. marker .. tc.name .. ": " .. preview, "PiToolResult")
					end
				else
					local preview = tc.result:gsub("\n", " ")
					local marker = tc.is_partial_result and "◀~ " or "◀ "
					local prefix = marker .. tc.name .. ": "
					local available = math.max(section_width - 2 - vim.fn.strdisplaywidth(prefix), 12)
					preview = M.truncate_text(preview, available)
					add_line("  " .. marker .. tc.name .. ": " .. preview, "PiToolResult")
				end
			end
			last_render_kind = "tool"
			last_tool_kind = "tool"
		end
	end

	if opts.post_tool_text ~= "" then
		if last_render_kind == "tool" then add_line("") end
		local md_lines, md_hls = markdown.render(opts.post_tool_text, { width = text_width })
		for _, ml in ipairs(md_lines) do
			add_line("  " .. ml)
		end
		for _, hl in ipairs(md_hls) do
			table.insert(s_highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
		end
		last_render_kind = "text"
		last_tool_kind = nil
	end

	return s_lines, s_highlights, s_tool_entries
end
return M

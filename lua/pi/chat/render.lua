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
					file = input.file_path or input.filePath or input.path or input.file or input.filename or "",
					command = input.command or "",
					details = tc.details,
					result = tc.result,
					is_error = tc.is_error == true or tc.isError == true,
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
						file = args.file_path or args.filePath or args.path or args.file or args.filename or "",
						command = args.command or "",
						details = block.details,
						result = block.result,
						is_error = block.is_error == true or block.isError == true,
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
		or input.from_line or input.fromLine or input.start or input.from
	local end_line = input.end_line or input.endLine or input.line_end or input.lineEnd
		or input.to_line or input.toLine or input["end"] or input.to
	if type(input.interval) == "string" and input.interval ~= "" then
		return input.interval
	end
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
	local char_count = vim.fn.strchars(text)
	local lo, hi, best = 0, char_count, 0
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local chunk = vim.fn.strcharpart(text, 0, mid)
		if vim.fn.strdisplaywidth(chunk .. "…") <= width then
			best = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	if best <= 0 then return "…" end
	return vim.fn.strcharpart(text, 0, best) .. "…"
end

function M.wrap_text(text, width)
	if not text or text == "" then return { "" } end
	width = math.max(1, width or 1)
	local result = {}
	local function append_ascii_wrapped(line)
		local current = {}
		local current_width = 0
		local last_space_idx = nil
		for i = 1, #line do
			local ch = line:sub(i, i)
			local ch_width = ch == "\t" and 3 or 1
			if current_width + ch_width > width and #current > 0 then
				local split_idx = last_space_idx or #current
				local head = table.concat(current, "", 1, split_idx):gsub("%s+$", "")
				if head ~= "" then table.insert(result, head) end
				local rest = {}
				for j = split_idx + 1, #current do
					if not (#rest == 0 and current[j]:match("^%s$")) then
						table.insert(rest, current[j])
					end
				end
				current = rest
				current_width = #table.concat(current)
				last_space_idx = nil
				for j, existing in ipairs(current) do
					if existing:match("^%s$") then last_space_idx = j end
				end
			end
			if not (#current == 0 and ch:match("^%s$")) then
				table.insert(current, ch)
				current_width = current_width + ch_width
				if ch:match("^%s$") then last_space_idx = #current end
			end
		end
		local tail = table.concat(current):gsub("%s+$", "")
		if tail ~= "" then table.insert(result, tail) end
	end
	for _, raw in ipairs(vim.split(text, "\n")) do
		local line = raw:gsub("\x1b%[[%d;]*m", "")
		if line == "" then
			table.insert(result, "")
		elseif vim.fn.strdisplaywidth(line) <= width then
			table.insert(result, line)
		elseif not line:find("[\128-\255]") then
			append_ascii_wrapped(line)
		else
			local parts = {}
			local current = {}
			local current_width = 0
			local last_space_idx = nil
			local chars = vim.fn.strchars(line)
			for i = 0, chars - 1 do
				local ch = vim.fn.strcharpart(line, i, 1)
				local ch_width = math.max(1, vim.fn.strdisplaywidth(ch))
				if current_width + ch_width > width and #current > 0 then
					local split_idx = last_space_idx or #current
					local head = table.concat(current, "", 1, split_idx):gsub("%s+$", "")
					if head ~= "" then table.insert(parts, head) end
					local rest = {}
					for j = split_idx + 1, #current do
						if not (#rest == 0 and current[j]:match("^%s$")) then
							table.insert(rest, current[j])
						end
					end
					current = rest
					current_width = vim.fn.strdisplaywidth(table.concat(current))
					last_space_idx = nil
					for j, existing in ipairs(current) do
						if existing:match("^%s$") then last_space_idx = j end
					end
				end
				if not (#current == 0 and ch:match("^%s$")) then
					table.insert(current, ch)
					current_width = current_width + ch_width
					if ch:match("^%s$") then last_space_idx = #current end
				end
			end
			local tail = table.concat(current):gsub("%s+$", "")
			if tail ~= "" then table.insert(parts, tail) end
			for _, part in ipairs(parts) do
				table.insert(result, part)
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

function M.extract_images(msg)
	local images = {}
	if not msg then return images end
	local content = msg.content
	if type(content) == "table" then
		for _, block in ipairs(content) do
			if block.type == "image" then
				table.insert(images, block)
			end
		end
	end
	return images
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

local function live_thinking_preview(thought)
	if type(thought) ~= "string" or thought == "" then return "" end
	local max_chars = 2500
	local chars = vim.fn.strchars(thought)
	if chars <= max_chars then return thought end
	return "... " .. vim.fn.strcharpart(thought, chars - max_chars, max_chars)
end

local function build_streaming_event_list(opts)
	local events = {}
	local text_by_id = {}
	for _, tb in ipairs(opts.text_blocks or {}) do
		if tb and tb.id then
			text_by_id[tb.id] = tb
		end
	end
	local thinking_by_id = {}
	for _, tb in ipairs(opts.thinking_blocks or {}) do
		if tb and tb.id then
			thinking_by_id[tb.id] = tb
		end
	end
	local order = opts.event_order or {}
	for _, ev in ipairs(order) do
		if ev.kind == "text" and ev.id then
			local text_block = text_by_id[ev.id]
			if text_block and type(text_block.text) == "string" and text_block.text ~= "" then
				table.insert(events, { kind = "text", id = ev.id, text = text_block.text })
			else
				local live_text = opts.live_text_blocks and opts.live_text_blocks[ev.id] or nil
				if type(live_text) == "string" and live_text ~= "" then
					table.insert(events, { kind = "text_live", id = ev.id, text = live_text })
				end
			end
		elseif ev.kind == "thinking" and ev.id then
			local thought = thinking_by_id[ev.id]
			if thought and type(thought.text) == "string" and thought.text ~= "" then
				table.insert(events, { kind = "thinking", id = ev.id, text = thought.text })
			elseif opts.live_thinking_id and ev.id == opts.live_thinking_id and opts.live_thinking and opts.live_thinking ~= "" then
				table.insert(events, { kind = "thinking_live", id = ev.id, text = opts.live_thinking })
			end
		elseif ev.kind == "tool" and ev.id then
			local tc = opts.tools_by_id and opts.tools_by_id[ev.id] or nil
			if tc then
				table.insert(events, { kind = "tool", id = ev.id, tc = tc })
			end
		end
	end
	return events
end

local function build_streaming_tool_line(tc, section_width)
	local file = tc.file
		or (type(tc.input) == "table" and (tc.input.file_path or tc.input.filePath or tc.input.path or tc.input.file or tc.input.filename))
		or (type(tc.details) == "table" and (tc.details.file_path or tc.details.filePath or tc.details.path or tc.details.file))
		or ""
	local cmd = tc.command or ""
	local suffix = tc.running and "  (running...)" or ""
	local tname_lower = type(tc.name) == "string" and tc.name:lower() or ""
	local body = tc.name
	local read_interval = ""
	local stats = nil
	local stats_included = false

	if tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit" then
		local diff_text = tc.details and tc.details.diff
		stats = M.diff_stats(diff_text)
	end

	if cmd ~= "" then
		local cmd_display = cmd:gsub("\n", " ")
		if vim.fn.strdisplaywidth(cmd_display) > 100 then
			cmd_display = vim.fn.strcharpart(cmd_display, 0, 97) .. "…"
		end
		body = tc.name .. "  " .. cmd_display
		elseif file ~= "" then
			if tname_lower == "read" or tname_lower == "read_file" then
				read_interval = M.format_read_interval(tc.input)
				if read_interval == "" then
					read_interval = M.format_read_interval(tc.details)
				end
				if read_interval ~= "" then
				local name_prefix = tc.name .. "  "
				local interval_suffix = "  " .. read_interval
				local avail_file = math.max(
					8,
					section_width - 2 - vim.fn.strdisplaywidth(name_prefix) - vim.fn.strdisplaywidth(interval_suffix)
				)
				body = name_prefix .. M.truncate_text(file, avail_file) .. interval_suffix
			else
				body = tc.name .. "  " .. file
			end
		elseif (tname_lower == "write" or tname_lower == "write_file" or tname_lower == "edit") and stats then
			local name_prefix = tc.name .. "  "
			local stats_suffix = "  " .. stats
			local avail_file = math.max(
				8,
				section_width - 2 - vim.fn.strdisplaywidth(name_prefix) - vim.fn.strdisplaywidth(stats_suffix)
			)
			body = name_prefix .. M.truncate_text(file, avail_file) .. stats_suffix
			stats_included = true
		else
			body = tc.name .. "  " .. file
		end
	end

	if stats and not stats_included then
		body = body .. "  " .. stats
	end

	local prefix = tc.is_error and "  ✗ " or "  ▶ "
	local hl_group = tc.is_error and "DiagnosticError" or "PiToolCall"
	local line_text = prefix .. M.truncate_text(body, section_width - 2) .. suffix
	return line_text, file, read_interval, stats, tname_lower, hl_group
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
	local assistant_section_open = false
	local last_render_kind = nil
	local last_tool_kind = nil

	local function add_line(value, hl_group)
		table.insert(lines, text.sanitize_line(value))
		if hl_group then
			table.insert(highlights, { line_idx, hl_group })
		end
		line_idx = line_idx + 1
	end

	local function render_error_text(error_text)
		if type(error_text) ~= "string" or error_text == "" then return end
		if last_render_kind == "tool" then add_line("") end
		local wrapped = M.wrap_text(error_text, math.max(text_width, 20))
		for _, wl in ipairs(wrapped) do
			add_line("  ! " .. wl, "DiagnosticError")
		end
		last_render_kind = "text"
		last_tool_kind = nil
	end

	local function add_tool_entry(entry)
		table.insert(tool_entries, entry)
	end

	if #opts.messages == 0 and not opts.is_streaming then
		add_line("")
		add_line("  No messages yet. Type in the input bar below.", "Comment")
		return lines, highlights, tool_entries
	end

	local model_text = "  pi"
	if opts.current_model and opts.current_model ~= "" then
		model_text = model_text .. "  " .. opts.current_model
		if opts.current_model_reasoning and opts.current_thinking_level and opts.current_thinking_level ~= "" and opts.current_thinking_level ~= "off" then
			model_text = model_text .. "  (thinking: " .. opts.current_thinking_level .. ")"
		end
	end
	add_line(model_text, "Title")
	if opts.start_idx and opts.start_idx > 1 then
		add_line("  [showing last " .. tostring(#opts.messages) .. " of " .. tostring(opts.total_messages) .. " messages]", "Comment")
	end
	add_line("")

	local pending_tools = {}
	local pending_tool_order = {}
	local tool_call_info = {}

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

	local function render_static_text(content)
		if type(content) ~= "string" or content == "" then return end
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

	local function render_static_thinking(thought, thinking_id)
		if type(thought) ~= "string" or thought == "" then return end
		if last_render_kind == "text" then add_line("") end
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
		last_render_kind = "tool"
		last_tool_kind = "thinking"
	end

	local function normalize_static_tool_call(tc)
		if not tc then return nil end
		if tc.type == "toolCall" then
			local args = tc.arguments or {}
			if type(args) == "string" then
				local ok, p = pcall(vim.fn.json_decode, args)
				if ok then args = p end
			end
				return {
					id = tc.id,
					name = tc.name or "?",
					input = args,
					file = args.file_path or args.filePath or args.path or args.file or args.filename or "",
					command = args.command or "",
					details = tc.details,
					result = tc.result,
					is_error = tc.is_error == true or tc.isError == true,
				}
		end
		return tc
	end

	local function render_static_tool(tc)
		tc = normalize_static_tool_call(tc)
		if not tc then return end
		if last_render_kind == "text" then add_line("") end

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
				local prefix = tc.is_error and "  ✗ " or "  ▶ "
				local hl_group = tc.is_error and "DiagnosticError" or "PiToolCall"
				local line_text = prefix .. M.truncate_text(body, section_width - 2)
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
				add_line(line_text, hl_group)
			elseif cmd ~= "" then
			local cmd_display = cmd:gsub("\n", " ")
			if vim.fn.strdisplaywidth(cmd_display) > 100 then
				cmd_display = vim.fn.strcharpart(cmd_display, 0, 97) .. "…"
			end
			local body = tc.name .. "  " .. cmd_display
			tool_call_info[tool_id] = { line_idx = line_idx, body = body, file = file }
				local prefix = tc.is_error and "  ✗ " or "  ▶ "
				local hl_group = tc.is_error and "DiagnosticError" or "PiToolCall"
				add_line(prefix .. M.truncate_text(body, section_width - 2), hl_group)
			else
				tool_call_info[tool_id] = { line_idx = line_idx, body = tc.name }
				local prefix = tc.is_error and "  ✗ " or "  ▶ "
				local hl_group = tc.is_error and "DiagnosticError" or "PiToolCall"
				add_line(prefix .. tc.name, hl_group)
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
			last_render_kind = "tool"
			last_tool_kind = "tool"
			if tc.is_error and tc.result and tc.result ~= "" then
				for _, l in ipairs(vim.split(tc.result, "\n")) do
					add_line("  │ " .. l, "DiagnosticError")
				end
			end
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
			-- Show image attachments
			local images = M.extract_images(msg)
			if #images > 0 then
				if not content or content == "" then
					open_user_section()
				end
				for _, img in ipairs(images) do
					local label = img.mimeType and ("[image: " .. img.mimeType:gsub("image/", "") .. "]") or "[image]"
					add_line("  " .. label, "Comment")
				end
				last_render_kind = "text"
			end
		elseif msg.role == "assistant" then
			if msg.is_error then
				open_assistant_section("Error")
				render_error_text(M.extract_text(msg) or "")
			else
				open_assistant_section("Assistant")

				if type(msg.content) == "table" then
					local thinking_idx = 0
					for _, block in ipairs(msg.content) do
						if block.type == "thinking" then
							thinking_idx = thinking_idx + 1
							local thinking_id = "thinking_" .. tostring(msg.timestamp or msg_idx) .. "_" .. tostring(thinking_idx)
							render_static_thinking(block.thinking, thinking_id)
						elseif block.type == "text" then
							render_static_text(block.text)
						elseif block.type == "toolCall" then
							render_static_tool(block)
						end
					end

					if msg.tool_calls and type(msg.tool_calls) == "table" then
						for _, tc in ipairs(M.extract_tool_calls({ tool_calls = msg.tool_calls })) do
							render_static_tool(tc)
						end
					end
				else
					render_static_text(M.extract_text(msg))
					for _, tc in ipairs(M.extract_tool_calls(msg)) do
						render_static_tool(tc)
					end
				end
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
				local stream_events = build_streaming_event_list({
					text_blocks = opts.streaming_text_blocks,
					live_text_blocks = opts.streaming_live_text_blocks,
					thinking_blocks = opts.streaming_thinking_blocks,
					live_thinking = opts.streaming_live_thinking,
					live_thinking_id = opts.streaming_live_thinking_id,
					event_order = opts.streaming_event_order,
					tools_by_id = opts.streaming_tools_by_id,
					tool_order = opts.streaming_tool_order,
				})
				for _, ev in ipairs(stream_events) do
					if ev.kind == "text" or ev.kind == "text_live" then
						if last_render_kind == "tool" then add_line("") end
						local md_lines, md_hls = markdown.render(ev.text or "", { width = text_width })
						for _, ml in ipairs(md_lines) do
							add_line("  " .. ml)
						end
						for _, hl in ipairs(md_hls) do
							table.insert(highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
						end
						last_render_kind = "text"
						last_tool_kind = nil
					elseif ev.kind == "thinking" or ev.kind == "thinking_live" then
						if last_render_kind == "text" then add_line("") end
						if ev.kind == "thinking_live" then
							add_line("  ◇ thinking...", "PiToolCall")
							for _, l in ipairs(M.wrap_text(live_thinking_preview(ev.text), text_width)) do
								add_line("  │ " .. l, "PiToolResult")
							end
						else
							add_line("  ◇ " .. thinking_summary(ev.text), "PiToolCall")
							add_tool_entry({
								id = ev.id,
								name = "thinking",
								kind = "thinking",
								line = line_idx - 1,
								result_text = ev.text,
							})
							if (opts.expanded_thinking_tools or {})[ev.id] then
								for _, l in ipairs(M.wrap_text(ev.text, text_width)) do
									add_line("  │ " .. l, "PiToolResult")
								end
							end
						end
						last_render_kind = "tool"
						last_tool_kind = "thinking"
				elseif ev.kind == "tool" and ev.tc then
					local tc = ev.tc
					local line_text, file, read_interval, stats, tname_lower, hl_group = build_streaming_tool_line(tc, section_width)
					local fstart = string.find(line_text, file, 1, true)
					if fstart then
						table.insert(highlights, { line_idx, "MoreMsg", fstart - 1, fstart + string.len(file) - 1 })
					end
					if read_interval ~= "" then
						local istart = string.find(line_text, "  " .. read_interval, 1, true)
						if istart then
							table.insert(highlights, { line_idx, "WarningMsg", istart - 1, istart + string.len("  " .. read_interval) - 1 })
						end
					elseif stats then
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
					add_line(line_text, hl_group)
					add_tool_entry({
						id = tc.id,
						name = tc.name,
						kind = "tool",
						input = tc.input,
						line = line_idx - 1,
						details = tc.details,
						result_text = tc.result,
					})

					if tc.result and tc.result ~= "" then
						if tc.is_error then
							local result_lines = vim.split(tc.result, "\n")
							for _, rl in ipairs(result_lines) do
								add_line("  │ " .. rl, "DiagnosticError")
							end
						elseif tname_lower == "read" or tname_lower == "read_file" then
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

	local stream_events = build_streaming_event_list({
		text_blocks = opts.text_blocks,
		live_text_blocks = opts.live_text_blocks,
		thinking_blocks = opts.thinking_blocks,
		live_thinking = opts.live_thinking,
		live_thinking_id = opts.live_thinking_id,
		event_order = opts.event_order,
		tools_by_id = opts.tools_by_id,
		tool_order = opts.tool_order,
	})
	for _, ev in ipairs(stream_events) do
		if ev.kind == "text" or ev.kind == "text_live" then
			if last_render_kind == "tool" then add_line("") end
			local md_lines, md_hls = markdown.render(ev.text or "", { width = text_width })
			for _, ml in ipairs(md_lines) do
				add_line("  " .. ml)
			end
			for _, hl in ipairs(md_hls) do
				table.insert(s_highlights, { line_idx - #md_lines + hl[1], hl[2], 2 + hl[3], 2 + hl[4] })
			end
			last_render_kind = "text"
			last_tool_kind = nil
		elseif ev.kind == "thinking" or ev.kind == "thinking_live" then
			if last_render_kind == "text" then add_line("") end
			if ev.kind == "thinking_live" then
				add_line("  ◇ thinking...", "PiToolCall")
				for _, l in ipairs(M.wrap_text(live_thinking_preview(ev.text), text_width)) do
					add_line("  │ " .. l, "PiToolResult")
				end
			else
				add_line("  ◇ " .. thinking_summary(ev.text), "PiToolCall")
				table.insert(s_tool_entries, {
					id = ev.id,
					name = "thinking",
					kind = "thinking",
					line = line_idx - 1,
					result_text = ev.text,
				})
				if ev.id and expanded_thinking[ev.id] then
					for _, l in ipairs(M.wrap_text(ev.text, text_width)) do
						add_line("  │ " .. l, "PiToolResult")
					end
				end
			end
			last_render_kind = "tool"
			last_tool_kind = "thinking"
		elseif ev.kind == "tool" and ev.tc then
			local tc = ev.tc
			local line_text, file, read_interval, stats, tname_lower, hl_group = build_streaming_tool_line(tc, section_width)
			local fstart = string.find(line_text, file, 1, true)
			if fstart then
				table.insert(s_highlights, { line_idx, "MoreMsg", fstart - 1, fstart + string.len(file) - 1 })
			end
			if read_interval ~= "" then
				local istart = string.find(line_text, "  " .. read_interval, 1, true)
				if istart then
					table.insert(s_highlights, { line_idx, "WarningMsg", istart - 1, istart + string.len("  " .. read_interval) - 1 })
				end
			elseif stats then
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
			add_line(line_text, hl_group)
			table.insert(s_tool_entries, {
				id = tc.id,
				name = tc.name,
				kind = "tool",
				input = tc.input,
				line = line_idx - 1,
				details = tc.details,
				result_text = tc.result,
			})

			if tc.result and tc.result ~= "" then
				if tc.is_error then
					local result_lines = vim.split(tc.result, "\n")
					for _, rl in ipairs(result_lines) do
						add_line("  │ " .. rl, "DiagnosticError")
					end
				elseif tname_lower == "read" or tname_lower == "read_file" then
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

	return s_lines, s_highlights, s_tool_entries
end
return M

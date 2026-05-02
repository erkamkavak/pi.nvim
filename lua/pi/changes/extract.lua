local git = require("pi.util.git")
local text = require("pi.util.text")

local M = {}

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

--- Extract last-turn edit diffs from session messages.
--- @param messages table[]
--- @return { user_text: string|nil, turn_diffs: table[] }|nil
function M.last_turn(messages)
	if not messages or #messages == 0 then return nil end

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
		return { user_text = nil, turn_diffs = {} }
	end

	local user_text = text.extract_message_text(last_user_msg, { detect_garbled = false })
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
						local diff_text = git.get_diff_for_file(source, { notify_no_diff = false })
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

	return {
		user_text = user_text,
		turn_diffs = turn_diffs,
	}
end

return M

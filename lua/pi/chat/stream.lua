local M = {}

function M.new_state()
	return {
		text_blocks = {},
		live_text_blocks = {},
		text_ids_by_content = {},
		live_thinking = "",
		live_thinking_id = nil,
		thinking_blocks = {},
		thinking_seq = 0,
		event_seq = 0,
		event_order = {},
		saw_tool_activity = false,
		tools_by_id = {},
		tool_order = {},
		is_streaming = false,
		last_render = 0,
		handlers_registered = false,
	}
end

function M.reset(state)
	state.text_blocks = {}
	state.live_text_blocks = {}
	state.text_ids_by_content = {}
	state.live_thinking = ""
	state.live_thinking_id = nil
	state.thinking_blocks = {}
	state.thinking_seq = 0
	state.event_seq = 0
	state.event_order = {}
	state.saw_tool_activity = false
	state.tools_by_id = {}
	state.tool_order = {}
	state.last_render = 0
end

local function next_event_seq(state)
	state.event_seq = (state.event_seq or 0) + 1
	return state.event_seq
end

local function find_thinking_block(state, id)
	if not id then return nil end
	for _, block in ipairs(state.thinking_blocks or {}) do
		if block.id == id then return block end
	end
	return nil
end

local function find_text_block(state, id)
	if not id then return nil end
	for _, block in ipairs(state.text_blocks or {}) do
		if block.id == id then return block end
	end
	return nil
end

local function ensure_text_event_id(state, content_index)
	local key = tostring(content_index or -1)
	local existing = state.text_ids_by_content[key]
	if existing and existing ~= "" then return existing end
	local seq = next_event_seq(state)
	local id = "text_stream_" .. tostring(seq)
	state.text_ids_by_content[key] = id
	table.insert(state.event_order, { kind = "text", id = id, seq = seq })
	return id
end

local function finalize_text_block(state, id, text_value)
	if type(text_value) ~= "string" or text_value == "" then
		state.live_text_blocks[id] = nil
		return
	end
	local existing = find_text_block(state, id)
	if existing then
		existing.text = text_value
	else
		table.insert(state.text_blocks, { id = id, text = text_value })
	end
	state.live_text_blocks[id] = nil
end

local function finalize_all_live_text(state)
	for id, text_value in pairs(state.live_text_blocks or {}) do
		finalize_text_block(state, id, text_value)
	end
end

local function finalize_live_thinking(state)
	local thought = state.live_thinking
	local thought_id = state.live_thinking_id
	if type(thought) ~= "string" or thought == "" then
		state.live_thinking = ""
		state.live_thinking_id = nil
		return
	end
	state.thinking_seq = (state.thinking_seq or 0) + 1
	if not thought_id or thought_id == "" then
		local seq = next_event_seq(state)
		thought_id = "thinking_stream_" .. tostring(seq)
		table.insert(state.event_order, { kind = "thinking", id = thought_id, seq = seq })
	end
	local existing = find_thinking_block(state, thought_id)
	if existing then
		existing.text = thought
	else
		table.insert(state.thinking_blocks, {
			id = thought_id,
			text = thought,
		})
	end
	state.live_thinking = ""
	state.live_thinking_id = nil
end

local function extract_command_from_partial_json(partial_json)
	if not partial_json or partial_json == "" then return nil end
	local ok, parsed = pcall(vim.fn.json_decode, partial_json)
	if ok and type(parsed) == "table" and type(parsed.command) == "string" then
		return parsed.command
	end
	local start_idx = partial_json:find([["command"%s*:%s*"]])
	if not start_idx then return nil end
	local value = partial_json:sub(start_idx):match([["command"%s*:%s*"([^"]*)$]])
	if not value then return nil end
	value = value:gsub('\\"', '"'):gsub("\\n", "\n"):gsub("\\\\", "\\")
	return value
end

local function extract_tool_result_text(result)
	if not result then return nil end
	local content = result.content
	if type(content) ~= "table" then return nil end
	local parts = {}
	for _, block in ipairs(content) do
		if block.type == "text" and block.text then
			table.insert(parts, block.text)
		end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, "\n")
end

local function extract_tool_details(payload)
	if type(payload) ~= "table" then return nil end
	if type(payload.details) == "table" then return payload.details end
	if type(payload.result) == "table" and type(payload.result.details) == "table" then
		return payload.result.details
	end
	if type(payload.partialResult) == "table" and type(payload.partialResult.details) == "table" then
		return payload.partialResult.details
	end
	return nil
end

function M.upsert_tool_call(state, id, name, input)
	if not id or id == "" then
		id = "tool_" .. tostring(#state.tool_order + 1)
	end

	local tc = state.tools_by_id[id]
	if not tc then
		tc = {
			id = id,
			name = name or "?",
			input = {},
			partial_json = "",
			command = "",
			file = "",
			result = nil,
			running = false,
			is_partial_result = false,
			is_error = false,
		}
		state.tools_by_id[id] = tc
		table.insert(state.tool_order, id)
		local seq = next_event_seq(state)
		table.insert(state.event_order, { kind = "tool", id = id, seq = seq })
	end

	if name and name ~= "" then
		tc.name = name
	end

	if type(input) == "table" then
		tc.input = input
		tc.file = input.file_path or input.filePath or input.path or input.file or input.filename or tc.file
		local cmd = input.command
		if type(cmd) == "string" and cmd ~= "" then
			tc.command = cmd
		end
	end

	return tc
end

-- ---------------------------------------------------------------------------
-- Throttled rendering
-- ---------------------------------------------------------------------------

local render_timer = nil
local MIN_RENDER_INTERVAL_MS = 16

--- Cancel any pending scheduled render.
local function cancel_scheduled_render()
	if render_timer then
		pcall(vim.fn.timer_stop, render_timer)
		render_timer = nil
	end
end

--- Schedule a throttled render.
--- Batches rapid streaming updates so we don't render on every single chunk.
local function schedule_render(state, is_open, on_render)
	if render_timer then return end
	local elapsed = vim.loop.now() - state.last_render
	local delay = math.max(0, MIN_RENDER_INTERVAL_MS - elapsed)
	render_timer = vim.defer_fn(function()
		render_timer = nil
		if not is_open() then return end
		state.last_render = vim.loop.now()
		on_render()
	end, delay)
end

--- Register client stream handlers once.
--- @param opts { client: table, state: table, is_open: fun():boolean, on_render: fun(), on_refresh: fun() }
function M.ensure_handlers(opts)
	local state = opts.state
	if state.handlers_registered then return end
	state.handlers_registered = true

	opts.client.on_event("message_update", function(event)
		if not event or not event.message then return end
		if event.message.role ~= "assistant" then return end

		state.is_streaming = true

		if event.message.content and type(event.message.content) == "table" then
			for block_idx, block in ipairs(event.message.content) do
				if block.type == "toolCall" then
					local args = block.arguments or {}
					if type(args) == "string" then
						local ok, parsed = pcall(vim.fn.json_decode, args)
						if ok then args = parsed end
					end
					local fallback_id = "content_" .. tostring(block_idx)
					M.upsert_tool_call(state, block.id or fallback_id, block.name, args)
				end
			end
		end

		local assistant_event = event.assistantMessageEvent
		if assistant_event and assistant_event.type == "text_start" then
			local text_id = ensure_text_event_id(state, assistant_event.contentIndex)
			state.live_text_blocks[text_id] = state.live_text_blocks[text_id] or ""
		elseif assistant_event and assistant_event.type == "text_delta" then
			local text_id = ensure_text_event_id(state, assistant_event.contentIndex)
			state.live_text_blocks[text_id] = (state.live_text_blocks[text_id] or "") .. (assistant_event.delta or "")
		elseif assistant_event and assistant_event.type == "text_end" then
			local text_id = ensure_text_event_id(state, assistant_event.contentIndex)
			local text_value = assistant_event.content
			if type(text_value) ~= "string" then
				text_value = state.live_text_blocks[text_id] or ""
			end
			finalize_text_block(state, text_id, text_value)
		elseif assistant_event and assistant_event.type == "toolcall_delta" then
			local content_idx = (assistant_event.contentIndex or 0) + 1
			local block = event.message.content and event.message.content[content_idx] or nil
			local fallback_id = "content_" .. tostring(content_idx)
			local tool_id = (block and block.id) or fallback_id
			local tool_name = (block and block.name) or "bash"
			local tc = M.upsert_tool_call(state, tool_id, tool_name, (block and block.arguments) or {})
			tc.partial_json = (tc.partial_json or "") .. (assistant_event.delta or "")
			local partial_command = extract_command_from_partial_json(tc.partial_json)
			if partial_command and partial_command ~= "" then
				tc.command = partial_command
			end
		elseif assistant_event and assistant_event.type == "toolcall_end" and assistant_event.toolCall then
			M.upsert_tool_call(
				state,
				assistant_event.toolCall.id,
				assistant_event.toolCall.name,
				assistant_event.toolCall.arguments or {}
			)
		elseif assistant_event and assistant_event.type == "thinking_start" then
			if not state.live_thinking_id then
				local seq = next_event_seq(state)
				local tid = "thinking_stream_" .. tostring(seq)
				state.live_thinking_id = tid
				table.insert(state.event_order, { kind = "thinking", id = tid, seq = seq })
			end
			state.live_thinking = ""
		elseif assistant_event and assistant_event.type == "thinking_delta" then
			if not state.live_thinking_id then
				local seq = next_event_seq(state)
				local tid = "thinking_stream_" .. tostring(seq)
				state.live_thinking_id = tid
				table.insert(state.event_order, { kind = "thinking", id = tid, seq = seq })
			end
			state.live_thinking = (state.live_thinking or "") .. (assistant_event.delta or "")
		elseif assistant_event and assistant_event.type == "thinking_end" then
			if not state.live_thinking_id then
				local seq = next_event_seq(state)
				local tid = "thinking_stream_" .. tostring(seq)
				state.live_thinking_id = tid
				table.insert(state.event_order, { kind = "thinking", id = tid, seq = seq })
			end
			if type(assistant_event.content) == "string" and assistant_event.content ~= "" then
				state.live_thinking = assistant_event.content
			end
			finalize_live_thinking(state)
		end

		vim.schedule(function()
			schedule_render(state, opts.is_open, opts.on_render)
		end)
	end)

	opts.client.on_event("message_end", function(event)
		if not event or not event.message then return end
		if event.message.role ~= "assistant" then return end
		-- Final render after assistant message is complete (not throttled)
		vim.schedule(function()
			cancel_scheduled_render()
			finalize_all_live_text(state)
			finalize_live_thinking(state)
			if opts.is_open() then opts.on_render() end
		end)
	end)

	opts.client.on_event("agent_end", function()
		vim.schedule(function()
			cancel_scheduled_render()
			state.is_streaming = false
			M.reset(state)
			opts.on_refresh()
		end)
	end)

	opts.client.on_event("tool_execution_start", function(event)
		if not event then return end
		state.is_streaming = true
		state.saw_tool_activity = true
		finalize_all_live_text(state)
		finalize_live_thinking(state)
		local tc = M.upsert_tool_call(state, event.toolCallId, event.toolName, event.args or {})
		tc.running = true
		tc.is_partial_result = false
		tc.is_error = false
		local details = extract_tool_details(event)
		if details then tc.details = details end
		-- Immediate render when tool starts (not throttled)
		vim.schedule(function()
			cancel_scheduled_render()
			if opts.is_open() then opts.on_render() end
		end)
	end)

	opts.client.on_event("tool_execution_update", function(event)
		if not event then return end
		state.is_streaming = true
		local tc = M.upsert_tool_call(state, event.toolCallId, event.toolName, event.args or {})
		tc.running = true
		tc.is_partial_result = true
		tc.is_error = false
		tc.result = extract_tool_result_text(event.partialResult)
		local details = extract_tool_details(event)
		if details then tc.details = details end
		vim.schedule(function()
			schedule_render(state, opts.is_open, opts.on_render)
		end)
	end)

	opts.client.on_event("tool_execution_end", function(event)
		if not event then return end
		local tc = M.upsert_tool_call(state, event.toolCallId, event.toolName, event.args or {})
		tc.running = false
		tc.is_partial_result = false
		tc.is_error = event.isError == true
		tc.result = extract_tool_result_text(event.result)
		local details = extract_tool_details(event)
		if details then tc.details = details end
		-- Immediate render when tool finishes (not throttled)
		vim.schedule(function()
			cancel_scheduled_render()
			if opts.is_open() then opts.on_render() end
		end)
	end)
end

return M

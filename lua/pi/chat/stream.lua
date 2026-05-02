local M = {}

function M.new_state()
	return {
		pre_tool_text = "",
		post_tool_text = "",
		live_thinking = "",
		thinking_blocks = {},
		thinking_seq = 0,
		saw_tool_activity = false,
		tools_by_id = {},
		tool_order = {},
		is_streaming = false,
		last_render = 0,
		handlers_registered = false,
	}
end

function M.reset(state)
	state.pre_tool_text = ""
	state.post_tool_text = ""
	state.live_thinking = ""
	state.thinking_blocks = {}
	state.thinking_seq = 0
	state.saw_tool_activity = false
	state.tools_by_id = {}
	state.tool_order = {}
	state.last_render = 0
end

local function finalize_live_thinking(state)
	local thought = state.live_thinking
	if type(thought) ~= "string" or thought == "" then return end
	state.thinking_seq = (state.thinking_seq or 0) + 1
	table.insert(state.thinking_blocks, {
		id = "thinking_stream_" .. tostring(state.thinking_seq),
		text = thought,
	})
	state.live_thinking = ""
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
	end

	if name and name ~= "" then
		tc.name = name
	end

	if type(input) == "table" then
		tc.input = input
		tc.file = input.file_path or input.path or input.file or tc.file
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

		local partial_text = ""
		if event.message.content and type(event.message.content) == "table" then
			for block_idx, block in ipairs(event.message.content) do
				if block.type == "text" and block.text then
					partial_text = partial_text .. block.text
				elseif block.type == "toolCall" then
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

		if state.saw_tool_activity then
			state.post_tool_text = partial_text
		else
			state.pre_tool_text = partial_text
		end

		local assistant_event = event.assistantMessageEvent
		if assistant_event and assistant_event.type == "toolcall_delta" then
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
			state.live_thinking = ""
		elseif assistant_event and assistant_event.type == "thinking_delta" then
			state.live_thinking = (state.live_thinking or "") .. (assistant_event.delta or "")
		elseif assistant_event and assistant_event.type == "thinking_end" then
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
		finalize_live_thinking(state)
		local tc = M.upsert_tool_call(state, event.toolCallId, event.toolName, event.args or {})
		tc.running = true
		tc.is_partial_result = false
		tc.is_error = false
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
		-- Immediate render when tool finishes (not throttled)
		vim.schedule(function()
			cancel_scheduled_render()
			if opts.is_open() then opts.on_render() end
		end)
	end)
end

return M

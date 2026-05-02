--- Pi RPC Client - communicates with pi --mode rpc via JSON lines on stdin/stdout
---
--- Spawns pi as a background process and sends/receives JSON commands.

local config = require("pi.config")
local json = require("pi.util.json")

local M = {}

local job_id = nil
local command_id = 0
local pending_commands = {}
local event_handlers = {}
local stdout_buffer = ""
local DEFAULT_RESPONSE_TIMEOUT_MS = 30000

local function safe_invoke_callback(callback, payload)
	if type(callback) ~= "function" then return end
	local ok, err = pcall(callback, payload)
	if not ok then
		vim.schedule(function()
			vim.notify("pi: callback error: " .. tostring(err), vim.log.levels.ERROR)
		end)
	end
end

local function fail_pending_command(id, err)
	local pending = pending_commands[id]
	if not pending then return end
	pending_commands[id] = nil
	safe_invoke_callback(pending.callback, {
		type = "response",
		id = id,
		command = pending.command,
		success = false,
		error = err or "request failed",
	})
end

local function fail_all_pending(err)
	local ids = {}
	for id, _ in pairs(pending_commands) do
		table.insert(ids, id)
	end
	for _, id in ipairs(ids) do
		fail_pending_command(id, err)
	end
end

--- Start the pi RPC process
--- @param opts? { cwd: string }
--- @return boolean success
function M.start(opts)
	opts = opts or {}
	if M.is_running() then
		return true
	end

	stdout_buffer = ""
	command_id = 0
	pending_commands = {}

	local pi_cmd = config.options.pi_cmd
	local cmd = { pi_cmd, "--mode", "rpc" }

	job_id = vim.fn.jobstart(cmd, {
		cwd = opts.cwd or vim.fn.getcwd(),
		on_stdout = function(_, data)
			M._on_stdout(data)
		end,
		on_stderr = function(_, data)
			M._on_stderr(data)
		end,
		on_exit = function(_, exit_code)
			M._on_exit(exit_code)
		end,
		stdout_buffered = false,
		stderr_buffered = false,
	})

	if job_id <= 0 then
		vim.notify("pi: jobstart failed (code " .. job_id .. ")", vim.log.levels.ERROR)
		job_id = nil
		return false
	end

	return true
end

--- Stop the pi RPC process
function M.stop()
	if job_id then
		vim.fn.jobstop(job_id)
		job_id = nil
	end
	fail_all_pending("pi: stopped")
	pending_commands = {}
	stdout_buffer = ""
end

--- Check if pi is running
--- @return boolean
function M.is_running()
	return job_id ~= nil and job_id > 0
end

--- Send a command to pi
--- @param cmd table The RPC command (without id)
--- @param callback? function Callback for the response
--- @return string|nil command_id
function M.send(cmd, callback)
	if not M.is_running() then
		vim.notify("pi is not running. Use :PiStart to start it.", vim.log.levels.ERROR)
		return nil
	end

	command_id = command_id + 1
	local id = tostring(command_id)
	local command = vim.tbl_extend("force", cmd, { id = id })

	if callback then
		pending_commands[id] = {
			command = cmd.type,
			callback = callback,
		}
		local timeout_ms = tonumber(config.options.rpc_timeout_ms) or DEFAULT_RESPONSE_TIMEOUT_MS
		vim.defer_fn(function()
			fail_pending_command(id, "timeout waiting for response to `" .. tostring(cmd.type) .. "`")
		end, math.max(1000, timeout_ms))
	end

	local ok, line = pcall(vim.fn.json_encode, command)
	if not ok then
		pending_commands[id] = nil
		vim.notify("pi: failed to encode command: " .. tostring(line), vim.log.levels.ERROR)
		return nil
	end

	-- Verify job is alive before sending
	local pid_ok, pid = pcall(vim.fn.jobpid, job_id)
	if not pid_ok or pid == 0 or pid == -1 then
		pending_commands[id] = nil
		vim.notify("pi: job " .. job_id .. " is not alive (pid=" .. tostring(pid) .. ")", vim.log.levels.ERROR)
		job_id = nil
		return nil
	end

	local result = vim.fn.chansend(job_id, line .. "\n")
	if result == 0 then
		pending_commands[id] = nil
		vim.notify("pi: chansend returned 0 (job " .. job_id .. " may have exited)", vim.log.levels.ERROR)
		job_id = nil
		return nil
	end

	return id
end

--- Send a prompt
--- @param message string
--- @param callback? function
function M.prompt(message, callback)
	return M.send({ type = "prompt", message = message }, callback)
end

--- Steer the current prompt
--- @param message string
function M.steer(message)
	return M.send({ type = "steer", message = message })
end

--- Abort the current operation
function M.abort()
	return M.send({ type = "abort" })
end

--- Get the current session state
--- @param callback function
function M.get_state(callback)
	return M.send({ type = "get_state" }, callback)
end

--- Get messages from the current session
--- @param callback function
function M.get_messages(callback)
	return M.send({ type = "get_messages" }, callback)
end

--- Get available models
--- @param callback function
function M.get_available_models(callback)
	return M.send({ type = "get_available_models" }, callback)
end

--- Set active model
--- @param provider string
--- @param model_id string
--- @param callback? function
function M.set_model(provider, model_id, callback)
	return M.send({ type = "set_model", provider = provider, modelId = model_id }, callback)
end

--- Compact current session context
--- @param custom_instructions? string
--- @param callback? function
function M.compact(custom_instructions, callback)
	local payload = { type = "compact" }
	if custom_instructions and custom_instructions ~= "" then
		payload.customInstructions = custom_instructions
	end
	return M.send(payload, callback)
end

--- Get detailed session stats
--- @param callback function
function M.get_session_stats(callback)
	return M.send({ type = "get_session_stats" }, callback)
end

--- Export current session to HTML
--- @param output_path? string
--- @param callback? function
function M.export_html(output_path, callback)
	local payload = { type = "export_html" }
	if output_path and output_path ~= "" then
		payload.outputPath = output_path
	end
	return M.send(payload, callback)
end

--- Get user messages that can be used as fork points
--- @param callback function
function M.get_fork_messages(callback)
	return M.send({ type = "get_fork_messages" }, callback)
end

--- Fork session at an entry
--- @param entry_id string
--- @param callback? function
function M.fork(entry_id, callback)
	return M.send({ type = "fork", entryId = entry_id }, callback)
end

--- Get last assistant text
--- @param callback function
function M.get_last_assistant_text(callback)
	return M.send({ type = "get_last_assistant_text" }, callback)
end

--- Get invokable extension/prompt/skill slash commands
--- @param callback function
function M.get_commands(callback)
	return M.send({ type = "get_commands" }, callback)
end

--- Switch to a different session
--- @param session_path string
--- @param callback? function
function M.switch_session(session_path, callback)
	return M.send({ type = "switch_session", sessionPath = session_path }, callback)
end

--- Create a new session
--- @param callback? function
function M.new_session(callback)
	return M.send({ type = "new_session" }, callback)
end

--- Set session name
--- @param name string
function M.set_session_name(name)
	return M.send({ type = "set_session_name", name = name })
end

--- Register a handler for agent events (text, tool_call, stop, etc.)
--- @param event_type string
--- @param handler function
function M.on_event(event_type, handler)
	if not event_handlers[event_type] then
		event_handlers[event_type] = {}
	end
	table.insert(event_handlers[event_type], handler)
end

--- Remove all event handlers for a type
--- @param event_type string
function M.off_event(event_type)
	event_handlers[event_type] = nil
end

--- Internal: handle stdout data from pi process.
--- Stream handlers may receive partial lines. Reassemble by newline boundaries.
--- @param data string[]
function M._on_stdout(data)
	if type(data) ~= "table" or #data == 0 then return end

	-- `data` is split by newlines; first/last can be partial.
	stdout_buffer = stdout_buffer .. (data[1] or "")
	for i = 2, #data do
		local line = stdout_buffer
		stdout_buffer = data[i] or ""
		if line ~= "" then
			M._process_line(line)
		end
	end
end

--- Process a single JSON line from stdout
--- @param line string
function M._process_line(line)
	local parsed = json.decode(line)
	if type(parsed) ~= "table" then
		local preview = line
		if #preview > 180 then preview = preview:sub(1, 180) .. "…" end
		vim.notify("pi: failed to parse response: " .. preview, vim.log.levels.WARN)
		return
	end

	if parsed.type == "response" then
		-- Command response
		local id = parsed.id
		if id and pending_commands[id] then
			local pending = pending_commands[id]
			pending_commands[id] = nil
			safe_invoke_callback(pending.callback, parsed)
		end
	elseif parsed.type == "extension_ui_request" then
		-- Handle extension UI request
		M._handle_ui_request(parsed)
	else
		-- Route all other events (message_update, agent_end, tool_execution_start, etc.)
		-- to registered event handlers by their type
		local handlers = event_handlers[parsed.type]
		if handlers then
			for _, handler in ipairs(handlers) do
				local ok, err = pcall(handler, parsed)
				if not ok then
					vim.schedule(function()
						vim.notify(
							"pi: event handler error (" .. tostring(parsed.type) .. "): " .. tostring(err),
							vim.log.levels.ERROR
						)
					end)
				end
			end
		end
	end
end

--- Handle extension UI requests
--- @param request table
function M._handle_ui_request(request)
	if request.method == "confirm" then
		local ok = vim.fn.confirm(request.message .. "\n\n" .. (request.title or ""), "&Yes\n&No") == 1
		M.send({ type = "extension_ui_response", id = request.id, confirmed = ok })
	elseif request.method == "input" then
		local result = vim.fn.input(request.title .. ": ")
		M.send({ type = "extension_ui_response", id = request.id, value = result })
	elseif request.method == "notify" then
		local level = request.notifyType == "error" and vim.log.levels.ERROR
			or request.notifyType == "warning" and vim.log.levels.WARN
			or vim.log.levels.INFO
		vim.notify(request.message, level)
	elseif request.method == "select" then
		local ok, idx = pcall(vim.fn.inputlist, vim.tbl_map(function(opt)
			return opt
		end, request.options))
		if ok and idx and idx > 0 then
			M.send({ type = "extension_ui_response", id = request.id, value = request.options[idx] })
		else
			M.send({ type = "extension_ui_response", id = request.id, cancelled = true })
		end
	else
		-- Send a cancelled response for unhandled methods
		M.send({ type = "extension_ui_response", id = request.id, cancelled = true })
	end
end

--- Internal: handle stderr data
--- @param data string[]
function M._on_stderr(data)
	for _, chunk in ipairs(data) do
		if chunk and chunk ~= "" then
			vim.notify("pi: " .. chunk, vim.log.levels.WARN)
		end
	end
end

--- Internal: handle process exit
--- @param exit_code number
function M._on_exit(exit_code)
	if stdout_buffer and stdout_buffer ~= "" then
		M._process_line(stdout_buffer)
		stdout_buffer = ""
	end
	job_id = nil
	fail_all_pending("pi exited with code " .. tostring(exit_code))
	if exit_code ~= 0 and exit_code ~= 143 then -- 143 = SIGTERM
		vim.notify("pi exited with code " .. exit_code, vim.log.levels.ERROR)
	end
end

return M

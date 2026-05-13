--- Reusable Pi RPC client instance.
---
--- Each instance owns one `pi --mode rpc` job. The higher-level client module
--- can keep multiple instances alive so background sessions continue running
--- after the UI switches away.

local config = require("pi.config")
local json = require("pi.util.json")

local DEFAULT_RESPONSE_TIMEOUT_MS = 30000

local Client = {}
Client.__index = Client

local function safe_invoke_callback(callback, payload)
	if type(callback) ~= "function" then return end
	local ok, err = pcall(callback, payload)
	if not ok then
		vim.schedule(function()
			vim.notify("pi: callback error: " .. tostring(err), vim.log.levels.ERROR)
		end)
	end
end

function Client.new(opts)
	opts = opts or {}
	return setmetatable({
		job_id = nil,
		command_id = 0,
		pending_commands = {},
		event_handlers = {},
		stdout_buffer = "",
		cwd = opts.cwd,
		session_path = opts.session_path,
		label = opts.label,
		is_streaming = false,
		last_activity = vim.loop.now(),
	}, Client)
end

function Client:_fail_pending_command(id, err)
	local pending = self.pending_commands[id]
	if not pending then return end
	self.pending_commands[id] = nil
	safe_invoke_callback(pending.callback, {
		type = "response",
		id = id,
		command = pending.command,
		success = false,
		error = err or "request failed",
	})
end

function Client:_fail_all_pending(err)
	local ids = {}
	for id, _ in pairs(self.pending_commands) do
		table.insert(ids, id)
	end
	for _, id in ipairs(ids) do
		self:_fail_pending_command(id, err)
	end
end

function Client:is_running()
	return self.job_id ~= nil and self.job_id > 0
end

function Client:is_idle()
	return self:is_running() and not self.is_streaming
end

function Client:touch()
	self.last_activity = vim.loop.now()
end

function Client:start(opts)
	opts = opts or {}
	if self:is_running() then return true end

	self.stdout_buffer = ""
	self.command_id = 0
	self.pending_commands = {}
	self.is_streaming = false
	self:touch()
	self.cwd = opts.cwd or self.cwd or vim.fn.getcwd()
	self.session_path = opts.session_path or self.session_path

	local cmd = { config.options.pi_cmd, "--mode", "rpc" }
	if self.session_path and self.session_path ~= "" then
		table.insert(cmd, "--session")
		table.insert(cmd, self.session_path)
	end

	self.job_id = vim.fn.jobstart(cmd, {
		cwd = self.cwd,
		on_stdout = function(_, data)
			self:_on_stdout(data)
		end,
		on_stderr = function(_, data)
			self:_on_stderr(data)
		end,
		on_exit = function(_, exit_code)
			self:_on_exit(exit_code)
		end,
		stdout_buffered = false,
		stderr_buffered = false,
	})

	if self.job_id <= 0 then
		vim.notify("pi: jobstart failed (code " .. self.job_id .. ")", vim.log.levels.ERROR)
		self.job_id = nil
		return false
	end

	return true
end

function Client:stop()
	if self.job_id then
		vim.fn.jobstop(self.job_id)
		self.job_id = nil
	end
	self:_fail_all_pending("pi: stopped")
	self.pending_commands = {}
	self.stdout_buffer = ""
	self.is_streaming = false
	self:touch()
end

function Client:send(cmd, callback)
	if not self:is_running() then
		vim.notify(
			"pi debug: send to stopped client cmd=" .. tostring(cmd and cmd.type)
				.. " session=" .. tostring(self.session_path)
				.. " label=" .. tostring(self.label),
			vim.log.levels.ERROR
		)
		return nil
	end

	self.command_id = self.command_id + 1
	self:touch()
	local id = tostring(self.command_id)
	local command = vim.tbl_extend("force", cmd, { id = id })

	if callback then
		self.pending_commands[id] = { command = cmd.type, callback = callback }
		local timeout_ms = tonumber(config.options.rpc_timeout_ms) or DEFAULT_RESPONSE_TIMEOUT_MS
		vim.defer_fn(function()
			self:_fail_pending_command(id, "timeout waiting for response to `" .. tostring(cmd.type) .. "`")
		end, math.max(1000, timeout_ms))
	end

	local ok, line = pcall(vim.fn.json_encode, command)
	if not ok then
		self.pending_commands[id] = nil
		vim.notify("pi: failed to encode command: " .. tostring(line), vim.log.levels.ERROR)
		return nil
	end

	local pid_ok, pid = pcall(vim.fn.jobpid, self.job_id)
	if not pid_ok or pid == 0 or pid == -1 then
		self.pending_commands[id] = nil
		vim.notify("pi: job " .. self.job_id .. " is not alive (pid=" .. tostring(pid) .. ")", vim.log.levels.ERROR)
		self.job_id = nil
		return nil
	end

	local result = vim.fn.chansend(self.job_id, line .. "\n")
	if result == 0 then
		self.pending_commands[id] = nil
		vim.notify("pi: chansend returned 0 (job " .. self.job_id .. " may have exited)", vim.log.levels.ERROR)
		self.job_id = nil
		return nil
	end

	return id
end

function Client:on_event(event_type, handler)
	if not self.event_handlers[event_type] then
		self.event_handlers[event_type] = {}
	end
	table.insert(self.event_handlers[event_type], handler)
end

function Client:off_event(event_type)
	self.event_handlers[event_type] = nil
end

function Client:_on_stdout(data)
	if type(data) ~= "table" or #data == 0 then return end
	self.stdout_buffer = self.stdout_buffer .. (data[1] or "")
	for i = 2, #data do
		local line = self.stdout_buffer
		self.stdout_buffer = data[i] or ""
		if line ~= "" then
			self:_process_line(line)
		end
	end
end

function Client:_process_line(line)
	local parsed = json.decode(line)
	if type(parsed) ~= "table" then
		local preview = line
		if #preview > 180 then preview = preview:sub(1, 180) .. "..." end
		vim.notify("pi: failed to parse response: " .. preview, vim.log.levels.WARN)
		return
	end

	if parsed.type == "response" then
		self:touch()
		local id = parsed.id
		if parsed.command == "get_state" and parsed.success and type(parsed.data) == "table" then
			self.session_path = parsed.data.sessionFile or self.session_path
			self.is_streaming = parsed.data.isStreaming == true
		end
		if id and self.pending_commands[id] then
			local pending = self.pending_commands[id]
			self.pending_commands[id] = nil
			safe_invoke_callback(pending.callback, parsed)
		elseif not parsed.success and parsed.error then
			-- Orphan error response (no pending callback to receive it).
			-- This happens when a command timed out but the real response arrives
			-- later. The callback already received a timeout error, so silently
			-- drop the late response to avoid spurious notifications.
		end
	elseif parsed.type == "extension_ui_request" then
		self:touch()
		self:_handle_ui_request(parsed)
	else
		self:touch()
		if parsed.type == "agent_start" or parsed.type == "message_update" or parsed.type == "tool_execution_start" then
			self.is_streaming = true
		elseif parsed.type == "agent_end" then
			self.is_streaming = false
		end
		local handlers = self.event_handlers[parsed.type]
		if handlers then
			for _, handler in ipairs(handlers) do
				local ok, err = pcall(handler, parsed, self)
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

function Client:_handle_ui_request(request)
	if request.method == "confirm" then
		local ok = vim.fn.confirm(request.message .. "\n\n" .. (request.title or ""), "&Yes\n&No") == 1
		if self:is_running() then
			self:send({ type = "extension_ui_response", id = request.id, confirmed = ok })
		end
	elseif request.method == "input" then
		local result = vim.fn.input(request.title .. ": ")
		if self:is_running() then
			self:send({ type = "extension_ui_response", id = request.id, value = result })
		end
	elseif request.method == "notify" then
		local level = request.notifyType == "error" and vim.log.levels.ERROR
			or request.notifyType == "warning" and vim.log.levels.WARN
			or vim.log.levels.INFO
		vim.notify(request.message, level)
	elseif request.method == "setStatus"
		or request.method == "setWidget"
		or request.method == "setTitle"
		or request.method == "set_editor_text" then
		-- Fire-and-forget RPC UI events. The agent does not expect a response.
	elseif request.method == "select" then
		local ok, idx = pcall(vim.fn.inputlist, vim.tbl_map(function(opt)
			return opt
		end, request.options))
		if ok and idx and idx > 0 then
			if self:is_running() then
				self:send({ type = "extension_ui_response", id = request.id, value = request.options[idx] })
			end
		else
			if self:is_running() then
				self:send({ type = "extension_ui_response", id = request.id, cancelled = true })
			end
		end
	else
		-- Unknown UI request. Only dialog-style requests need responses; avoid
		-- writing to a process that may have already exited during startup/switch.
		if self:is_running() then
			self:send({ type = "extension_ui_response", id = request.id, cancelled = true })
		end
	end
end

function Client:_on_stderr(data)
	for _, chunk in ipairs(data) do
		if chunk and chunk ~= "" then
			-- Only surface stderr that looks like a genuine error. The pi CLI
			-- logs routine info and warnings to stderr; suppressing noise avoids
			-- spurious notifications during normal tool execution.
			local lower = chunk:lower()
			if lower:find("error") or lower:find("fatal") or lower:find("uncaught") or lower:find("exception") then
				vim.notify("pi: " .. chunk, vim.log.levels.WARN)
			end
		end
	end
end

function Client:_on_exit(exit_code)
	if self.stdout_buffer and self.stdout_buffer ~= "" then
		self:_process_line(self.stdout_buffer)
		self.stdout_buffer = ""
	end
	self.job_id = nil
	self:_fail_all_pending("pi exited with code " .. tostring(exit_code))
	if exit_code ~= 0 and exit_code ~= 143 then
		vim.notify("pi exited with code " .. exit_code, vim.log.levels.ERROR)
	end
end

return Client

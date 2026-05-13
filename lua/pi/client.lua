--- Pi RPC Client facade.
---
--- Public API stays singleton-shaped for the UI, but internally this can keep
--- multiple RPC jobs alive. Each session that is opened while another one is
--- running gets its own `pi --mode rpc --session <file>` process.

local Client = require("pi.client_instance")

local M = {}

local active_client = nil
local clients_by_key = {}
local event_handlers = {}
local schedule_idle_cleanup
local status_update_timer = nil

local function idle_timeout_ms()
	local raw = tonumber(require("pi.config").options.background_idle_timeout_ms)
	if raw == nil then return 300000 end
	return math.max(0, math.floor(raw))
end

local function max_idle_clients()
	local raw = tonumber(require("pi.config").options.background_max_idle_clients)
	if raw == nil then return 1 end
	return math.max(0, math.floor(raw))
end

local function status_update_interval_ms()
	local raw = tonumber(require("pi.config").options.client_status_update_interval_ms)
	if raw == nil then return 500 end
	return math.max(50, math.floor(raw))
end

local function emit_status_changed()
	vim.schedule(function()
		vim.api.nvim_exec_autocmds("User", { pattern = "PiClientStatusChanged" })
	end)
end

local function emit_session_changed()
	vim.schedule(function()
		vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
	end)
end

local function emit_status_changed_throttled()
	if status_update_timer then return end
	status_update_timer = vim.defer_fn(function()
		status_update_timer = nil
		emit_status_changed()
	end, status_update_interval_ms())
end

local function client_key(opts)
	opts = opts or {}
	if opts.session_path and opts.session_path ~= "" then
		return "session:" .. opts.session_path
	end
	return "default"
end

local function bridge_events(client)
	if client._pi_facade_bridged then return end
	client._pi_facade_bridged = true
	local event_types = {
		"agent_start",
		"agent_end",
		"turn_start",
		"turn_end",
		"message_start",
		"message_update",
		"message_end",
		"tool_execution_start",
		"tool_execution_update",
		"tool_execution_end",
		"queue_update",
		"compaction_start",
		"compaction_end",
		"auto_retry_start",
		"auto_retry_end",
		"extension_error",
	}
	for _, event_type in ipairs(event_types) do
		client:on_event(event_type, function(event, source_client)
			local event_client = source_client or client
			if event_type == "agent_end" then
				schedule_idle_cleanup(event_client)
				emit_status_changed()
				emit_session_changed()
			elseif event_type == "agent_start" then
				emit_status_changed_throttled()
				emit_session_changed()
			elseif event_type == "agent_start" or event_type == "message_update" or event_type == "tool_execution_start" then
				emit_status_changed_throttled()
			elseif event_type == "extension_error" then
				local msg = (event and event.message) or "extension error"
				vim.schedule(function()
					vim.notify("pi extension: " .. tostring(msg), vim.log.levels.WARN)
				end)
			end
			local handlers = event_handlers[event_type]
			if not handlers then return end
			for _, handler in ipairs(handlers) do
				local ok, err = pcall(handler, event, event_client)
				if not ok then
					vim.schedule(function()
						vim.notify(
							"pi: event handler error (" .. tostring(event_type) .. "): " .. tostring(err),
							vim.log.levels.ERROR
						)
					end)
				end
			end
		end)
	end
end

local function get_or_create_client(opts)
	opts = opts or {}
	local key = client_key(opts)
	local client = clients_by_key[key]
	if not client then
		client = Client.new({
			cwd = opts.cwd,
			session_path = opts.session_path,
			label = key,
		})
		clients_by_key[key] = client
		bridge_events(client)
	end
	return client, key
end

local function remove_client(target)
	for key, client in pairs(clients_by_key) do
		if client == target then
			clients_by_key[key] = nil
		end
	end
	if active_client == target then
		active_client = nil
	end
end

local function rekey_client(client)
	if not client then return end
	local new_key = client_key({ session_path = client.session_path })
	for key, existing in pairs(clients_by_key) do
		if existing == client and key ~= new_key then
			clients_by_key[key] = nil
		end
	end
	local existing = clients_by_key[new_key]
	if existing and existing ~= client and existing:is_idle() then
		existing:stop()
	end
	clients_by_key[new_key] = client
	client.label = new_key
end

schedule_idle_cleanup = function(target)
	if not target then return end
	local timeout = idle_timeout_ms()
	if timeout < 0 then return end
	local token = (target._pi_cleanup_token or 0) + 1
	target._pi_cleanup_token = token
	vim.defer_fn(function()
		if target._pi_cleanup_token ~= token then return end
		if target == active_client then return end
		if target:is_idle() then
			target:stop()
			remove_client(target)
			emit_status_changed()
		end
	end, timeout)
end

local function cleanup_idle_clients(force)
	local now = vim.loop.now()
	local timeout = idle_timeout_ms()
	local clients = {}
	local idle_clients = {}
	for _, client in pairs(clients_by_key) do
		table.insert(clients, client)
	end
	for _, client in ipairs(clients) do
		if client ~= active_client and client:is_idle() then
			local idle_for = now - (client.last_activity or now)
			if force or timeout == 0 or idle_for >= timeout then
				client:stop()
				remove_client(client)
			else
				table.insert(idle_clients, client)
			end
		end
	end
	table.sort(idle_clients, function(a, b)
		return (a.last_activity or 0) < (b.last_activity or 0)
	end)
	local keep = max_idle_clients()
	while #idle_clients > keep do
		local client = table.remove(idle_clients, 1)
		client:stop()
		remove_client(client)
	end
end

local function get_active()
	if not active_client then
		active_client = get_or_create_client({})
	end
	return active_client
end

local function send(cmd, callback)
	return get_active():send(cmd, callback)
end

--- Start the active pi RPC process.
--- @param opts? { cwd: string, session_path: string }
--- @return boolean success
function M.start(opts)
	opts = opts or {}
	local client = get_or_create_client(opts)
	if active_client and active_client ~= client and active_client:is_idle() then
		schedule_idle_cleanup(active_client)
	end
	active_client = client
	client._pi_cleanup_token = (client._pi_cleanup_token or 0) + 1
	cleanup_idle_clients(false)
	return client:start(opts)
end

--- Attach the facade to a session-specific RPC process.
--- @param session_path string
--- @param opts? { cwd: string }
--- @param callback? function
function M.attach_session(session_path, opts, callback)
	opts = opts or {}
	if type(opts) == "function" then
		callback = opts
		opts = {}
	end
	local client = get_or_create_client({ cwd = opts.cwd, session_path = session_path })
	local previous_client = active_client
	active_client = client
	client._pi_cleanup_token = (client._pi_cleanup_token or 0) + 1
	local ok = client:start({ cwd = opts.cwd, session_path = session_path })
	if not ok then
		remove_client(client)
		active_client = previous_client
		if callback then callback({ success = false, error = "failed to start session client" }) end
		return nil
	end
	if callback then
		return client:send({ type = "get_state" }, function(response)
			if response and response.success then
				rekey_client(client)
				if previous_client and previous_client ~= client and previous_client:is_idle() then
					schedule_idle_cleanup(previous_client)
				end
				cleanup_idle_clients(false)
			else
				if client:is_running() then client:stop() end
				remove_client(client)
				if active_client == nil then active_client = previous_client end
			end
			callback(response)
		end)
	end
	return true
end

--- Stop all pi RPC processes.
function M.stop()
	for _, client in pairs(clients_by_key) do
		client:stop()
	end
	active_client = nil
end

function M.cleanup_idle(force)
	cleanup_idle_clients(force == true)
	emit_status_changed()
end

--- Stop only the active RPC process.
function M.stop_active()
	if active_client then active_client:stop() end
end

function M.is_running()
	return active_client ~= nil and active_client:is_running()
end

function M.has_running_clients()
	for _, client in pairs(clients_by_key) do
		if client:is_running() then return true end
	end
	return false
end

function M.active_client()
	return get_active()
end

function M.get_session_status(session_path)
	if type(session_path) ~= "string" or session_path == "" then return nil end
	if active_client and active_client.session_path == session_path and active_client:is_running() then
		return active_client.is_streaming and "active_running" or "active_idle"
	end
	for _, client in pairs(clients_by_key) do
		if client.session_path == session_path and client:is_running() then
			return client.is_streaming and "running" or "idle"
		end
	end
	return nil
end

function M.send(cmd, callback)
	return send(cmd, callback)
end

function M.prompt(message, images, callback)
	if type(images) == "function" then
		callback = images
		images = nil
	end
	return send({ type = "prompt", message = message, images = images }, function(response)
		if response and response.success then
			emit_status_changed()
			vim.schedule(function()
				vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
			end)
		end
		if callback then callback(response) end
	end)
end

function M.steer(message)
	return send({ type = "steer", message = message })
end

function M.abort()
	return send({ type = "abort" })
end

function M.get_state(callback)
	return send({ type = "get_state" }, callback)
end

function M.get_messages(callback)
	return send({ type = "get_messages" }, callback)
end

function M.get_available_models(callback)
	return send({ type = "get_available_models" }, callback)
end

function M.set_model(provider, model_id, callback)
	return send({ type = "set_model", provider = provider, modelId = model_id }, callback)
end

function M.set_thinking_level(level, callback)
	return send({ type = "set_thinking_level", level = level }, callback)
end

function M.cycle_thinking_level(callback)
	return send({ type = "cycle_thinking_level" }, callback)
end

function M.compact(custom_instructions, callback)
	local payload = { type = "compact" }
	if custom_instructions and custom_instructions ~= "" then
		payload.customInstructions = custom_instructions
	end
	return send(payload, callback)
end

function M.get_session_stats(callback)
	return send({ type = "get_session_stats" }, callback)
end

function M.export_html(output_path, callback)
	local payload = { type = "export_html" }
	if output_path and output_path ~= "" then
		payload.outputPath = output_path
	end
	return send(payload, callback)
end

function M.get_fork_messages(callback)
	return send({ type = "get_fork_messages" }, callback)
end

function M.fork(entry_id, callback)
	return send({ type = "fork", entryId = entry_id }, callback)
end

function M.get_last_assistant_text(callback)
	return send({ type = "get_last_assistant_text" }, callback)
end

function M.get_commands(callback)
	return send({ type = "get_commands" }, callback)
end

function M.switch_session(session_path, callback)
	-- Prefer a session-specific process over replacing the active runtime in an
	-- existing process. This lets other running sessions continue in background.
	return M.attach_session(session_path, {}, callback)
end

function M.new_session(callback)
	local client = get_active()
	return client:send({ type = "new_session" }, function(response)
		if not response or not response.success then
			if callback then callback(response) end
			return
		end
		client:send({ type = "get_state" }, function(state_response)
			if state_response and state_response.success then
				rekey_client(client)
				emit_status_changed()
				vim.schedule(function()
					vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
				end)
			end
			if callback then callback(response) end
		end)
	end)
end

function M.set_session_name(name)
	return send({ type = "set_session_name", name = name })
end

function M.on_event(event_type, handler)
	if not event_handlers[event_type] then
		event_handlers[event_type] = {}
	end
	table.insert(event_handlers[event_type], handler)
end

function M.off_event(event_type)
	event_handlers[event_type] = nil
end

return M

local M = {}

--- Execute local slash command in pi-nvim chat UI.
--- Returns true when command is consumed (including unsupported built-ins).
--- @param message string
--- @param ctx table
--- @return boolean
function M.execute_local(message, ctx)
	if type(message) ~= "string" or message:sub(1, 1) ~= "/" then
		return false
	end
	local cmd, args = message:match("^/(%S+)%s*(.*)$")
	if not cmd then return false end
	cmd = cmd:lower()
	args = args or ""

	local client = ctx.client

	if cmd == "new" then
		if not client.is_running() then
			vim.notify("pi: not running. Use :PiStart first", vim.log.levels.ERROR)
			return true
		end
		client.new_session(function(response)
			vim.schedule(function()
				if response and response.success then
					vim.notify("pi: new session created", vim.log.levels.INFO)
					vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
				else
					local err = response and response.error or "unknown error"
					vim.notify("pi: failed to create session: " .. err, vim.log.levels.ERROR)
				end
			end)
		end)
		return true
	end

	if cmd == "model" then
		ctx.open_model_selector()
		return true
	end

	if cmd == "thinking" then
		ctx.open_thinking_level_selector()
		return true
	end

	if cmd == "compact" then
		client.compact(args ~= "" and args or nil, function(response)
			vim.schedule(function()
				if response and response.success then
					vim.notify("pi: compaction complete", vim.log.levels.INFO)
					ctx.refresh()
				else
					local err = response and response.error or "compaction failed"
					vim.notify("pi: " .. err, vim.log.levels.ERROR)
				end
			end)
		end)
		return true
	end

	if cmd == "copy" then
		ctx.copy_last_assistant_to_clipboard()
		return true
	end

	if cmd == "export" then
		client.export_html(args ~= "" and args or nil, function(response)
			vim.schedule(function()
				if response and response.success and response.data and response.data.path then
					vim.notify("pi: exported to " .. response.data.path, vim.log.levels.INFO)
				else
					local err = response and response.error or "export failed"
					vim.notify("pi: " .. err, vim.log.levels.ERROR)
				end
			end)
		end)
		return true
	end

	if cmd == "fork" then
		ctx.open_fork_selector()
		return true
	end

	if cmd == "resume" then
		local sidebar = require("pi.sidebar")
		if sidebar.is_open and not sidebar.is_open() then
			sidebar.open(vim.fn.getcwd())
		end
		sidebar.focus()
		return true
	end

	if cmd == "session" then
		if not client.is_running() then
			vim.notify("pi: not running", vim.log.levels.WARN)
			return true
		end
		client.get_session_stats(function(stats_response)
			vim.schedule(function()
				client.get_state(function(response)
					vim.schedule(function()
						if response and response.success and response.data then
							local st = response.data
							local model = st.model and (st.model.provider .. "/" .. st.model.id) or "?"
							local session_name = st.sessionName or st.sessionId or "?"
							local tokens = "?"
							if stats_response and stats_response.success and stats_response.data then
								local t = stats_response.data.totalTokens
								if t then tokens = tostring(t) end
							end
							local msg = string.format(
								"pi: session=%s | model=%s | messages=%s | tokens=%s",
								session_name,
								model,
								tostring(st.messageCount or "?"),
								tokens
							)
							vim.notify(msg, vim.log.levels.INFO)
						else
							vim.notify("pi: failed to read session state", vim.log.levels.WARN)
						end
					end)
				end)
			end)
		end)
		return true
	end

	if cmd == "name" then
		if args == "" then
			vim.notify("pi: usage /name <session name>", vim.log.levels.WARN)
			return true
		end
		client.set_session_name(args)
		vim.notify("pi: session renamed", vim.log.levels.INFO)
		vim.api.nvim_exec_autocmds("User", { pattern = "PiSessionChanged" })
		return true
	end

	if cmd == "hotkeys" then
		vim.notify("pi: local commands: /model /thinking /new /resume /name /session /compact /copy /export /fork /quit", vim.log.levels.INFO)
		return true
	end

	if cmd == "quit" then
		ctx.close_pi_ui()
		client.stop()
		vim.notify("pi: stopped", vim.log.levels.INFO)
		return true
	end

	if cmd == "settings" or cmd == "scoped-models" or cmd == "import" or cmd == "share"
		or cmd == "tree" or cmd == "login" or cmd == "logout"
		or cmd == "reload" or cmd == "changelog"
	then
		vim.notify("pi: /" .. cmd .. " UI is not implemented in pi-nvim yet", vim.log.levels.INFO)
		return true
	end

	vim.notify("pi: unknown or unsupported slash command: /" .. cmd, vim.log.levels.WARN)
	return true
end

return M

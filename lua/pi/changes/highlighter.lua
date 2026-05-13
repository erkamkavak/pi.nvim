--- Diff highlighter – manages a persistent Node.js server process that
--- uses @pierre/diffs for structured diff parsing and syntax highlighting.
---
--- Usage:
---   local hl = require("pi.changes.highlighter")
---   hl.setup()  -- auto-called on first use
---   hl.highlight(patch, path, function(result) ... end)

local M = {}
local config = require("pi.config")

-- Resolve this module's directory at load time (debug.getinfo at the
-- top level of a required file returns the file path, not the caller).
local module_source = debug.getinfo(1, "S").source
local module_dir = nil
if module_source and module_source:sub(1, 1) == "@" then
  module_dir = vim.fn.fnamemodify(module_source:sub(2), ":p:h")
end

local server_job = nil
local server_dir = nil
local request_id = 0
local pending = {}
local ready = false
local ready_callbacks = {}
local setup_done = false
local server_mtime = nil
local stdout_pending = ""
local stopping = false
local install_prompted = false
local missing_deps_notified = false

local function options()
  local opts = config.options.diff_highlight or {}
  return {
    enabled = opts.enabled ~= false,
    install = opts.install or "never",
  }
end

local function can_run(executable)
  return vim.fn.executable(executable) == 1
end

--- Find the server.mjs path relative to this plugin's install location.
local function find_server_dir()
  if server_dir then return server_dir end
  -- Try relative to this file's location (captured at load time)
  if module_dir then
    local dir = module_dir .. "/highlight"
    if vim.fn.isdirectory(dir) == 1 then
      server_dir = dir
      return dir
    end
  end
  -- Fallback: search common plugin paths
  local search_paths = {
    vim.fn.stdpath("config") .. "/lua/pi/changes/highlight",
    vim.fn.stdpath("data") .. "/site/lua/pi/changes/highlight",
  }
  for _, p in ipairs(search_paths) do
    if vim.fn.isdirectory(p) == 1 then
      server_dir = p
      return p
    end
  end
  return nil
end

local function dependencies_ready(dir)
  local node_modules = dir .. "/node_modules"
  if vim.fn.isdirectory(node_modules) == 1 then
    local pkg = node_modules .. "/@pierre/diffs"
    if vim.fn.isdirectory(pkg) == 1 then
      return true
    end
  end
  return false
end

local function install_dependencies(dir)
  if not can_run("npm") then
    vim.notify("pi: npm not found; diff syntax highlighting disabled", vim.log.levels.WARN)
    return false
  end

  vim.notify("pi: installing diff highlighter dependencies...", vim.log.levels.INFO)
  local lockfile = dir .. "/package-lock.json"
  local cmd
  if vim.fn.filereadable(lockfile) == 1 then
    cmd = { "npm", "ci", "--prefix", dir, "--no-audit", "--no-fund" }
  else
    cmd = { "npm", "install", "--prefix", dir, "--no-audit", "--no-fund" }
  end
  local result = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  if not ok then
    vim.notify("pi: failed to install diff highlighter: " .. result, vim.log.levels.ERROR)
    return false
  end
  vim.notify("pi: diff highlighter dependencies installed", vim.log.levels.INFO)
  return true
end

local function ensure_dependencies(dir, callback)
  if dependencies_ready(dir) then
    callback(true)
    return
  end

  local opts = options()
  if opts.install == "auto" then
    callback(install_dependencies(dir))
    return
  end

  if opts.install == "prompt" and not install_prompted then
    install_prompted = true
    vim.schedule(function()
      vim.ui.select({ "Install", "Skip" }, {
        prompt = "Set up enhanced diff highlighting for pi.nvim?",
      }, function(choice)
        callback(choice == "Install" and install_dependencies(dir) or false)
      end)
    end)
    return
  end

  if not missing_deps_notified then
    missing_deps_notified = true
    vim.notify(
      "pi: enhanced diff highlighting is disabled until diff_highlight.install is set to 'prompt' or 'auto'",
      vim.log.levels.INFO
    )
  end
  callback(false)
end

local function handle_response_line(line)
  if line == "" then return end
  local ok, decoded = pcall(vim.fn.json_decode, line)
  if not ok or type(decoded) ~= "table" then return end
  local id = decoded.id
  if id and pending[id] then
    local cb = pending[id]
    pending[id] = nil
    cb(decoded)
  end
end

--- Handle incoming JSONL data from stdout. Neovim may deliver either raw pipe
--- chunks or readfile-style line fragments, so support both shapes.
local function on_stdout(_, data)
  if not data then return end
  for idx, chunk in ipairs(data) do
    if chunk then
      stdout_pending = stdout_pending .. chunk
      local is_last = idx == #data
      if chunk:find("\n", 1, true) then
        while true do
          local newline = stdout_pending:find("\n", 1, true)
          if not newline then break end
          local line = stdout_pending:sub(1, newline - 1):gsub("\r$", "")
          stdout_pending = stdout_pending:sub(newline + 1)
          handle_response_line(line)
        end
      elseif not is_last or chunk == "" then
        handle_response_line(stdout_pending:gsub("\r$", ""))
        stdout_pending = ""
      end
    end
  end

  if stdout_pending ~= "" then
    local ok, decoded = pcall(vim.fn.json_decode, stdout_pending)
    if ok and type(decoded) == "table" and decoded.id then
      stdout_pending = ""
      handle_response_line(vim.fn.json_encode(decoded))
    end
  end
end

--- Callback when server writes to stderr.
local function on_stderr(_, data)
  if not data then return end
  for _, line in ipairs(data) do
    if line and line ~= "" then
      if line:find("diff%-server: ready") then
        ready = true
        -- Flush pending ready callbacks
        local cbs = ready_callbacks
        ready_callbacks = {}
        for _, cb in ipairs(cbs) do
          vim.schedule(function() cb(true) end)
        end
      end
    end
  end
end

--- Called when the server process exits.
local function on_exit(_, exit_code)
  server_job = nil
  ready = false
  local was_stopping = stopping
  stopping = false
  local cbs = ready_callbacks
  ready_callbacks = {}
  for _, cb in ipairs(cbs) do
    vim.schedule(function() cb(false) end)
  end
  local requests = pending
  pending = {}
  for _, cb in pairs(requests) do
    vim.schedule(function() cb({ success = false, error = "diff highlighter exited" }) end)
  end
  if exit_code ~= 0 and not was_stopping then
    vim.notify("pi: diff highlighter exited with code " .. exit_code, vim.log.levels.WARN)
  end
end

--- Start the server process.
--- @param callback function|nil called when server is ready
function M.start(callback)
  if not options().enabled then
    if callback then callback(false) end
    return
  end

  local dir = find_server_dir()
  if not dir or vim.fn.isdirectory(dir) ~= 1 then
    vim.notify("pi: diff highlighter directory not found", vim.log.levels.ERROR)
    if callback then callback(false) end
    return
  end

  if not can_run("node") then
    vim.notify("pi: node not found; diff syntax highlighting disabled", vim.log.levels.WARN)
    if callback then callback(false) end
    return
  end

  local server_path = dir .. "/server.mjs"
  if vim.fn.filereadable(server_path) ~= 1 then
    vim.notify("pi: diff highlighter server.mjs not found", vim.log.levels.ERROR)
    if callback then callback(false) end
    return
  end

  local function start_job()
    local current_mtime = tonumber(vim.fn.getftime(server_path)) or nil
    -- Auto-restart when the server file changes (useful in local dev sessions).
    if server_job and vim.fn.jobwait({ server_job }, 0)[1] == -1 and server_mtime and current_mtime and current_mtime ~= server_mtime then
      M.stop()
    end

    -- If server is already running, wait for ready or callback immediately
    if server_job and vim.fn.jobwait({ server_job }, 0)[1] == -1 then
      if ready then
        if callback then callback(true) end
      else
        if callback then
        table.insert(ready_callbacks, callback)
        end
      end
      return
    end

    ready = false
    stdout_pending = ""
    if callback then
      table.insert(ready_callbacks, callback)
    end

    server_job = vim.fn.jobstart({
      "node", server_path,
    }, {
      cwd = dir,
      on_stdout = on_stdout,
      on_stderr = on_stderr,
      on_exit = on_exit,
      stdout_buffered = false,
      stderr_buffered = false,
    })

    if server_job <= 0 then
      vim.notify("pi: failed to start diff highlighter server", vim.log.levels.ERROR)
      ready = false
      server_job = nil
      local cbs = ready_callbacks
      ready_callbacks = {}
      if callback then callback(false) end
      for _, cb in ipairs(cbs) do
        if cb ~= callback then vim.schedule(function() cb(false) end) end
      end
    end

    server_mtime = current_mtime
  end

  ensure_dependencies(dir, function(ok)
    if ok then
      start_job()
    elseif callback then
      callback(false)
    end
  end)
end

--- Stop the server process.
function M.stop()
  if server_job and vim.fn.jobwait({ server_job }, 0)[1] == -1 then
    stopping = true
    vim.fn.jobstop(server_job)
  end
  server_job = nil
  ready = false
  stdout_pending = ""
  pending = {}
  ready_callbacks = {}
end

--- Check if the server is ready.
function M.is_ready()
  return options().enabled and ready and server_job ~= nil
end

--- Initialize: start server on first use.
function M.setup()
  if setup_done then return end
  setup_done = true
  M.start()
end

--- Send a highlight request to the server.
---
--- @param patch string Unified diff text
--- @param path string|nil File path (for language detection)
--- @param callback function Called with result table on completion
function M.highlight(patch, path, callback)
  if not callback then
    vim.notify("pi: highlighter.highlight requires a callback", vim.log.levels.ERROR)
    return
  end

  if not options().enabled then
    callback({ success = false, error = "diff highlighting disabled" })
    return
  end

  -- Keep parser/runtime changes hot: if server.mjs changed while the job is
  -- running, recycle it before serving the next request.
  if server_job and vim.fn.jobwait({ server_job }, 0)[1] == -1 then
    local dir = find_server_dir()
    if dir then
      local current_mtime = tonumber(vim.fn.getftime(dir .. "/server.mjs")) or nil
      if server_mtime and current_mtime and current_mtime ~= server_mtime then
        M.stop()
      end
    end
  end

  if not ready or not server_job then
    M.start(function(ok)
      if ok then
        M.highlight(patch, path, callback)
      else
        callback({ success = false, error = "diff highlighter unavailable" })
      end
    end)
    return
  end

  request_id = request_id + 1
  local id = "hl-" .. request_id
  pending[id] = callback

  local request = vim.fn.json_encode({
    type = "highlight",
    id = id,
    patch = patch,
    path = path or "",
  })

  local ok = pcall(vim.api.nvim_chan_send, server_job, request .. "\n")
  if not ok then
    pending[id] = nil
    callback({ success = false, error = "failed to send highlight request" })
  end
end

-- Auto-setup when module loads, but defer actual start
setup_done = false

return M

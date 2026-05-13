--- Diff renderer for pi.nvim changes panel.
---
--- Supports two rendering modes:
--- 1. Plain text (legacy) – simple +/- line-level highlighting
--- 2. Highlighted (new)    – per-token syntax highlighting via @pierre/diffs

local highlighter = require("pi.changes.highlighter")

local M = {}

local function sanitize_line(value)
  local text
  if type(value) == "string" then
    text = value
  elseif value == nil then
    text = ""
  else
    text = tostring(value)
  end
  text = text:gsub("%z", "")
  text = text:gsub("[\r\n]", "")
  return text
end

local function add_highlight(highlights, row, group, col, end_col)
  if type(row) ~= "number" or type(group) ~= "string" or group == "" then return end
  table.insert(highlights, { row, group, tonumber(col) or 0, tonumber(end_col) or -1 })
end

-- ---------------------------------------------------------------------------
-- Highlight group names for syntax tokens
-- Fallback semantic groups used when the server cannot provide a raw color.
-- ---------------------------------------------------------------------------
local TOKEN_HL = {
  keyword = "PiHlKeyword",
  identifier = "PiHlIdentifier",
  type = "PiHlType",
  variable = "PiHlVariable",
  comment = "PiHlComment",
  punctuation = "PiHlPunctuation",
  string = "PiHlString",
  number = "PiHlNumber",
}

local COLOR_HL_CACHE = {}

local function normalize_hex_color(color)
  if type(color) ~= "string" then return nil end
  local hex = color:match("^#([0-9a-fA-F]+)$")
  if not hex then return nil end
  hex = hex:lower()
  if #hex == 3 then
    hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
  end
  if #hex ~= 6 then return nil end
  return "#" .. hex
end

local function token_highlight_group(token_hl)
  if type(token_hl) ~= "string" or token_hl == "" then
    return nil
  end

  local hex = normalize_hex_color(token_hl)
  if hex then
    local key = hex:sub(2):upper()
    local group = COLOR_HL_CACHE[key]
    if not group then
      group = "PiDiffColor" .. key
      COLOR_HL_CACHE[key] = group
      vim.api.nvim_set_hl(0, group, { fg = hex, default = true })
    end
    return group
  end

  return TOKEN_HL[token_hl]
end

-- ---------------------------------------------------------------------------
-- Buffer helpers
-- ---------------------------------------------------------------------------

local function set_content(buf, lines, highlights)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local safe_lines = {}
  for _, line in ipairs(lines or {}) do
    table.insert(safe_lines, sanitize_line(line))
  end
  if #safe_lines == 0 then
    safe_lines = { "" }
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, safe_lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  if not ok then
    vim.notify("pi: failed to render diff: " .. tostring(err), vim.log.levels.WARN)
    return
  end

  if highlights then
    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
    for _, hl in ipairs(highlights) do
      local row, group, col, end_col = hl[1], hl[2], hl[3], hl[4]
      if type(row) == "number" and row >= 0 and row < #safe_lines and type(group) == "string" and group ~= "" then
        local line_len = #(safe_lines[row + 1] or "")
        col = math.max(0, tonumber(col) or 0)
        end_col = tonumber(end_col) or -1
        if end_col == -1 or end_col > line_len then
          end_col = line_len
        end
        if col < end_col then
          pcall(vim.api.nvim_buf_add_highlight, buf, -1, group, row, col, end_col)
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Plain text fallback renderers (unchanged logic)
-- ---------------------------------------------------------------------------

local function plain_diff_lines(diff_text, width)
  local lines = {}
  local highlights = {}

  for _, raw in ipairs(vim.split(diff_text, "\n", { plain = true })) do
    local line = raw:gsub("\x1b%[[%d;]*m", "")
    table.insert(lines, line)
    local row = #lines - 1
    if vim.startswith(line, "diff ") or vim.startswith(line, "@@") then
      add_highlight(highlights, row, "PiChangesHeader", 0, -1)
    elseif vim.startswith(line, "+++ ") or vim.startswith(line, "--- ") then
      add_highlight(highlights, row, "PiChangesFile", 0, -1)
    elseif vim.startswith(line, "+") then
      add_highlight(highlights, row, "DiffAdd", 0, -1)
    elseif vim.startswith(line, "-") then
      add_highlight(highlights, row, "DiffDelete", 0, -1)
    end
  end

  return lines, highlights
end

local function compact_hunk_lines(hunk_lines, keep_context_lines)
  local keep_count = tonumber(keep_context_lines) or 2
  if keep_count <= 0 or not hunk_lines or #hunk_lines == 0 then
    return hunk_lines or {}
  end

  local context_positions = {}
  for idx, line in ipairs(hunk_lines) do
    if line.type == "context" then
      table.insert(context_positions, idx)
    end
  end

  if #context_positions <= keep_count * 2 then
    return hunk_lines
  end

  local keep = {}
  for idx, line in ipairs(hunk_lines) do
    if line.type ~= "context" then
      keep[idx] = true
    end
  end

  for idx, pos in ipairs(context_positions) do
    if idx <= keep_count or idx > (#context_positions - keep_count) then
      keep[pos] = true
    end
  end

  local compacted = {}
  local omitted = false
  for idx, line in ipairs(hunk_lines) do
    if keep[idx] then
      if omitted then
        table.insert(compacted, {
          type = "skip",
          tokens = { { t = "...", h = "comment" } },
        })
        omitted = false
      end
      table.insert(compacted, line)
    else
      omitted = true
    end
  end

  if omitted then
    table.insert(compacted, {
      type = "skip",
      tokens = { { t = "...", h = "comment" } },
    })
  end

  return compacted
end

-- ---------------------------------------------------------------------------
-- Highlighted diff rendering
-- ---------------------------------------------------------------------------

--- Render a diff using the syntax highlighter.
--- The highlighter is called asynchronously; we use a callback pattern.
---
--- @param buf integer  Neovim buffer handle
--- @param width number  Panel content width
--- @param diff { title?: string, text: string, source?: string, tool?: string }
--- @param done? function  Called after rendering completes
function M.diff(buf, width, diff, done)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    if done then done() end
    return
  end
  if not diff or type(diff.text) ~= "string" or diff.text == "" then
    M.empty(buf, "  (no diff)")
    if done then done() end
    return
  end

  local diff_text = diff.text:gsub("\x1b%[[%d;]*m", "")

  -- Render plain text immediately so the user sees something
  local plain_lines, plain_highlights = plain_diff_lines(diff_text, width)
  set_content(buf, plain_lines, plain_highlights)

  -- Then upgrade with syntax highlighting when the highlighter is ready
  local function upgrade_with_highlighting()
    highlighter.highlight(diff_text, diff.source, function(result)
      vim.schedule(function()
        M._render_highlighted(buf, width, diff, result, done)
      end)
    end)
  end

  if highlighter.is_ready() then
    upgrade_with_highlighting()
  else
    highlighter.start(function(ok)
      if ok then
        upgrade_with_highlighting()
      elseif done then
        done()
      end
    end)
  end
end

--- Internal: render highlighted diff result into buffer.
function M._render_highlighted(buf, width, diff, result, done)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    if done then done() end
    return
  end

  local lines = {}
  local highlights = {}

  if not result or not result.success or not result.file then
    -- Highlighter failed, fall back to plain
    local plain_lines, plain_highlights = plain_diff_lines(
      diff.text:gsub("\x1b%[[%d;]*m", ""), width
    )
    vim.list_extend(lines, plain_lines)
    vim.list_extend(highlights, plain_highlights)
    set_content(buf, lines, highlights)
    if done then done() end
    return
  end

  local file = result.file

  -- Add file info
  if file.path then
    table.insert(lines, " " .. file.path)
    add_highlight(highlights, #lines - 1, "PiChangesFile", 0, -1)
    if file.stats and (file.stats.additions > 0 or file.stats.deletions > 0) then
      local stat_line = string.format(
        " +%d/-%d  %s",
        file.stats.additions,
        file.stats.deletions,
        file.language or ""
      )
      table.insert(lines, " " .. stat_line)
      add_highlight(highlights, #lines - 1, "Comment", 0, -1)
    end
    table.insert(lines, " " .. string.rep("─", width))
    add_highlight(highlights, #lines - 1, "PiSeparator", 0, -1)
  end

  -- Render each hunk
  for _, hunk in ipairs(file.hunks or {}) do
    -- Hunk header
    table.insert(lines, " " .. (hunk.header or ""))
    add_highlight(highlights, #lines - 1, "PiChangesHeader", 0, -1)

    -- Render lines with tokens
    local hunk_lines = hunk.lines or {}
    if diff.tool == "edit" then
      hunk_lines = compact_hunk_lines(hunk_lines, 2)
    end

    for _, hunk_line in ipairs(hunk_lines) do
      local row = #lines + 1
      local rendered_line = ""
      local col_tokens = {} -- { {start, end, hl_group}, ... }

      -- Sign column
      if hunk_line.type == "addition" then
        rendered_line = "+"
      elseif hunk_line.type == "deletion" then
        rendered_line = "-"
      elseif hunk_line.type == "skip" then
        rendered_line = "..."
      else
        rendered_line = " "
      end

      -- Tokens
      if hunk_line.tokens and #hunk_line.tokens > 0 then
        for _, token in ipairs(hunk_line.tokens) do
          local text = sanitize_line(token.t)
          if text ~= "" then
            local start_col = #rendered_line
            rendered_line = rendered_line .. text
            local end_col = #rendered_line

            local hl = token_highlight_group(token.h)
            if hl then
              table.insert(col_tokens, {
                start = start_col,
                end_col = end_col,
                hl = hl,
              })
            end
          end
        end
      else
        rendered_line = rendered_line .. " "
      end

      table.insert(lines, rendered_line)

      -- Apply line-level highlights (background tint for add/remove context)
      if hunk_line.type == "addition" then
        add_highlight(highlights, row - 1, "DiffAdd", 0, -1)
      elseif hunk_line.type == "deletion" then
        add_highlight(highlights, row - 1, "DiffDelete", 0, -1)
      elseif hunk_line.type == "skip" then
        add_highlight(highlights, row - 1, "Comment", 0, -1)
      end

      -- Apply token-level highlights on top
      for _, t in ipairs(col_tokens) do
        add_highlight(highlights, row - 1, t.hl, t.start, t.end_col)
      end
    end
  end

  set_content(buf, lines, highlights)
  if done then done() end
end

--- Build header lines and highlights for a diff panel.
--- Returns (lines, highlights) tables.
function M._build_header(buf, width, diff)
  local lines = {}
  local highlights = {}

  local header = " 🔀 " .. (diff.title or "Diff")
  table.insert(lines, header)
  add_highlight(highlights, #lines - 1, "PiChangesHeader", 0, -1)

  local info_parts = {}
  if diff.tool and diff.tool ~= "" then table.insert(info_parts, "tool: " .. diff.tool) end
  if diff.source and diff.source ~= "" then table.insert(info_parts, "file: " .. diff.source) end
  if #info_parts > 0 then
    table.insert(lines, " " .. table.concat(info_parts, "  |  "))
    add_highlight(highlights, #lines - 1, "Comment", 0, -1)
  end
  table.insert(lines, " " .. string.rep("─", width))
  add_highlight(highlights, #lines - 1, "PiSeparator", 0, -1)

  return lines, highlights
end

--- Append header lines and highlights inline (mutates lists).
function M._append_header(lines, highlights, width, diff)
  local hdrs, hls = M._build_header(nil, width, diff)
  vim.list_extend(lines, hdrs)
  vim.list_extend(highlights, hls)
end

-- ---------------------------------------------------------------------------
-- Summary renderer
-- ---------------------------------------------------------------------------

function M.empty(buf, text)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text or "  (no messages yet)" })
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

--- Render summary from extracted last-turn data.
--- @param buf integer
--- @param width number
--- @param data { user_text: string|nil, turn_diffs: table[] }
function M.summary(buf, width, data)
  local lines = {}
  local highlights = {}

  table.insert(lines, " 🔄 Last Turn Edits")
  add_highlight(highlights, #lines - 1, "PiChangesHeader", 0, -1)

  if data.user_text and data.user_text ~= "" then
    local prompt = data.user_text:gsub("%s+", " ")
    if vim.api.nvim_strwidth(prompt) > width - 8 then
      prompt = vim.fn.strcharpart(prompt, 0, width - 10) .. "…"
    end
    table.insert(lines, " prompt: " .. prompt)
    add_highlight(highlights, #lines - 1, "PiChangesPrompt", 0, -1)
  end
  table.insert(lines, " " .. string.rep("─", width))
  add_highlight(highlights, #lines - 1, "PiSeparator", 0, -1)

  if not data.turn_diffs or #data.turn_diffs == 0 then
    table.insert(lines, "")
    table.insert(lines, " (no edit diffs in last turn)")
    add_highlight(highlights, #lines - 1, "Comment", 0, -1)
    set_content(buf, lines, highlights)
    return
  end

  for idx, d in ipairs(data.turn_diffs) do
    table.insert(lines, "")
    local label = string.format(" [%d] %s", idx, d.tool or "tool")
    if d.source and d.source ~= "" then
      label = label .. "  " .. d.source
    end
    table.insert(lines, label)
    add_highlight(highlights, #lines - 1, "PiChangesFile", 0, -1)
    table.insert(lines, " " .. string.rep("─", width))
    add_highlight(highlights, #lines - 1, "PiSeparator", 0, -1)

    -- Use plain rendering for summary (multiple diffs inline)
    local base_row = #lines
    local plain_lines, plain_highlights = plain_diff_lines(d.diff, width)
    vim.list_extend(lines, plain_lines)
    for _, hl in ipairs(plain_highlights) do
      add_highlight(highlights, base_row + hl[1], hl[2], hl[3], hl[4])
    end
  end

  set_content(buf, lines, highlights)
end

--- Render a bash tool call as a terminal transcript.
--- @param buf integer
--- @param width number
--- @param terminal { title?: string, command?: string, output?: string, cwd?: string, exit_code?: number|string }
function M.terminal(buf, width, terminal)
  local lines = {}
  local highlights = {}

  terminal = terminal or {}
  table.insert(lines, " $ " .. (terminal.title or "Terminal"))
  add_highlight(highlights, #lines - 1, "PiChangesHeader", 0, -1)

  local meta = {}
  if terminal.cwd and terminal.cwd ~= "" then table.insert(meta, "cwd: " .. terminal.cwd) end
  if terminal.exit_code ~= nil and terminal.exit_code ~= "" then table.insert(meta, "exit: " .. tostring(terminal.exit_code)) end
  if #meta > 0 then
    table.insert(lines, " " .. table.concat(meta, "  |  "))
    add_highlight(highlights, #lines - 1, "Comment", 0, -1)
  end
  table.insert(lines, " " .. string.rep("─", width))
  add_highlight(highlights, #lines - 1, "PiSeparator", 0, -1)

  local command = type(terminal.command) == "string" and terminal.command or ""
  if command ~= "" then
    for _, raw in ipairs(vim.split(command, "\n", { plain = true })) do
      local line = "$ " .. sanitize_line(raw)
      table.insert(lines, line)
      add_highlight(highlights, #lines - 1, "PiTerminalCommand", 0, -1)
      add_highlight(highlights, #lines - 1, "PiTerminalPrompt", 0, 2)
    end
  end

  local output = type(terminal.output) == "string" and terminal.output or ""
  if output ~= "" then
    if command ~= "" then table.insert(lines, "") end
    for _, raw in ipairs(vim.split(output, "\n", { plain = true })) do
      table.insert(lines, sanitize_line(raw))
      add_highlight(highlights, #lines - 1, "PiTerminalOutput", 0, -1)
    end
  elseif command == "" then
    table.insert(lines, "")
    table.insert(lines, " (no terminal output)")
    add_highlight(highlights, #lines - 1, "Comment", 0, -1)
  end

  set_content(buf, lines, highlights)
end

return M

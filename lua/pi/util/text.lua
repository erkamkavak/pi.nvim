local M = {}

local function looks_like_garbled_text(text)
	if type(text) ~= "string" or text == "" then return false end

	local repl_count = select(2, text:gsub("�", ""))
	local char_count = math.max(vim.fn.strchars(text), 1)
	if repl_count >= 64 and (repl_count / char_count) >= 0.12 then
		return true
	end

	local triplet_count = select(2, text:gsub("<%x%x><%x%x><%x%x>", ""))
	if triplet_count >= 12 then
		local approx_bytes = triplet_count * 12
		if (approx_bytes / math.max(#text, 1)) >= 0.25 then
			return true
		end
	end

	return false
end

local function normalize_render_text(text)
	if type(text) ~= "string" then return text end
	if looks_like_garbled_text(text) then
		return "[binary or invalid UTF-8 content omitted]"
	end
	return text
end

--- Remove control codes and hard line breaks from a single display line.
--- @param text any
--- @return string
function M.sanitize_line(text)
	if type(text) ~= "string" then
		text = text == nil and "" or tostring(text)
	end
	local sanitized = text
		:gsub("\x1b%[[%d;]*m", "")
		:gsub("[%z\1-\8\11\12\14-\31\127]", " ")
		:gsub("\r", "")
		:gsub("\n", " ")
	return sanitized
end

--- Truncate a string to display width with ellipsis.
--- @param text string|nil
--- @param width number
--- @return string
function M.truncate_display(text, width)
	if not text then return "" end
	if width <= 0 then return "" end
	if vim.fn.strdisplaywidth(text) <= width then return text end
	local out = text
	while #out > 0 and vim.fn.strdisplaywidth(out .. "…") > width do
		out = out:sub(1, -2)
	end
	if out == "" then return "…" end
	return out .. "…"
end

--- Soft-wrap text by display width.
--- @param text string|nil
--- @param width number
--- @return string[]
function M.wrap(text, width)
	if not text or text == "" then return { "" } end
	local result = {}
	for _, raw in ipairs(vim.split(text, "\n")) do
		local line = raw:gsub("\x1b%[[%d;]*m", "")
		if line == "" then
			table.insert(result, "")
		elseif vim.fn.strdisplaywidth(line) <= width then
			table.insert(result, line)
		else
			local r = line
			while r ~= "" do
				if vim.fn.strdisplaywidth(r) <= width then
					table.insert(result, r)
					break
				end

				local best_char = 0
				local split_char = 0
				local char_count = vim.fn.strchars(r)
				for i = 1, char_count do
					local chunk = vim.fn.strcharpart(r, 0, i)
					if vim.fn.strdisplaywidth(chunk) > width then break end
					best_char = i
					if vim.fn.strcharpart(r, i - 1, 1) == " " then
						split_char = i
					end
				end

				local split_at = split_char > 0 and split_char or math.max(best_char, 1)
				local head = vim.fn.strcharpart(r, 0, split_at):gsub("%s+$", "")
				table.insert(result, head)
				r = vim.fn.strcharpart(r, split_at):gsub("^%s+", "")
			end
		end
	end
	return result
end

--- Extract plain text from a message object (string content or text blocks).
--- @param msg table|nil
--- @param opts? { max_chars?: integer, detect_garbled?: boolean }
--- @return string|nil
function M.extract_message_text(msg, opts)
	if not msg then return nil end
	opts = opts or {}
	local max_chars = opts.max_chars
	local detect_garbled = opts.detect_garbled ~= false

	local content = msg.content
	if not content then return nil end

	local function finalize(text)
		if detect_garbled then
			text = normalize_render_text(text)
		end
		if type(max_chars) == "number" and max_chars > 0 and vim.fn.strchars(text) > max_chars then
			text = vim.fn.strcharpart(text, 0, max_chars) .. "\n...[truncated]"
		end
		return text
	end

	if type(content) == "string" then
		return finalize(content)
	end

	if type(content) == "table" then
		local parts = {}
		for _, block in ipairs(content) do
			if block.type == "text" and type(block.text) == "string" then
				table.insert(parts, block.text)
			end
		end
		if #parts == 0 then return nil end
		return finalize(table.concat(parts, "\n"))
	end

	return nil
end

return M

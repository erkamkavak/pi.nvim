local M = {}

-- Preserve Markdown syntax and let Neovim / render-markdown.nvim do the visual
-- rendering. The chat renderer still owns layout, headers, tool rows, and
-- scrolling, so this module only normalizes Markdown text into buffer lines.
local function wrap_line(line, width)
	if line == "" or vim.fn.strdisplaywidth(line) <= width then
		return { line }
	end

	local indent = line:match("^(%s*)") or ""
	local marker = ""
	local rest = line:sub(#indent + 1)
	local list_marker, list_text = rest:match("^([%-%*%+]%s+)(.*)$")
	local ordered_marker, ordered_text = rest:match("^(%d+%.%s+)(.*)$")
	local quote_marker, quote_text = rest:match("^(>%s?)(.*)$")

	if list_marker then
		marker, rest = list_marker, list_text
	elseif ordered_marker then
		marker, rest = ordered_marker, ordered_text
	elseif quote_marker then
		marker, rest = quote_marker, quote_text
	end

	local first_prefix = indent .. marker
	local next_prefix = indent .. string.rep(" ", vim.fn.strdisplaywidth(marker))
	local lines = {}
	local current = first_prefix
	local current_width = vim.fn.strdisplaywidth(current)

	for word, space in (rest .. " "):gmatch("(%S+)(%s*)") do
		local chunk = word .. (space ~= "" and " " or "")
		local chunk_width = vim.fn.strdisplaywidth(chunk)
		if current_width + chunk_width > width and current ~= first_prefix and current ~= next_prefix then
			local trimmed = current:gsub("%s+$", "")
			table.insert(lines, trimmed)
			current = next_prefix .. chunk
			current_width = vim.fn.strdisplaywidth(current)
		else
			current = current .. chunk
			current_width = current_width + chunk_width
		end
	end

	if current:gsub("%s+", "") ~= "" then
		local trimmed = current:gsub("%s+$", "")
		table.insert(lines, trimmed)
	end
	return #lines > 0 and lines or { line }
end

function M.render(text, opts)
	if type(text) ~= "string" or text == "" then
		return {}, {}
	end

	opts = opts or {}
	local width = math.max(opts.width or 78, 10)
	local lines = {}
	local in_code_block = false

	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		if line:match("^%s*```") or line:match("^%s*~~~") then
			table.insert(lines, line)
			in_code_block = not in_code_block
		elseif in_code_block or line:find("|", 1, true) then
			table.insert(lines, line)
		else
			for _, wrapped in ipairs(wrap_line(line, width)) do
				table.insert(lines, wrapped)
			end
		end
	end

	return lines, {}
end

return M

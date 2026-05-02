local M = {}

--- Decode JSON safely across Neovim versions.
--- @param raw string|nil
--- @return table|nil
function M.decode(raw)
	if not raw or raw == "" then return nil end
	if vim.json and vim.json.decode then
		local ok, parsed = pcall(vim.json.decode, raw)
		if ok then return parsed end
	end
	local ok, parsed = pcall(vim.fn.json_decode, raw)
	if ok then return parsed end
	return nil
end

return M

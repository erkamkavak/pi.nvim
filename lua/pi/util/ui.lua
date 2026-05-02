local M = {}

--- Shared UI margins in editor columns/rows.
--- @param config table
--- @return integer, integer
function M.get_margins(config)
	local mx = tonumber(config.options.ui_margin_cols) or 0
	local my = tonumber(config.options.ui_margin_rows) or 0
	return math.max(0, math.floor(mx)), math.max(0, math.floor(my))
end

return M

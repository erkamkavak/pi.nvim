-- Autoloaded commands for pi.nvim
-- This file is loaded when Neovim starts if the plugin is installed

-- Commands are created in init.lua setup()
-- This file ensures the plugin is available for lazy loading

vim.api.nvim_create_autocmd("User", {
	pattern = "VeryLazy",
	once = true,
	callback = function()
		-- Preload config but don't set up until user calls require("pi").setup()
	end,
})

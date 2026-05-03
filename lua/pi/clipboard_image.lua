local M = {}

local SUPPORTED_MIME_TYPES = {
	["image/png"] = "png",
	["image/jpeg"] = "jpg",
	["image/webp"] = "webp",
	["image/gif"] = "gif",
}

--- Check if the system is running under Wayland.
local function is_wayland()
	return os.getenv("WAYLAND_DISPLAY") ~= nil or os.getenv("XDG_SESSION_TYPE") == "wayland"
end

--- Select the preferred image MIME type from a list.
local function select_preferred_mime_type(types_str)
	if not types_str or types_str == "" then return nil end
	for _, preferred in ipairs({ "image/png", "image/jpeg", "image/webp", "image/gif" }) do
		if types_str:find(preferred, 1, true) then
			return preferred
		end
	end
	-- Fallback: any image type
	for line in types_str:gmatch("[^\r\n]+") do
		if line:match("^image/") then
			return line:gsub("%s+", "")
		end
	end
	return nil
end

--- Read clipboard image via wl-paste (Wayland).
--- Returns: { path = string, mimeType = string } or nil
function M.read_via_wl_paste()
	if vim.fn.executable("wl-paste") ~= 1 then return nil end
	local list = vim.fn.system("wl-paste --list-types 2>/dev/null")
	if vim.v.shell_error ~= 0 then return nil end
	local mime = select_preferred_mime_type(list)
	if not mime then return nil end

	local tmp = vim.fn.tempname() .. "." .. (SUPPORTED_MIME_TYPES[mime] or "png")
	local cmd = string.format("wl-paste --type '%s' --no-newline > '%s' 2>/dev/null", mime, tmp)
	vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		vim.fn.delete(tmp)
		return nil
	end
	return { path = tmp, mimeType = mime }
end

--- Read clipboard image via xclip (X11).
--- Returns: { path = string, mimeType = string } or nil
function M.read_via_xclip()
	if vim.fn.executable("xclip") ~= 1 then return nil end
	local targets = vim.fn.system("xclip -selection clipboard -t TARGETS -o 2>/dev/null")
	local mime = nil
	if vim.v.shell_error == 0 and targets ~= "" then
		mime = select_preferred_mime_type(targets)
	end
	-- Try supported types in order if no TARGETS or no match
	local try_types = mime and { mime } or { "image/png", "image/jpeg", "image/webp", "image/gif" }
	for _, try_mime in ipairs(try_types) do
		local tmp = vim.fn.tempname() .. "." .. (SUPPORTED_MIME_TYPES[try_mime] or "png")
		local cmd = string.format("xclip -selection clipboard -t '%s' -o > '%s' 2>/dev/null", try_mime, tmp)
		vim.fn.system(cmd)
		if vim.v.shell_error == 0 then
			local size = vim.fn.getfsize(tmp)
			if size and size > 0 then
				return { path = tmp, mimeType = try_mime }
			end
			vim.fn.delete(tmp)
		end
	end
	return nil
end

--- Read clipboard image via pngpaste (macOS).
--- Returns: { path = string, mimeType = string } or nil
function M.read_via_pngpaste()
	if vim.fn.executable("pngpaste") ~= 1 then return nil end
	local tmp = vim.fn.tempname() .. ".png"
	vim.fn.system("pngpaste '" .. tmp .. "' 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		vim.fn.delete(tmp)
		return nil
	end
	return { path = tmp, mimeType = "image/png" }
end

--- Read clipboard image via PowerShell (Windows/WSL fallback).
--- Returns: { path = string, mimeType = string } or nil
function M.read_via_powershell()
	if vim.fn.executable("powershell.exe") ~= 1 then return nil end
	local tmp = vim.fn.tempname() .. ".png"
	local win_path = vim.fn.system("wslpath -w '" .. tmp .. "' 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		vim.fn.delete(tmp)
		return nil
	end
	win_path = win_path:gsub("%s+$", "")
	if win_path == "" then
		vim.fn.delete(tmp)
		return nil
	end

	local ps_script = table.concat({
		"Add-Type -AssemblyName System.Windows.Forms;",
		"Add-Type -AssemblyName System.Drawing;",
		"$img = [System.Windows.Forms.Clipboard]::GetImage();",
		"if ($img) { $img.Save('" .. win_path:gsub("'", "''") .. "', [System.Drawing.Imaging.ImageFormat]::Png); Write-Output 'ok' } else { Write-Output 'empty' }",
	}, " ")

	local result = vim.fn.system("powershell.exe -NoProfile -Command '" .. ps_script .. "' 2>/dev/null")
	if vim.v.shell_error ~= 0 or result:gsub("%s+", "") ~= "ok" then
		vim.fn.delete(tmp)
		return nil
	end

	local size = vim.fn.getfsize(tmp)
	if not size or size == 0 then
		vim.fn.delete(tmp)
		return nil
	end
	return { path = tmp, mimeType = "image/png" }
end

--- Read an image from the system clipboard.
--- Tries Wayland → X11 → macOS → Windows/WSL in order.
--- Returns: { path = string, mimeType = string } or nil
function M.read_clipboard_image()
	local uname = vim.loop.os_uname()
	local sysname = uname.sysname

	-- Termux: not supported
	if os.getenv("TERMUX_VERSION") then
		return nil
	end

	if sysname == "Linux" then
		local wayland = is_wayland()
		local wsl = os.getenv("WSL_DISTRO_NAME") or os.getenv("WSLENV")

		if wayland or wsl then
			local img = M.read_via_wl_paste()
			if img then return img end
			img = M.read_via_xclip()
			if img then return img end
		end

		if wsl then
			local img = M.read_via_powershell()
			if img then return img end
		end

		if not wayland then
			return M.read_via_xclip()
		end

		return nil
	elseif sysname == "Darwin" then
		return M.read_via_pngpaste()
	else
		-- Windows native (not WSL) - try PowerShell
		return M.read_via_powershell()
	end
end

--- Encode a file to base64 string.
--- @param path string
--- @return string|nil
function M.file_to_base64(path)
	if not path or vim.fn.filereadable(path) ~= 1 then return nil end
	local file = io.open(path, "rb")
	if not file then return nil end
	local data = file:read("*a")
	file:close()
	if not data or #data == 0 then return nil end

	-- Pure-Lua base64 encode (RFC 4648, no line wraps).
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local out = {}
	local len = #data
	local i = 1

	while i <= len do
		local a = data:byte(i) or 0
		local b = data:byte(i + 1) or 0
		local c = data:byte(i + 2) or 0
		local n = a * 65536 + b * 256 + c

		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64

		out[#out + 1] = alphabet:sub(c1 + 1, c1 + 1)
		out[#out + 1] = alphabet:sub(c2 + 1, c2 + 1)

		if i + 1 <= len then
			out[#out + 1] = alphabet:sub(c3 + 1, c3 + 1)
		else
			out[#out + 1] = "="
		end

		if i + 2 <= len then
			out[#out + 1] = alphabet:sub(c4 + 1, c4 + 1)
		else
			out[#out + 1] = "="
		end

		i = i + 3
	end

	return table.concat(out)
end

--- Clean up temporary image files.
--- @param images table[] Array of { path = string }
function M.cleanup(images)
	if not images then return end
	for _, img in ipairs(images) do
		if img.path and vim.fn.filereadable(img.path) == 1 then
			vim.fn.delete(img.path)
		end
	end
end

return M

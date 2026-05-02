local M = {}

--- Resolve a git base directory for an absolute path.
--- @param path string
--- @return string|nil
function M.resolve_git_base_for_path(path)
	if not path or path == "" then return nil end
	local abs = vim.fn.fnamemodify(path, ":p")
	if vim.fn.isdirectory(abs) == 1 then return abs end
	local dir = vim.fn.fnamemodify(abs, ":h")
	if vim.fn.isdirectory(dir) == 1 then return dir end
	return vim.fn.getcwd()
end

--- Read unstaged diff for a file path; handles untracked files too.
--- @param path string
--- @param opts? { notify_no_diff?: boolean }
--- @return string|nil
function M.get_diff_for_file(path, opts)
	opts = opts or {}
	if not path or path == "" then return nil end
	local abs = vim.fn.fnamemodify(path, ":p")
	if vim.fn.filereadable(abs) == 0 then
		vim.notify("pi: file not found: " .. abs, vim.log.levels.WARN)
		return nil
	end

	local git_base = M.resolve_git_base_for_path(abs)
	if not git_base or vim.fn.isdirectory(git_base) == 0 then
		vim.notify("pi: cannot resolve git base for " .. abs, vim.log.levels.WARN)
		return nil
	end

	local rel = abs
	local root = git_base:gsub("/+$", "")
	if abs:sub(1, #root) == root then
		rel = abs:sub(#root + 2)
	end

	local cmd = string.format(
		"git -C %s --no-pager diff -- %s",
		vim.fn.shellescape(git_base),
		vim.fn.shellescape(rel)
	)
	local out = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		local cmd_abs = string.format(
			"git -C %s --no-pager diff -- %s",
			vim.fn.shellescape(git_base),
			vim.fn.shellescape(abs)
		)
		out = vim.fn.systemlist(cmd_abs)
	end
	local text = table.concat(out or {}, "\n")
	if text ~= "" then
		return text
	end

	-- Untracked file: synthesize add-from-/dev/null style diff.
	if vim.fn.filereadable(abs) == 1 then
		local untracked_cmd = string.format(
			"git --no-pager diff --no-index -- /dev/null %s",
			vim.fn.shellescape(abs)
		)
		local untracked_out = vim.fn.systemlist(untracked_cmd)
		local untracked_text = table.concat(untracked_out or {}, "\n")
		if untracked_text ~= "" then
			return untracked_text
		end
	end

	if opts.notify_no_diff ~= false then
		vim.notify("pi: no unstaged diff for " .. abs, vim.log.levels.INFO)
	end
	return nil
end

return M

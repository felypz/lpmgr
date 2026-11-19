local data_home = os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or ".") .. "/.local/share")

local M = {
	repo_url = os.getenv("LIC_PLUGINS_REPO") or "https://github.com/felipe/lic-plugins.git",
	cache_dir = data_home .. "/lic/lpmgr/repo",
	plugins_dir = data_home .. "/lic/plugins",
}

local BUF = "[lpmgr]"

local function trim(s)
	return (s or ""):match("^%s*(.-)%s*$")
end

local function sh_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function log_line(msg, open_buf)
	lic.echo(msg, BUF)
	if open_buf then
		lic.switch_buffer(BUF)
	end
end

local function run_cmd(cmd)
	local p = io.popen(cmd .. " 2>&1")
	if not p then
		return false, "failed to spawn shell command"
	end
	local out = p:read("*a") or ""
	local ok = p:close()
	return (ok == true or ok == 0), trim(out)
end

local function path_exists(path)
	local ok = run_cmd("test -e " .. sh_quote(path))
	return ok
end

local function ensure_dirs()
	os.execute("mkdir -p " .. sh_quote(M.cache_dir) .. " " .. sh_quote(M.plugins_dir))
end

local function resolve_remote_ref()
	local ok, sym = run_cmd(
		"git -C " .. sh_quote(M.cache_dir) .. " symbolic-ref --quiet --short refs/remotes/origin/HEAD"
	)
	if ok and sym ~= "" then
		return sym
	end

	local ok_main = run_cmd(
		"git -C " .. sh_quote(M.cache_dir) .. " rev-parse --verify --quiet refs/remotes/origin/main"
	)
	if ok_main then
		return "origin/main"
	end

	return "origin/master"
end

local function ensure_cache(open_buf)
	ensure_dirs()
	if not path_exists(M.cache_dir .. "/.git") then
		log_line("Cloning plugin repo from " .. M.repo_url .. "...", open_buf)
		local ok, out = run_cmd(
			"git clone --depth=50 " .. sh_quote(M.repo_url) .. " " .. sh_quote(M.cache_dir)
		)
		if not ok then
			log_line("ERROR cloning repo: " .. out, true)
			return false
		end
		log_line("Clone complete.", open_buf)
		return true
	end

	local ok, out = run_cmd("git -C " .. sh_quote(M.cache_dir) .. " fetch --quiet origin")
	if not ok then
		log_line("ERROR fetching updates: " .. out, true)
		return false
	end
	return true
end

local function list_installed_plugins()
	local list = {}
	local p = io.popen("ls -1 " .. sh_quote(M.plugins_dir) .. "/*.lua 2>/dev/null")
	if not p then
		return list
	end
	for path in p:lines() do
		local name = path:match("([^/]+)%.lua$")
		if name and name ~= "lpmgr" then
			table.insert(list, name)
		end
	end
	p:close()
	table.sort(list)
	return list
end

local function list_remote_plugins()
	local list = {}
	local src_dir = M.cache_dir .. "/plugins"
	local p = io.popen("ls -1 " .. sh_quote(src_dir) .. "/*.lua 2>/dev/null")
	if not p then
		return list
	end
	for path in p:lines() do
		local name = path:match("([^/]+)%.lua$")
		if name then
			table.insert(list, name)
		end
	end
	p:close()
	table.sort(list)
	return list
end

local function copy_plugin(name)
	local src = M.cache_dir .. "/plugins/" .. name .. ".lua"
	local dst = M.plugins_dir .. "/" .. name .. ".lua"
	if not path_exists(src) then
		log_line("ERROR plugin not found in repo: " .. name .. ".lua", true)
		return false
	end
	local ok, out = run_cmd("cp " .. sh_quote(src) .. " " .. sh_quote(dst))
	if not ok then
		log_line("ERROR installing " .. name .. ": " .. out, true)
		return false
	end
	return true
end

local function cmd_list()
	local installed = list_installed_plugins()
	log_line("=== Installed plugins (" .. tostring(#installed) .. ") ===", true)
	if #installed == 0 then
		log_line("  (none in " .. M.plugins_dir .. ")", false)
		return
	end
	for _, name in ipairs(installed) do
		log_line("  * " .. name .. ".lua", false)
	end
end

local function cmd_outdated()
	if not ensure_cache(true) then
		return
	end
	local ref = resolve_remote_ref()
	local ok, diff = run_cmd(
		"git -C "
			.. sh_quote(M.cache_dir)
			.. " diff --name-only HEAD.."
			.. sh_quote(ref)
			.. " -- 'plugins/*.lua'"
	)
	if not ok then
		log_line("ERROR checking updates against " .. ref .. ": " .. diff, true)
		return
	end
	log_line("=== Upstream changes (HEAD.." .. ref .. ") ===", true)
	if diff == "" then
		log_line("  All plugins up to date.", false)
		return
	end
	for line in diff:gmatch("[^\r\n]+") do
		log_line("  ~ " .. line, false)
	end
end

local function cmd_install(args)
	if not ensure_cache(true) then
		return
	end
	local targets = {}
	if args == "" or args == "all" then
		targets = list_remote_plugins()
	else
		for token in args:gmatch("%S+") do
			table.insert(targets, token:gsub("%.lua$", ""))
		end
	end

	if #targets == 0 then
		log_line("No plugins found to install.", true)
		return
	end

	for _, name in ipairs(targets) do
		if copy_plugin(name) then
			log_line("Installed " .. name .. ".lua", true)
		end
	end
	log_line("Run /reload or :reload to load newly installed plugins.", true)
end

local function cmd_update(args)
	if not ensure_cache(true) then
		return
	end
	local ok, out = run_cmd("git -C " .. sh_quote(M.cache_dir) .. " pull --ff-only")
	if not ok then
		log_line("ERROR pulling repo: " .. out, true)
		return
	end

	local targets = {}
	if trim(args) == "" or trim(args) == "all" then
		targets = list_installed_plugins()
	else
		for token in args:gmatch("%S+") do
			table.insert(targets, token:gsub("%.lua$", ""))
		end
	end

	for _, name in ipairs(targets) do
		if copy_plugin(name) then
			log_line("Updated " .. name .. ".lua", true)
		end
	end
	log_line("Update finished. Run /reload or :reload to apply.", true)
end

local function cmd_remove(args)
	local name = trim(args):gsub("%.lua$", "")
	if name == "" then
		log_line("Usage: /lpmgr remove <plugin>", true)
		return
	end
	local dst = M.plugins_dir .. "/" .. name .. ".lua"
	local ok, out = run_cmd("rm -f " .. sh_quote(dst))
	if not ok then
		log_line("ERROR removing " .. name .. ": " .. out, true)
		return
	end
	log_line("Removed " .. name .. ".lua (run /reload or :reload to unload)", true)
end

lic.command("lpmgr", function(raw_arg)
	local line = trim(raw_arg)
	local sub, rest = line:match("^(%S+)%s*(.-)$")
	sub = (sub or "list"):lower()
	rest = trim(rest)

	if sub == "list" or sub == "ls" then
		cmd_list()
	elseif sub == "outdated" then
		cmd_outdated()
	elseif sub == "install" then
		cmd_install(rest)
	elseif sub == "update" then
		cmd_update(rest)
	elseif sub == "remove" or sub == "rm" then
		cmd_remove(rest)
	else
		log_line("Usage: /lpmgr <list|ls|outdated|install|update|remove> [args]", true)
	end
end)

return M

local uv = vim.loop
local log = require("codeium.log")
local Path = require("plenary.path")
local Job = require("plenary.job")
local curl = require("plenary.curl")
local config = require("codeium.config")
local default_mod = 438 -- 666

local has_http, http = pcall(require, "http")
if has_http then
	has_http = http.supported()
end

local M = {}

local function check_job(job, status)
	if status == 0 then
		return job, nil
	else
		if job.enable_recording then
			return job,
				{
					code = status,
					out = table.concat(job:result(), "\n"),
					err = table.concat(job:stderr_result(), "\n"),
				}
		else
			return job, { code = status }
		end
	end
end

local function check_job_wrap(fn)
	return function(job, status)
		fn(check_job(job, status))
	end
end

function M.executable(path)
	local override = config.options.tools[path]
	if override then
		return vim.fn.executable(override)
	end
	return vim.fn.executable(path)
end

function M.touch(path)
	local fd, err = uv.fs_open(path, "w+", default_mod)
	if err or not fd then
		log.error("failed to create file ", path, ": ", err)
		return nil
	end

	local stat
	stat, err = uv.fs_fstat(fd)
	uv.fs_close(fd)

	if err or not stat then
		log.error("could not stat ", path, ": ", err)
		return nil
	end

	return stat.mtime.sec
end

function M.stat_mtime(path)
	local stat, err = uv.fs_stat(path)
	if err or not stat then
		log.error("could not stat ", path, ": ", err)
		return nil
	end

	return stat.mtime.sec
end

function M.exists(path)
	local stat, err = uv.fs_stat(path)
	if err or not stat then
		return false
	end
	return stat.type == "file"
end

function M.readdir(path)
	local fd, err = uv.fs_opendir(path, nil, 1000)
	if err then
		log.error("could not open dir ", path, ": ", err)
		return {}
	end

	local entries, err = uv.fs_readdir(fd)
	uv.fs_closedir(fd)
	if err then
		log.error("could not read dir ", path, ":", err)
		return {}
	end

	return entries
end

function M.tempdir(suffix)
	local dir = vim.fn.tempname() .. (suffix or "")
	vim.fn.mkdir(dir, "p")
	return dir
end

function M.timer(delay, rep, fn)
	local timer = uv.new_timer()
	fn = vim.schedule_wrap(fn)
	local function cancel()
		if timer then
			pcall(timer.stop, timer)
			pcall(timer.close, timer)
		end
		timer = nil
	end
	local function callback()
		if timer then
			fn(cancel)
		end
	end

	timer:start(delay, rep, callback)
	return cancel
end

function M.read_json(path)
	local fd, err, errcode = uv.fs_open(path, "r", default_mod)
	if err or not fd then
		if errcode == "ENOENT" then
			return nil, errcode
		end
		log.error("could not open ", path, ": ", err)
		return nil, errcode
	end

	local stat, err, errcode = uv.fs_fstat(fd)
	if err or not stat then
		uv.fs_close(fd)
		log.error("could not stat ", path, ": ", err)
		return nil, errcode
	end

	local contents, err, errcode = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	if err then
		log.error("could not read ", path, ": ", err)
		return nil, errcode
	end

	local ok, json = pcall(vim.fn.json_decode, contents)
	if not ok then
		log.error("could not parse json in ", path, ": ", err)
		return nil, json
	end

	return json, nil
end

function M.write_json(path, json)
	local ok, text = pcall(vim.fn.json_encode, json)
	if not ok then
		log.error("could not encode JSON ", path, ": ", text)
		return nil, text
	end

	local parent = Path:new(path):parent().filename
	local ok, err = pcall(vim.fn.mkdir, parent, "p")
	if not ok then
		log.error("could not create directory ", parent, ": ", err)
		return nil, err
	end

	local fd, err, errcode = uv.fs_open(path, "w+", default_mod)
	if err or not fd then
		log.error("could not open ", path, ": ", err)
		return nil, errcode
	end

	local size, err, errcode = uv.fs_write(fd, text, 0)
	uv.fs_close(fd)
	if err then
		log.error("could not write ", path, ": ", err)
		return nil, errcode
	end

	return size, nil
end

function M.get_command_output(...)
	local job = M.job({ ... })
	local output, err = job:sync(1000)
	if err and err ~= 0 then
		log.debug("job failed ", err)
		return nil, err
	end
	local result, err = check_job(job, err)
	if err then
		log.debug("job failed: ", err)
		return nil, err
	else
		return output[1], nil
	end
end

local system_info_cache = nil
function M.get_system_info()
	if system_info_cache then
		return system_info_cache
	end

	local uname = vim.loop.os_uname()
	local os = uname.sysname

	if os == "Linux" then
		os = "linux"
	elseif os == "Darwin" then
		os = "macos"
	elseif os == "Windows_NT" then
		os = "windows"
	else
		require("codeium.notify").warn("Unknown sysname: ", os)
	end

	local arch = uname.machine

	if os == "macos" and arch == "arm64" then
		arch = "aarch64"
	end

	system_info_cache = {
		os = os,
		arch = arch,
		is_arm = arch == "arm",
		is_aarch = arch == "aarch64",
		is_x86 = arch == "x86_64",
		is_unix = os == "linux" or os == "macos",
		is_windows = os == "windows",
	}
	return system_info_cache
end

-- @return plenary.Job
function M.job(cmd)
	local o = config.options
	local tool_name = cmd[1]
	local tool = o.tools[tool_name]
	local wrapper

	if tool then
		wrapper = tool
	else
		wrapper = o.wrapper
	end

	if wrapper then
		if type(wrapper) == "string" then
			wrapper = { wrapper }
		end

		local wrap = #wrapper
		local num = #cmd
		local offset
		if tool then
			-- tools directly replace the binary
			offset = -1
		else
			offset = 0
		end

		for i = num, 1, -1 do
			cmd[i + wrap + offset] = cmd[i]
		end
		for i = 1, wrap do
			cmd[i] = wrapper[i]
		end
	end

	local result = {}
	result.args = {}

	for k, v in pairs(cmd) do
		if type(k) == "number" then
			if k == 1 then
				result.command = v
			else
				result.args[k - 1] = v
			end
		elseif type(v) == "function" then
			if k == "on_exit" then
				v = check_job_wrap(v)
			end
			result[k] = vim.schedule_wrap(v)
		else
			result[k] = v
		end
	end

	return Job:new(result)
end

function M.generate_uuid()
	local uuid
	local os = M.get_system_info()

	if os.is_windows then
		uuid = string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
			return string.format("%x", (c == "x") and (math.random(16) - 1) or (((math.random(16) - 1) % 4) + 8))
		end)
	end
	if not M.executable("uuidgen") then
		error("uuiden could not be found")
	else
		local err
		uuid, err = M.get_command_output("uuidgen")
		if err then
			error("failed to generate UUID: " .. vim.inspect(err))
		end
	end
	return uuid
end

function M.gunzip(path, callback)
	local os = M.get_system_info()

	if os.is_windows then
		M.job({
			"powershell.exe",
			"-noprofile",
			"-command",
			"\"Expand-Archive -Path '",
			path,
			"' -DestinationPath '",
			".",
			"'\"",
			on_exit = callback,
		}):start()
	else
		if not M.executable("gzip") then
			callback(nil, "gzip could not be found")
		else
			M.job({
				"gzip",
				"-d",
				path,
				on_exit = callback,
			}):start()
		end
	end
end

function M.set_executable(path, callback)
	if M.get_system_info().os == "windows" then
		-- determined by the filename
		-- improvement: potentially unblock the file
		callback(nil, nil)
	else
		M.job({
			"chmod",
			"+x",
			path,
			on_exit = callback,
		}):start()
	end
end

function M.download(url, path, callback)
	if has_http then
		http.request({
			http.methods.GET,
			url,
			nil,
			path,
			callback = vim.schedule_wrap(function(err, resp)
				if err then
					callback(nil, "failed to download file " .. err)
				elseif resp.code < 200 or resp.code > 399 then
					callback(resp, "http response " .. resp.status)
				else
					callback(resp, nil)
				end
			end),
		})
	else
		curl.get(url, {
			output = path,
			compressed = false,
			callback = vim.schedule_wrap(function(out)
				if out.exit ~= 0 then
					callback(out, "curl exited with status code " .. out)
				elseif out.status < 200 or out.status > 399 then
					callback(out, "http response " .. out.status)
				else
					callback(out, nil)
				end
			end),
		})
	end
end

function M.post(url, params)
	if type(params.body) == "table" then
		params.headers = params.headers or {}
		params.headers["content-type"] = params.headers["content-type"] or "application/json"
		params.body = vim.fn.json_encode(params.body)
	end

	local cb = vim.schedule_wrap(params.callback)

	if has_http then
		params[1] = http.methods.POST
		params[2] = url
		params[3] = params.body
		params.body = nil
		params.callback = function(err, resp)
			if err then
				cb(nil, {
					code = 1,
					err = err,
				})
			elseif resp.code > 299 then
				cb(resp.body, {
					code = 0,
					status = resp.code,
					response = resp,
					out = resp.body,
				})
			else
				cb(resp.body, nil)
			end
		end
		http.request(params)
	else
		params.callback = function(out, _)
			if out.exit ~= 0 then
				cb(nil, {
					code = out.exit,
					err = "curl failed",
				})
			elseif out.status > 299 then
				cb(out.body, {
					code = 0,
					status = out.status,
					response = out,
					out = out.body,
				})
			else
				cb(out.body, nil)
			end
		end

		curl.post(url, params)
	end
end

function M.shell_open(...)
	local info = M.get_system_info()
	if info.os == "linux" then
		return M.get_command_output("xdg-open", ...)
	elseif info.os == "macos" then
		return M.get_command_output("/usr/bin/open", ...)
	else
		return M.get_command_output("start", ...)
	end
end

return M

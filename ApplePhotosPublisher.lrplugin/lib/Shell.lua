--[[
    Shell Utilities

    Shell command execution with output capture. Lightroom's LrTasks.execute()
    only returns the launcher's status. Capture the helper's XML, stderr, and
    kernel termination record separately from the launcher's diagnostics.
]]

local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

local M = {}

--- Shell-escape a string using single-quote wrapping.
--- Any embedded single quotes are handled by ending the quoted segment,
--- adding an escaped single quote, and starting a new quoted segment.
--- @param str string The string to escape
--- @return string The shell-safe escaped string
function M.escape(str)
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

--- Read and remove a capture file after the app exits.
local function readCapture(path)
    local output = ''
    local file = io.open(path, 'r')
    if file then
        output = file:read('*a')
        file:close()
    end
    LrFileUtils.delete(path)
    return output
end

--- Validate the monitor's versioned record before using it to judge success.
local function parseExitRecord(text)
    local record = {}
    for line in text:gmatch('[^\r\n]+') do
        local key, value = line:match('^(%w+)=(%w+)$')
        if not key or record[key] then return nil end
        record[key] = value
    end
    if record.version ~= '1' then return nil end
    if record.state == 'startupFailed' or record.state == 'monitorFailed' then return record end
    record.pid = tonumber(record.pid)
    record.rawStatus = tonumber(record.rawStatus)
    if not record.pid or record.pid <= 1 or not record.rawStatus
        or record.rawStatus < 0 or record.rawStatus > 65535 then return nil end
    local signal = record.rawStatus % 128
    if record.state == 'exited' then
        record.exitCode = tonumber(record.exitCode)
        if signal ~= 0 or record.exitCode ~= math.floor(record.rawStatus / 256) then return nil end
    elseif record.state == 'signaled' then
        record.signal = tonumber(record.signal)
        if signal == 0 or record.signal ~= signal then return nil end
    else
        return nil
    end
    return record
end

--- Launch and monitor a fresh helper instance through Launch Services.
--- Directly executing Contents/MacOS/lrphotosimporter would attribute Photos
--- access to Lightroom again, even though the executable lives in an app.
--- @param appPath string Absolute path to the helper app
--- @param arguments table Command arguments (escaped individually here)
--- @return number launchStatus Raw wait status of lrphotoslauncher, NOT the helper
--- @return string output The helper's stdout (XML)
--- @return string diagnostics The launcher's output and the helper's stderr
--- @return table|nil termination The helper's kernel exit status, or monitor failure
function M.executeAppWithOutput(appPath, arguments)
    local stdoutPath = os.tmpname()
    local stderrPath = os.tmpname()
    local launchPath = os.tmpname()
    local statusPath = os.tmpname()
    local command = M.escape(appPath .. '/Contents/MacOS/lrphotoslauncher')
        .. ' --app ' .. M.escape(appPath)
        .. ' --stdout ' .. M.escape(stdoutPath)
        .. ' --stderr ' .. M.escape(stderrPath)
        .. ' --status ' .. M.escape(statusPath) .. ' --'
    for _, argument in ipairs(arguments) do
        command = command .. ' ' .. M.escape(argument)
    end
    command = command .. ' > ' .. M.escape(launchPath) .. ' 2>&1'
    local launchStatus = LrTasks.execute(command)
    return launchStatus, readCapture(stdoutPath), readCapture(launchPath) .. readCapture(stderrPath),
        parseExitRecord(readCapture(statusPath))
end

return M

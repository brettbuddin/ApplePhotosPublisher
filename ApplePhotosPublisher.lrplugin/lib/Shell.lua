--[[
    Shell Utilities

    Shell command execution with output capture. Lightroom's LrTasks.execute()
    only returns an exit code. Launch Services does not inherit shell output
    redirections, so capture the app's stdout/stderr separately from open(1).
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

--- Launch a fresh helper instance through Launch Services and wait for it.
--- Directly executing Contents/MacOS/lrphotosimporter would attribute Photos
--- access to Lightroom again, even though the executable lives in an app.
--- @param appPath string Absolute path to the helper app
--- @param arguments table Command arguments (escaped individually here)
--- @return number launchStatus Raw wait status of open(1), NOT the helper
--- @return string output The helper's stdout (XML)
--- @return string diagnostics The launcher's output and the helper's stderr
function M.executeAppWithOutput(appPath, arguments)
    local stdoutPath = os.tmpname()
    local stderrPath = os.tmpname()
    local launchPath = os.tmpname()
    local command = '/usr/bin/open -n -W -a ' .. M.escape(appPath)
        .. ' --stdout ' .. M.escape(stdoutPath)
        .. ' --stderr ' .. M.escape(stderrPath) .. ' --args'
    for _, argument in ipairs(arguments) do
        command = command .. ' ' .. M.escape(argument)
    end
    command = command .. ' > ' .. M.escape(launchPath) .. ' 2>&1'
    local launchStatus = LrTasks.execute(command)
    return launchStatus, readCapture(stdoutPath), readCapture(launchPath) .. readCapture(stderrPath)
end

return M

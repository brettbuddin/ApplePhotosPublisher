--[[
    Shell Utilities

    Shell command execution with output capture. Lightroom's LrTasks.execute()
    only returns an exit code, so this module captures stdout/stderr via a
    temporary file.
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

--- Execute a shell command and capture its output.
--- @param command string The shell command to execute
--- @return number exitCode The command's exit code (0 = success)
--- @return string output Combined stdout and stderr from the command
function M.executeWithOutput(command)
    local tempFile = os.tmpname()
    local fullCommand = command .. ' > "' .. tempFile .. '" 2>&1'
    local exitCode = LrTasks.execute(fullCommand)

    local output = ""
    local file = io.open(tempFile, "r")
    if file then
        output = file:read("*a")
        file:close()
    end

    LrFileUtils.delete(tempFile)

    return exitCode, output
end

return M

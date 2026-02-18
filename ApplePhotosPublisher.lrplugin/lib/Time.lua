--[[
    Time Utilities

    Time-related helper functions.
]]

local M = {}

--- Get the current timestamp in ISO 8601 format (UTC)
--- @return string The timestamp string
function M.nowISO8601()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

return M

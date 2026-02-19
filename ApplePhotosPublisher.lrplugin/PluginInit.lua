--[[
    Plugin Initialization

    Sets up logging.
]]

local pluginLoad = require 'PluginModuleLoader'
local logger = pluginLoad 'lib/Logger'

local ok, buildInfo = pcall(require, 'BuildInfo')
if ok then
    logger:info('Build: ' .. buildInfo.version .. ' (' .. buildInfo.sha .. ')')
end

logger:info('Plugin initialized')

--[[
    Plugin Initialization

    Sets up logging.
]]

local pluginLoad = require 'PluginModuleLoader'
local logger = pluginLoad 'lib/Logger'

logger:info('Plugin initialized')

--[[
    Plugin Module Loader

    Provides dofile-like functionality for loading Lua modules from paths
    within the plugin directory. Lightroom's require() only looks in the
    plugin root, so this enables subdirectory organization.

    Usage:
        local pluginLoad = require 'PluginModuleLoader'
        local MyModule = pluginLoad 'lib/MyModule'
        local Utils = pluginLoad 'lib/Strings'
]]

local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'

local logger = LrLogger('ApplePhotosPublisher')
logger:enable('logfile')

local cache = {}

--- Load a Lua module from a path relative to the plugin directory.
--- Modules are cached after first load.
--- @param modulePath string Path to the module (without .lua extension)
--- @return any The module's return value
local function load(modulePath)
    -- Return cached module if already loaded
    if cache[modulePath] then
        logger:trace('PluginModuleLoader: cache hit for "' .. modulePath .. '"')
        return cache[modulePath]
    end

    -- Build full path: plugin directory + module path + .lua
    local fullPath = LrPathUtils.child(_PLUGIN.path, modulePath .. '.lua')

    logger:info('PluginModuleLoader: loading "' .. modulePath .. '" from ' .. fullPath)

    -- Load and compile the file
    local chunk, err = loadfile(fullPath)
    if not chunk then
        error('PluginModuleLoader: Failed to load "' .. modulePath .. '": ' .. (err or 'unknown error'))
    end

    -- Execute the chunk in protected mode and cache the result
    local ok, result = pcall(chunk)
    if not ok then
        error('PluginModuleLoader: Error executing "' .. modulePath .. '": ' .. (result or 'unknown error'))
    end
    cache[modulePath] = result

    return result
end

return load

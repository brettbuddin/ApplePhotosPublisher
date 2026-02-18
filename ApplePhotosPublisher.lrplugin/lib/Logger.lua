--[[
    Logger

    Shared logger instance for the plugin. All log output goes to:
      ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/ApplePhotosPublisher.log

    Usage:
        local logger = pluginLoad 'lib/Logger'
        logger:info('Message here')
        logger:error('Error details')
        logger:warn('Warning message')
        logger:trace('Debug info')  -- Only shown if trace is enabled
]]

local LrLogger = import 'LrLogger'

local logger = LrLogger('ApplePhotosPublisher')
logger:enable('logfile')

return logger

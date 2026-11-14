--[[
    Renderer

    Renders photos in a format the publish service does not render itself.

    A publish service has one set of output settings, and Lightroom renders every collection
    in it with those. `updateExportSettings` is the only place they can be changed, and
    nothing the SDK documents tells it which collection is being published, so a collection
    in another format cannot be rendered by the publish it belongs to.

    Its photos are rendered here instead, in an export session of the plugin's own. The
    publish is told to skip them first, so each photo is still rendered once, in the format
    it is wanted in, rather than once for the service and again for the collection.
]]

local LrDate = import 'LrDate'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local pluginLoad = require 'PluginModuleLoader'
local Formats = pluginLoad 'lib/Formats'

local M = {}

--- Where and how the files are written, which a publish otherwise decides for itself.
local DESTINATION_SETTINGS = {
    LR_export_destinationType = 'specificFolder',
    LR_export_useSubfolder = false,
    LR_reimportExportedPhoto = false,
    LR_export_postProcessing = 'doNothing',
    -- Two photos can share a file name, and the default is to stop and ask.
    LR_collisionHandling = 'rename',
    LR_renamingTokensOn = false,
    LR_extensionCase = 'lowercase',
    LR_includeVideoFiles = false,
}

--- Make a directory of our own for the rendered files, removed when the publish ends.
--- @param functionContext LrFunctionContext The publish's function context
--- @return string The directory's path
local function makeDirectory(functionContext)
    local tempDir = LrPathUtils.getStandardFilePath('temp')
    local directory = LrFileUtils.chooseUniqueFileName(
        LrPathUtils.child(tempDir, 'lrphotosimporter_render_' .. tostring(LrDate.currentTime())))
    LrFileUtils.createAllDirectories(directory)
    -- The helper copies each file into the library, so nothing needs them afterwards.
    functionContext:addCleanupHandler(function()
        LrFileUtils.delete(directory)
    end)
    return directory
end

--- Render photos in a format.
---
--- Every photo that started rendering gets an entry: the path it was written to, or the
--- reason it was not. A photo with no entry was never reached, which is what stopping early
--- leaves behind.
---
--- @param functionContext LrFunctionContext The publish's function context, for cleanup
--- @param photos table Array of LrPhoto
--- @param format string A format name
--- @param onRendered function|nil Called after each photo; return false to stop
--- @return table Map of photo localIdentifier to {path} or {message}
function M.render(functionContext, photos, format, onRendered)
    local results = {}
    if #photos == 0 then
        return results
    end

    local settings = Formats.exportSettings(format)
    for key, value in pairs(DESTINATION_SETTINGS) do
        settings[key] = value
    end
    settings.LR_export_destinationPathPrefix = makeDirectory(functionContext)

    local session = LrExportSession({
        photosToExport = photos,
        exportSettings = settings,
    })

    for _, rendition in session:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if success then
            results[rendition.photo.localIdentifier] = { path = pathOrMessage }
        else
            results[rendition.photo.localIdentifier] = { message = pathOrMessage }
        end
        if onRendered and onRendered() == false then
            break
        end
    end

    return results
end

return M

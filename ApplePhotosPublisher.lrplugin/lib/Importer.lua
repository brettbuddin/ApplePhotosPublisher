--[[
    Importer

    Wrapper for the lrphotosimporter binary. Provides functions to:
      - Import multiple photos in a batch
      - Delete photos from Apple Photos by identifier

    The binary outputs XML which is parsed and returned as Lua tables.
]]

local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrXml = import 'LrXml'

local pluginLoad = require 'PluginModuleLoader'
local Shell = pluginLoad 'lib/Shell'
local XML = pluginLoad 'lib/XML'

local logger = pluginLoad 'lib/Logger'

local M = {}

local STATUS_SUCCESS = 'success'
local STATUS_ERROR = 'error'

--- Fill in a parse-error fallback when the XML parser returned no status
--- @param result table The parsed result table (modified in place)
--- @param exitCode number The shell exit code
--- @param output string|nil The raw command output
local function fillParseError(result, exitCode, output)
    if result.status then return end
    result.status = STATUS_ERROR
    result.errorCode = 'PARSE_ERROR'
    result.errorMessage = 'Failed to parse importer response (exit code: ' .. tostring(exitCode) .. ')'
    if output and output ~= '' then
        result.errorMessage = result.errorMessage .. '\nOutput: ' .. output
    end
end

--- Get the path to the importer binary
--- @return string Path to the lrphotosimporter binary
local function getBinaryPath()
    local pluginPath = _PLUGIN.path
    local binDir = LrPathUtils.child(pluginPath, 'bin')
    return LrPathUtils.child(binDir, 'lrphotosimporter')
end

--- Build manifest XML for a batch of photos
--- @param photos table Array of {path, previousIdentifier} tables
--- @return string XML string
local function buildManifestXML(photos)
    local builder = LrXml.createXmlBuilder(false)
    builder:beginBlock('manifest')
    builder:beginBlock('photos')
    for _, photo in ipairs(photos) do
        builder:beginBlock('photo')
        builder:tag('path', photo.path)
        if photo.previousIdentifier and photo.previousIdentifier ~= '' then
            builder:tag('previousIdentifier', photo.previousIdentifier)
        end
        builder:endBlock()
    end
    builder:endBlock()
    builder:endBlock()
    return builder:serialize()
end

--- Write manifest XML to a temp file
--- @param xml string The manifest XML content
--- @return string|nil path The written file path, or nil on error
--- @return string|nil err Error message on failure
local function writeManifestFile(xml)
    local tempDir = LrPathUtils.getStandardFilePath('temp')
    local manifestName = 'lrphotosimporter_manifest_' .. tostring(LrDate.currentTime()) .. '.xml'
    local manifestPath = LrPathUtils.child(tempDir, manifestName)

    local ok, err = pcall(function()
        local file = io.open(manifestPath, 'w')
        if file then
            file:write(xml)
            file:close()
        else
            error('Could not open file for writing')
        end
    end)

    if not ok then
        return nil, tostring(err)
    end

    return manifestPath
end

--- Import multiple photos into Apple Photos in a single batch.
---
--- We use a manifest XML file to batch all imports into a single CLI invocation
--- rather than calling the importer binary once per photo. This works around a
--- problem in Lightroom's fork/exec machinery where repeated rapid CLI calls
--- cause panics. By encoding all import information (paths, previous identifiers)
--- into one XML manifest, we reduce the interaction to a single process launch.
---
--- The trade-off is that we lose granular progress feedback (the progress bar
--- can't update per-photo) in exchange for reliable imports.
---
--- @param photos table Array of {path, previousIdentifier} tables
--- @return table Result table with status, results keyed by path, or errorCode/errorMessage
function M.importPhotos(photos)
    if #photos == 0 then
        return {
            status = STATUS_SUCCESS,
            results = {},
        }
    end

    local manifestPath, writeErr = writeManifestFile(buildManifestXML(photos))
    if not manifestPath then
        return {
            status = STATUS_ERROR,
            errorCode = 'MANIFEST_WRITE_ERROR',
            errorMessage = 'Failed to write manifest file: ' .. writeErr,
        }
    end
    logger:info('Written manifest to: ' .. manifestPath)
    logger:info('Manifest contains ' .. #photos .. ' photos')

    local binary = getBinaryPath()
    local command = Shell.escape(binary) .. ' import --manifest ' .. Shell.escape(manifestPath)

    logger:info('Running batch import command: ' .. command)

    local exitCode, output = Shell.executeWithOutput(command)
    LrFileUtils.delete(manifestPath)
    if output and output ~= '' then
        logger:info('Batch import output:\n' .. output)
    end

    local result = XML.parseBatchImportResult(output or '')
    fillParseError(result, exitCode, output)
    return result
end

--- Delete photos from Apple Photos by identifier.
---
--- We batch all deletes into a single call because PhotoKit prompts the user
--- for confirmation each time a delete is requested. Batching ensures the user
--- sees one confirmation dialog for the entire set rather than one per photo.
---
--- @param identifiers table Array of Photos local identifiers to delete
--- @return table Result table with status, deletedCount/errorCode/errorMessage
function M.deletePhotos(identifiers)
    if #identifiers == 0 then
        return {
            status = STATUS_SUCCESS,
            deletedCount = 0,
        }
    end

    local binary = getBinaryPath()
    local command = Shell.escape(binary) .. ' delete'
    for _, id in ipairs(identifiers) do
        command = command .. ' ' .. Shell.escape(id)
    end
    logger:info('Running delete command: ' .. command)

    local exitCode, output = Shell.executeWithOutput(command)
    if output and output ~= '' then
        logger:info('Delete output:\n' .. output)
    end

    local result = XML.parseDeleteResult(output or '')
    fillParseError(result, exitCode, output)
    return result
end

--- Status value indicating a successful operation
M.STATUS_SUCCESS = STATUS_SUCCESS

--- Status value indicating a failed operation
M.STATUS_ERROR = STATUS_ERROR

return M

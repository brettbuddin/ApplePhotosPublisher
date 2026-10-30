--[[
    Importer

    Wrapper for the Apple Photos Publisher for Lightroom Classic helper app. Provides functions to:
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

--- Error codes the importer returns when it lacks access to the Photos
--- library. macOS only prompts for Photos access once, so these all need the
--- user to change the setting in System Settings and deserve a dialog rather
--- than a per-photo failure message.
local AUTHORIZATION_ERROR_CODES = {
    READ_AUTH_DENIED = true,
    WRITE_AUTH_DENIED = true,
    WRITE_AUTH_LIMITED = true,
    WRITE_AUTH_RESTRICTED = true,
}

--- Names for the signals a crashed importer is likely to die from.
local SIGNAL_NAMES = {
    [1] = 'SIGHUP',
    [2] = 'SIGINT',
    [3] = 'SIGQUIT',
    [4] = 'SIGILL',
    [5] = 'SIGTRAP',
    [6] = 'SIGABRT',
    [7] = 'SIGEMT',
    [8] = 'SIGFPE',
    [9] = 'SIGKILL',
    [10] = 'SIGBUS',
    [11] = 'SIGSEGV',
    [12] = 'SIGSYS',
    [13] = 'SIGPIPE',
    [14] = 'SIGALRM',
    [15] = 'SIGTERM',
}

--- Describe a signal number as "N (NAME)" when the name is known.
--- @param signal number The signal number
--- @return string
local function describeSignal(signal)
    local name = SIGNAL_NAMES[signal]
    if name then
        return tostring(signal) .. ' (' .. name .. ')'
    end
    return tostring(signal)
end

--- Describe the status returned by LrTasks.execute in human terms.
---
--- On macOS, LrTasks.execute returns the raw wait status from system(3)
--- rather than a plain exit code. The command runs under /bin/sh, so the
--- status normally encodes the shell's exit code in the high byte. When the
--- importer dies from a signal, the shell reports 128 + signal as its exit
--- code, so a crash shows up as a value such as 34304 (134 << 8, SIGABRT).
--- If the shell itself is killed, the signal number sits in the low byte.
---
--- @param status number The raw status from LrTasks.execute
--- @return string A description such as "exit code 1" or "killed by signal 6 (SIGABRT)"
local function describeExitStatus(status)
    if type(status) ~= 'number' then
        return 'status ' .. tostring(status)
    end

    local high = math.floor(status / 256)
    local low = status % 256
    local lowSignal = low % 128 -- bit 0x80 marks a core dump

    if lowSignal ~= 0 then
        return 'killed by signal ' .. describeSignal(lowSignal)
    end

    local exitCode = high
    if exitCode > 128 and exitCode < 160 then
        return 'exit code ' .. tostring(exitCode)
            .. ', killed by signal ' .. describeSignal(exitCode - 128)
    elseif exitCode == 126 then
        return 'exit code 126 (binary found but could not be executed)'
    elseif exitCode == 127 then
        return 'exit code 127 (binary not found)'
    end
    return 'exit code ' .. tostring(exitCode)
end

--- Distinguish launch failures from helpers that exit without valid XML.
--- @param result table The parsed result table (modified in place)
--- @param launchStatus number The raw status of open(1), not the helper's exit code
--- @param output string|nil The raw command output
--- @param diagnostics string The helper's stderr and launch errors
local function fillParseError(result, launchStatus, output, diagnostics)
    -- open -W can fail to attach its exit watcher if the app finishes quickly
    -- (kevent reports ESRCH). A complete XML result is the helper's outcome.
    if result.status then return end
    result.status = STATUS_ERROR
    if launchStatus ~= 0 then
        result.errorCode = 'LAUNCH_FAILED'
        result.errorMessage = 'Could not launch Apple Photos Publisher for Lightroom Classic ('
            .. describeExitStatus(launchStatus) .. ', raw status ' .. tostring(launchStatus) .. ')'
    else
        result.errorCode = 'PARSE_ERROR'
        result.errorMessage = 'Apple Photos Publisher for Lightroom Classic exited without a valid XML response. '
            .. 'The helper may have crashed; check ~/Library/Logs/DiagnosticReports/lrphotosimporter*.ips.'
    end
    if output and output ~= '' then
        result.errorMessage = result.errorMessage .. '\nOutput: ' .. output
    else
        result.errorMessage = result.errorMessage .. '\nThe importer produced no output.'
    end
    if diagnostics and diagnostics ~= '' then
        result.errorMessage = result.errorMessage .. '\nDiagnostics: ' .. diagnostics
    end
end

--- Get the helper app that owns the Photos permission.
--- @return string Path to the helper app
local function getAppPath()
    local pluginPath = _PLUGIN.path
    local binDir = LrPathUtils.child(pluginPath, 'bin')
    return LrPathUtils.child(binDir, 'Apple Photos Publisher for Lightroom Classic.app')
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

    local appPath = getAppPath()
    logger:info('Launching batch import via Launch Services: ' .. appPath)
    local launchStatus, output, diagnostics = Shell.executeAppWithOutput(appPath, { 'import', '--manifest', manifestPath })
    LrFileUtils.delete(manifestPath)
    if diagnostics and diagnostics ~= '' then
        logger:info('Batch import diagnostics:\n' .. diagnostics)
    end
    if output and output ~= '' then
        logger:info('Batch import output:\n' .. output)
    end

    local result = XML.parseBatchImportResult(output or '')
    fillParseError(result, launchStatus, output, diagnostics)
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

    local appPath = getAppPath()
    local arguments = { 'delete' }
    for _, id in ipairs(identifiers) do
        table.insert(arguments, id)
    end
    logger:info('Launching delete via Launch Services: ' .. appPath)

    local launchStatus, output, diagnostics = Shell.executeAppWithOutput(appPath, arguments)
    if diagnostics and diagnostics ~= '' then
        logger:info('Delete diagnostics:\n' .. diagnostics)
    end
    if output and output ~= '' then
        logger:info('Delete output:\n' .. output)
    end

    local result = XML.parseDeleteResult(output or '')
    fillParseError(result, launchStatus, output, diagnostics)
    return result
end

--- Whether a result describes a missing Photos library permission.
--- @param result table A result table from importPhotos or deletePhotos
--- @return boolean
function M.isAuthorizationError(result)
    return result.status == STATUS_ERROR
        and AUTHORIZATION_ERROR_CODES[result.errorCode or ''] == true
end

--- Status value indicating a successful operation
M.STATUS_SUCCESS = STATUS_SUCCESS

--- Status value indicating a failed operation
M.STATUS_ERROR = STATUS_ERROR

return M

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

--- Error code the helper returns when the user dismissed the macOS confirmation dialog.
--- Deleting an album or a folder always raises that dialog, so a refusal is an ordinary
--- outcome and has to be worded differently from a fault.
local USER_CANCELLED = 'USER_CANCELLED'

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
--- status normally encodes the shell's exit code in the high byte. This is
--- only the launcher's status; helper signals come from the monitor record.
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
    if exitCode == 126 then
        return 'exit code 126 (binary found but could not be executed)'
    elseif exitCode == 127 then
        return 'exit code 127 (binary not found)'
    end
    return 'exit code ' .. tostring(exitCode)
end

--- Require a known, successful process exit before accepting success XML.
--- @param result table The parsed result table (modified in place)
--- @param launchStatus number The raw status of the launcher, not the helper
--- @param output string|nil The raw command output
--- @param diagnostics string The helper's stderr and launch errors
--- @param termination table|nil The monitor's validated termination record
local function checkProcessResult(result, launchStatus, output, diagnostics, termination)
    local helper = 'Apple Photos Publisher for Lightroom Classic'
    if termination and termination.state == 'signaled' then
        result.errorCode = 'HELPER_CRASHED'
        result.errorMessage = helper .. ' was killed by signal ' .. describeSignal(termination.signal)
            .. ' (raw status ' .. tostring(termination.rawStatus) .. ').'
    elseif termination and termination.state == 'exited' and termination.exitCode ~= 0 then
        local detail = helper .. ' exited with code ' .. tostring(termination.exitCode)
            .. ' (raw status ' .. tostring(termination.rawStatus) .. ').'
        if result.status == STATUS_ERROR and result.errorMessage then
            result.errorMessage = result.errorMessage .. '\n' .. detail
        else
            result.errorCode = 'HELPER_EXIT_FAILED'
            result.errorMessage = detail
        end
    elseif termination and termination.state == 'exited' then
        if result.status then return end
        result.errorCode = 'PARSE_ERROR'
        result.errorMessage = helper .. ' exited with code 0 but did not return valid XML.'
    elseif termination and termination.state == 'startupFailed' then
        result.errorCode = 'LAUNCH_FAILED'
        result.errorMessage = helper .. ' failed before its startup handshake completed. '
            .. 'The helper\'s exit status is unavailable.'
    else
        result.errorCode = 'MONITOR_FAILED'
        result.errorMessage = 'Could not determine how ' .. helper .. ' terminated (launcher '
            .. describeExitStatus(launchStatus) .. '). The operation may have completed; check Photos before retrying.'
    end
    result.status = STATUS_ERROR
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

--- Write an identifier tag only when there is one, since an empty value would read as a
--- real identifier on the other side rather than "never published".
local function optionalTag(builder, name, value)
    if value and value ~= '' then
        builder:tag(name, value)
    end
end

--- Build manifest XML for a batch of photos
--- @param photos table Array of {path, previousIdentifier, reuseIdentifier} tables
--- @param album table|nil {identifier, name, folders} target album, outermost folder first
--- @return string XML string
local function buildManifestXML(photos, album)
    local builder = LrXml.createXmlBuilder(false)
    builder:beginBlock('manifest')
    if album then
        builder:beginBlock('album')
        optionalTag(builder, 'identifier', album.identifier)
        builder:tag('name', album.name)
        if album.folders and #album.folders > 0 then
            builder:beginBlock('folders')
            for _, folder in ipairs(album.folders) do
                builder:beginBlock('folder')
                optionalTag(builder, 'identifier', folder.identifier)
                builder:tag('name', folder.name)
                builder:endBlock()
            end
            builder:endBlock()
        end
        builder:endBlock()
    end
    builder:beginBlock('photos')
    for _, photo in ipairs(photos) do
        builder:beginBlock('photo')
        builder:tag('path', photo.path)
        optionalTag(builder, 'previousIdentifier', photo.previousIdentifier)
        optionalTag(builder, 'reuseIdentifier', photo.reuseIdentifier)
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
--- @param photos table Array of {path, previousIdentifier, reuseIdentifier} tables
--- @param album table|nil {identifier, name, folders} album to file the batch into
--- @return table Result table with status, results keyed by path, album, or errorCode/errorMessage
function M.importPhotos(photos, album)
    if #photos == 0 and not album then
        return {
            status = STATUS_SUCCESS,
            results = {},
        }
    end

    local manifestPath, writeErr = writeManifestFile(buildManifestXML(photos, album))
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
    local launchStatus, output, diagnostics, termination = Shell.executeAppWithOutput(
        appPath, { 'import', '--manifest', manifestPath })
    LrFileUtils.delete(manifestPath)
    if diagnostics and diagnostics ~= '' then
        logger:info('Batch import diagnostics:\n' .. diagnostics)
    end
    if output and output ~= '' then
        logger:info('Batch import output:\n' .. output)
    end

    local result = XML.parseBatchImportResult(output or '')
    checkProcessResult(result, launchStatus, output, diagnostics, termination)
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

    local launchStatus, output, diagnostics, termination = Shell.executeAppWithOutput(appPath, arguments)
    if diagnostics and diagnostics ~= '' then
        logger:info('Delete diagnostics:\n' .. diagnostics)
    end
    if output and output ~= '' then
        logger:info('Delete output:\n' .. output)
    end

    local result = XML.parseDeleteResult(output or '')
    checkProcessResult(result, launchStatus, output, diagnostics, termination)
    return result
end

--- Run a single album or folder operation through the helper.
---
--- Each of these comes from one action in the Publish Services panel, so a launch apiece is
--- acceptable. Batch work rides along in the import manifest instead, to stay inside the
--- single launch that publishing already costs.
---
--- @param label string Description used in the log
--- @param arguments table Command arguments
--- @return table Result table with status, identifier/created or errorCode/errorMessage
local function runCollectionCommand(label, arguments)
    local appPath = getAppPath()
    logger:info('Launching ' .. label .. ' via Launch Services: ' .. appPath)

    local launchStatus, output, diagnostics, termination = Shell.executeAppWithOutput(appPath, arguments)
    if diagnostics and diagnostics ~= '' then
        logger:info(label .. ' diagnostics:\n' .. diagnostics)
    end
    if output and output ~= '' then
        logger:info(label .. ' output:\n' .. output)
    end

    local result = XML.parseCollectionResult(output or '')
    checkProcessResult(result, launchStatus, output, diagnostics, termination)
    return result
end

--- Find or create the album for a published collection.
--- @param name string The collection's name, used as the album title
--- @param identifier string|nil Album identifier recorded by a previous publish
--- @param folderIdentifier string|nil Folder to create the album in
--- @return table Result table, with identifier and created on success
function M.ensureAlbum(name, identifier, folderIdentifier)
    local arguments = { 'album', 'ensure', '--name', name }
    if identifier and identifier ~= '' then
        table.insert(arguments, '--identifier')
        table.insert(arguments, identifier)
    end
    if folderIdentifier and folderIdentifier ~= '' then
        table.insert(arguments, '--folder')
        table.insert(arguments, folderIdentifier)
    end
    return runCollectionCommand('album ensure', arguments)
end

--- Rename an album.
function M.renameAlbum(identifier, name)
    return runCollectionCommand('album rename',
        { 'album', 'rename', '--identifier', identifier, '--name', name })
end

--- Delete an album, leaving its photos in the library.
--- Raises the macOS confirmation dialog; a refusal returns USER_CANCELLED.
function M.deleteAlbum(identifier)
    return runCollectionCommand('album delete', { 'album', 'delete', '--identifier', identifier })
end

--- Remove photos from an album without deleting them. Silent, no dialog.
function M.removeFromAlbum(identifier, assetIdentifiers)
    if #assetIdentifiers == 0 then
        return { status = STATUS_SUCCESS }
    end

    local arguments = { 'album', 'remove', '--identifier', identifier }
    for _, assetIdentifier in ipairs(assetIdentifiers) do
        table.insert(arguments, assetIdentifier)
    end
    return runCollectionCommand('album remove', arguments)
end

--- Set an album's photos to exactly the given set.
--- The repair path for an album that was edited in Photos, and the backfill for one created
--- for a collection whose photos were published before album sync existed.
function M.syncAlbum(identifier, assetIdentifiers)
    local arguments = { 'album', 'sync', '--identifier', identifier }
    for _, assetIdentifier in ipairs(assetIdentifiers) do
        table.insert(arguments, assetIdentifier)
    end
    return runCollectionCommand('album sync', arguments)
end

--- Find or create the folder for a published collection set.
function M.ensureFolder(name, identifier, parentIdentifier)
    local arguments = { 'folder', 'ensure', '--name', name }
    if identifier and identifier ~= '' then
        table.insert(arguments, '--identifier')
        table.insert(arguments, identifier)
    end
    if parentIdentifier and parentIdentifier ~= '' then
        table.insert(arguments, '--parent')
        table.insert(arguments, parentIdentifier)
    end
    return runCollectionCommand('folder ensure', arguments)
end

--- Rename a folder.
function M.renameFolder(identifier, name)
    return runCollectionCommand('folder rename',
        { 'folder', 'rename', '--identifier', identifier, '--name', name })
end

--- Delete a folder and every collection inside it, leaving all their photos.
--- Raises the macOS confirmation dialog; a refusal returns USER_CANCELLED.
function M.deleteFolder(identifier)
    return runCollectionCommand('folder delete', { 'folder', 'delete', '--identifier', identifier })
end

--- Move an album or folder to a new parent, or to the top level when folderIdentifier is nil.
function M.moveCollection(identifier, folderIdentifier)
    local arguments = { 'folder', 'move', '--identifier', identifier }
    if folderIdentifier and folderIdentifier ~= '' then
        table.insert(arguments, '--folder')
        table.insert(arguments, folderIdentifier)
    end
    return runCollectionCommand('collection move', arguments)
end

--- Whether a result describes a missing Photos library permission.
--- @param result table A result table from importPhotos or deletePhotos
--- @return boolean
function M.isAuthorizationError(result)
    return result.status == STATUS_ERROR
        and AUTHORIZATION_ERROR_CODES[result.errorCode or ''] == true
end

--- Whether a result describes the user dismissing the confirmation dialog.
--- @param result table A result table from any helper command
--- @return boolean
function M.isUserCancelled(result)
    return result.status == STATUS_ERROR and result.errorCode == USER_CANCELLED
end

--- Status value indicating a successful operation
M.STATUS_SUCCESS = STATUS_SUCCESS

--- Status value indicating a failed operation
M.STATUS_ERROR = STATUS_ERROR

return M

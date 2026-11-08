-- Run from the repository root. No Lightroom or Photos access is required.
local modules = {}
local unpackValues = table.unpack or unpack
local execute
local deleted = {}
function import(name) return assert(modules[name], name) end
modules.LrFileUtils = { delete = function(path)
    deleted[path] = true
    os.remove(path)
end }
modules.LrTasks = { execute = function(command) return execute(command) end }
modules.LrPathUtils = { child = function(parent, child) return parent .. '/' .. child end }
modules.LrDate = { currentTime = function() return 1 end }
modules.LrPathUtils.getStandardFilePath = function() return '/tmp' end
-- Minimal stand-in for LrXml's builder, enough to inspect the manifest we produce.
modules.LrXml = { createXmlBuilder = function()
    local parts, stack, builder = {}, {}, {}
    function builder:beginBlock(name)
        table.insert(stack, name)
        table.insert(parts, '<' .. name .. '>')
    end
    function builder:endBlock()
        table.insert(parts, '</' .. table.remove(stack) .. '>')
    end
    function builder:tag(name, value)
        table.insert(parts, '<' .. name .. '>' .. tostring(value) .. '</' .. name .. '>')
    end
    function builder:serialize() return table.concat(parts) end
    return builder
end }
local Shell = dofile('ApplePhotosPublisher.lrplugin/lib/Shell.lua')
local function write(path, content)
    local file = assert(io.open(path, 'w'))
    file:write(content)
    file:close()
end

-- The monitor's kernel status, helper XML, and diagnostics use separate files.
execute = function(command)
    assert(command:find(Shell.escape("/tmp/Publisher's helper.app/Contents/MacOS/lrphotoslauncher"), 1, true) == 1)
    assert(command:find(Shell.escape("/tmp/Publisher's helper.app"), 1, true))
    assert(command:find(Shell.escape("/tmp/a 'quote' $(touch never-run).xml"), 1, true))
    local stdout = assert(command:match("%-%-stdout '([^']+)'"))
    local stderr = assert(command:match("%-%-stderr '([^']+)'"))
    local launcher = assert(command:match(" > '([^']+)' 2>&1$"))
    local statusFile = assert(command:match("%-%-status '([^']+)'"))
    assert(stdout ~= stderr and stdout ~= launcher and stderr ~= launcher)
    write(stdout, '<result/>')
    write(stderr, 'helper warning')
    write(launcher, 'launcher message\n')
    write(statusFile, 'version=1\nstate=exited\npid=42\nrawStatus=0\nexitCode=0\n')
    return 0
end
local status, output, diagnostics, termination = Shell.executeAppWithOutput(
    "/tmp/Publisher's helper.app", { 'import', '--manifest', "/tmp/a 'quote' $(touch never-run).xml" })
assert(status == 0 and output == '<result/>')
assert(diagnostics == 'launcher message\nhelper warning')
assert(termination.state == 'exited' and termination.exitCode == 0)
local deletedCount = 0
for path in pairs(deleted) do
    assert(io.open(path, 'r') == nil)
    deletedCount = deletedCount + 1
end
assert(deletedCount == 4)
print('PASS: monitor arguments, separate output/status capture, and cleanup')

execute = function(command)
    local statusFile = assert(command:match("%-%-status '([^']+)'"))
    write(statusFile, 'version=1\nstate=exited\npid=42\nrawStatus=6\nexitCode=0\n')
    return 0
end
local _, _, _, invalid = Shell.executeAppWithOutput('/app', {})
assert(invalid == nil)

-- Test importer error classification without involving PhotoKit.
local normalExit = { state = 'exited', exitCode = 0, rawStatus = 0 }
local response = { 0, '<success/>', 'warning', normalExit }
local receivedOutput
local lastArgs, lastManifest
local stubs = {
    ['lib/Shell'] = { executeAppWithOutput = function(app, args)
        assert(app == '/plugin/bin/Apple Photos Publisher for Lightroom Classic.app')
        lastArgs = args
        -- Read the manifest while it still exists; the importer deletes it on return.
        lastManifest = nil
        for index, value in ipairs(args) do
            if value == '--manifest' and args[index + 1] then
                local file = io.open(args[index + 1], 'r')
                if file then
                    lastManifest = file:read('*a')
                    file:close()
                end
            end
        end
        return unpackValues(response)
    end },
    ['lib/XML'] = { parseDeleteResult = function(xml)
        receivedOutput = xml
        return xml == '<success/>' and { status = 'success', deletedCount = 1 } or {}
    end, parseBatchImportResult = function(xml)
        return xml == '<success/>' and { status = 'success', results = {} } or {}
    end, parseCollectionResult = function(xml)
        return xml == '<success/>' and { status = 'success', identifier = 'alb-1' } or {}
    end },
    ['lib/Logger'] = { info = function() end, error = function() end },
}
package.loaded.PluginModuleLoader = function(name) return assert(stubs[name], name) end
_PLUGIN = { path = '/plugin' }
local Importer = dofile('ApplePhotosPublisher.lrplugin/lib/Importer.lua')
assert(Importer.deletePhotos({ "photo'id" }).status == 'success')
assert(receivedOutput == '<success/>')
assert(lastArgs[1] == 'delete' and lastArgs[2] == "photo'id")
response = { 256, '', 'app not found', { state = 'startupFailed' } }
local result = Importer.deletePhotos({ "photo'id" })
assert(result.errorCode == 'LAUNCH_FAILED')
assert(result.errorMessage:find('app not found', 1, true))
response = { 0, '', '', normalExit }
result = Importer.deletePhotos({ "photo'id" })
assert(result.errorCode == 'PARSE_ERROR')
assert(result.errorMessage:find('exited with code 0', 1, true))
response = { 0, '<success/>', '', { state = 'signaled', signal = 6, rawStatus = 6 } }
result = Importer.deletePhotos({ "photo'id" })
assert(result.status == 'error' and result.errorCode == 'HELPER_CRASHED')
assert(result.errorMessage:find('6 (SIGABRT)', 1, true))
response = { 0, '<success/>', '', { state = 'exited', exitCode = 134, rawStatus = 34304 } }
result = Importer.deletePhotos({ "photo'id" })
assert(result.errorCode == 'HELPER_EXIT_FAILED')
assert(result.errorMessage:find('code 134', 1, true) and not result.errorMessage:find('SIGABRT', 1, true))
response = { 0, '<success/>', '' }
result = Importer.deletePhotos({ "photo'id" })
assert(result.status == 'error' and result.errorCode == 'MONITOR_FAILED')
print('PASS: confirmed success, startup failure, missing XML/status, signal vs exit code, crash after success XML')

-- The album rides along in the manifest, so creating the album, importing and setting
-- membership all happen in the one launch publishing already costs.
response = { 0, '<success/>', '', normalExit }
assert(Importer.importPhotos({
    { path = '/tmp/a.jpg', previousIdentifier = 'prev-1' },
    { path = '/tmp/b.jpg', reuseIdentifier = 'live-1' },
}, {
    identifier = 'alb-1',
    name = 'Family 2026',
}).status == 'success')
assert(lastManifest, 'manifest should have been written')
assert(lastManifest:find('<album><identifier>alb-1</identifier><name>Family 2026</name></album>', 1, true))
assert(lastManifest:find('<previousIdentifier>prev-1</previousIdentifier>', 1, true))
assert(lastManifest:find('<reuseIdentifier>live-1</reuseIdentifier>', 1, true))

-- An absent identifier must stay absent: an empty tag would read as a real identifier on
-- the other side rather than "never published".
Importer.importPhotos({ { path = '/tmp/a.jpg' } }, { name = 'Trip' })
assert(not lastManifest:find('<identifier>', 1, true))
assert(not lastManifest:find('previousIdentifier', 1, true))

-- Publishing without an album leaves the block out entirely.
Importer.importPhotos({ { path = '/tmp/a.jpg' } }, nil)
assert(not lastManifest:find('<album>', 1, true))
print('PASS: manifest album block, reuse and omitted identifiers')

-- Collection commands build their own argument lists.
assert(Importer.ensureAlbum('Family', 'alb-1').identifier == 'alb-1')
assert(table.concat(lastArgs, ' ') == 'album ensure --name Family --identifier alb-1')
Importer.ensureAlbum('Family')
assert(table.concat(lastArgs, ' ') == 'album ensure --name Family')
Importer.renameAlbum('alb-1', 'New Name')
assert(table.concat(lastArgs, ' ') == 'album rename --identifier alb-1 --name New Name')
Importer.deleteAlbum('alb-1')
assert(table.concat(lastArgs, ' ') == 'album delete --identifier alb-1')
Importer.removeFromAlbum('alb-1', { 'a', 'b' })
assert(table.concat(lastArgs, ' ') == 'album remove --identifier alb-1 a b')
Importer.syncAlbum('alb-1', { 'a' })
assert(table.concat(lastArgs, ' ') == 'album sync --identifier alb-1 a')

-- Removing nothing should not launch the helper at all.
lastArgs = nil
assert(Importer.removeFromAlbum('alb-1', {}).status == 'success')
assert(lastArgs == nil)

-- A refused confirmation dialog has to stay distinguishable from a fault, because the
-- plugin words the two differently.
assert(Importer.isUserCancelled({ status = 'error', errorCode = 'USER_CANCELLED' }))
assert(not Importer.isUserCancelled({ status = 'error', errorCode = 'DELETE_FAILED' }))
assert(not Importer.isUserCancelled({ status = 'success' }))
assert(not Importer.isAuthorizationError({ status = 'error', errorCode = 'USER_CANCELLED' }))
print('PASS: album command arguments, empty removal, cancellation classification')

if arg[1] == '--integration' then
    -- Execute the real launch path with non-mutating commands only. Test a
    -- manifest filename containing shell metacharacters and repeated instances.
    execute = function(command)
        local ok, why, code = os.execute(command)
        if type(ok) == 'number' then return ok end -- Lua 5.1
        return why == 'exit' and code * 256 or code
    end
    local cwd = assert(io.popen('pwd'))
    local root = cwd:read('*l')
    cwd:close()
    local app = root .. '/tmp/build/ApplePhotosPublisher.lrplugin/bin/Apple Photos Publisher for Lightroom Classic.app'
    local basePath = os.tmpname()
    os.remove(basePath)
    local manifest = basePath .. " 'quoted' $.xml"
    write(manifest, '<manifest><photos/></manifest>')
    for _ = 1, 2 do
        local launch, xml, errors, outcome = Shell.executeAppWithOutput(app, { 'import', '--manifest', manifest })
        assert(xml:find('<status>success</status>', 1, true), xml .. errors)
        assert(launch == 0 and outcome.state == 'exited' and outcome.exitCode == 0, errors)
    end
    os.remove(manifest)
    local launch, xml, errors, outcome = Shell.executeAppWithOutput(app, { '--not-a-real-option' })
    assert(xml == '' and errors:find('Unknown option', 1, true), xml .. errors)
    assert(launch == 0 and outcome.state == 'exited' and outcome.exitCode == 64, errors)
    print('PASS: real monitored helper, quoted manifest, repeated success, parser exit code 64')
end

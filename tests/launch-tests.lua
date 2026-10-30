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
modules.LrXml = {}
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
local stubs = {
    ['lib/Shell'] = { executeAppWithOutput = function(app, args)
        assert(app == '/plugin/bin/Apple Photos Publisher for Lightroom Classic.app')
        assert(args[1] == 'delete' and args[2] == "photo'id")
        return unpackValues(response)
    end },
    ['lib/XML'] = { parseDeleteResult = function(xml)
        receivedOutput = xml
        return xml == '<success/>' and { status = 'success', deletedCount = 1 } or {}
    end },
    ['lib/Logger'] = { info = function() end },
}
package.loaded.PluginModuleLoader = function(name) return assert(stubs[name], name) end
_PLUGIN = { path = '/plugin' }
local Importer = dofile('ApplePhotosPublisher.lrplugin/lib/Importer.lua')
assert(Importer.deletePhotos({ "photo'id" }).status == 'success')
assert(receivedOutput == '<success/>')
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

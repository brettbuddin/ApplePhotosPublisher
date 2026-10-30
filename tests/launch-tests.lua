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

-- Model Launch Services writing to its own streams, independently of open's
-- shell redirection. Warnings must not corrupt XML or leave capture files.
execute = function(command)
    assert(command:find('/usr/bin/open -n -W -a ', 1, true) == 1)
    assert(command:find(Shell.escape("/tmp/Publisher's helper.app"), 1, true))
    assert(command:find(Shell.escape("/tmp/a 'quote' $(touch never-run).xml"), 1, true))
    local stdout = assert(command:match("%-%-stdout '([^']+)'"))
    local stderr = assert(command:match("%-%-stderr '([^']+)'"))
    local launcher = assert(command:match(" > '([^']+)' 2>&1$"))
    assert(stdout ~= stderr and stdout ~= launcher and stderr ~= launcher)
    write(stdout, '<result/>')
    write(stderr, 'helper warning')
    write(launcher, 'launcher message\n')
    return 0
end
local status, output, diagnostics = Shell.executeAppWithOutput(
    "/tmp/Publisher's helper.app", { 'import', '--manifest', "/tmp/a 'quote' $(touch never-run).xml" })
assert(status == 0 and output == '<result/>')
assert(diagnostics == 'launcher message\nhelper warning')
local deletedCount = 0
for path in pairs(deleted) do
    assert(io.open(path, 'r') == nil)
    deletedCount = deletedCount + 1
end
assert(deletedCount == 3)
print('PASS: Launch Services arguments, separate output capture, and cleanup')

-- Test importer error classification without involving PhotoKit.
local response = { 0, '<success/>', 'warning' }
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
response = { 256, '<success/>', 'Unable to block on applications (initial call to kevent() failed: No such process)' }
assert(Importer.deletePhotos({ "photo'id" }).status == 'success')
response = { 256, '', 'app not found' }
local result = Importer.deletePhotos({ "photo'id" })
assert(result.errorCode == 'LAUNCH_FAILED')
assert(result.errorMessage:find('app not found', 1, true))
response = { 0, '', '' }
result = Importer.deletePhotos({ "photo'id" })
assert(result.errorCode == 'PARSE_ERROR')
assert(result.errorMessage:find('may have crashed', 1, true))
assert(not result.errorMessage:find('exit code 0', 1, true))
print('PASS: XML success with stderr, failed launch, and helper exit without XML')

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
        local _, xml, errors = Shell.executeAppWithOutput(app, { 'import', '--manifest', manifest })
        assert(xml:find('<status>success</status>', 1, true), xml .. errors)
    end
    os.remove(manifest)
    local _, xml, errors = Shell.executeAppWithOutput(app, { '--not-a-real-option' })
    -- Launch Services can also report a launch failure if the app exits early.
    -- In either case, capture the argument parser's actual error on stderr.
    assert(xml == '' and errors:find('Unknown option', 1, true), xml .. errors)
    print('PASS: real helper launches, quoted manifest path, repeated XML responses, and stderr on parser failure')
end

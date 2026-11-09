--[[
    Reconcile Albums

    Sets each album's photos to exactly what its published collection holds.

    Lightroom only reports what changed, so two kinds of drift are invisible to publishing
    and need repairing out of band:

      - An album created for a collection whose photos were published before album sync
        existed starts empty, and Lightroom will never mention those photos again because
        nothing about them changed.
      - An album edited in Photos no longer matches its collection.

    Reconciles whatever published collections are selected in the Publish Services panel, or
    every collection in the service when none are.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'

local pluginLoad = require 'PluginModuleLoader'
local Albums = pluginLoad 'lib/Albums'
local Importer = pluginLoad 'lib/Importer'
local logger = pluginLoad 'lib/Logger'

--- Every collection this plugin publishes, across all of its services.
local function allServiceCollections(catalog)
    local collections = {}
    for _, service in ipairs(catalog:getPublishServices(_PLUGIN.id)) do
        for _, collection in ipairs(Albums.allCollections(service)) do
            table.insert(collections, collection)
        end
    end
    return collections
end

--- The published collections the user is looking at, if any belong to this plugin.
local function selectedCollections(catalog)
    local collections = {}
    for _, source in ipairs(catalog:getActiveSources()) do
        -- Sources can be strings for the special "all photographs" style views.
        if type(source) == 'table' and source.type then
            local kind = source:type()
            if kind == 'LrPublishedCollection' then
                table.insert(collections, source)
            elseif kind == 'LrPublishedCollectionSet' then
                for _, child in ipairs(Albums.allCollections(source)) do
                    table.insert(collections, child)
                end
            end
        end
    end
    return collections
end

--- "1 album" rather than "1 album(s)", since this ends up in front of the user.
--- @param n number
--- @param singular string
--- @param plural string
--- @return string
local function counted(n, singular, plural)
    return n .. ' ' .. (n == 1 and singular or plural)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('reconcileAlbums', function()
        local catalog = LrApplication.activeCatalog()

        local collections = selectedCollections(catalog)
        local scope = 'the selected albums'
        if #collections == 0 then
            collections = allServiceCollections(catalog)
            scope = 'every album'
        end

        if #collections == 0 then
            LrDialogs.message('Nothing to reconcile',
                'Set up the Apple Photos publish service and publish an album first.', 'info')
            return
        end

        logger:info('Reconciling ' .. #collections .. ' collections (' .. scope .. ')')

        local failures = {}
        local reconciled, skipped, repointed, deleted = 0, 0, 0, 0
        for _, collection in ipairs(collections) do
            local result = Albums.reconcile(collection)
            if result.status == Importer.STATUS_SUCCESS then
                if result.skipped then
                    -- The default collection has no album, so it is not one of the albums
                    -- this claims to have updated.
                    skipped = skipped + 1
                else
                    reconciled = reconciled + 1
                    repointed = repointed + (result.repointed or 0)
                    deleted = deleted + (result.deleted or 0)
                end
            else
                local message = result.errorMessage or result.errorCode or 'Unknown error'
                table.insert(failures, collection:getName() .. ': ' .. message)
                logger:error('Reconcile failed for ' .. collection:getName() .. ': ' .. message)
                if Importer.isAuthorizationError(result) then
                    -- Access is missing for all of them, so stop rather than repeat the
                    -- same failure once per collection.
                    break
                end
            end
        end

        if reconciled == 0 and skipped > 0 and #failures == 0 then
            LrDialogs.message('Nothing to reconcile',
                'The Apple Photos collection has no album of its own, so there is nothing to '
                .. 'bring back in line. Select an album you added instead.', 'info')
            return
        end

        local summary = 'Updated ' .. counted(reconciled, 'album', 'albums')
            .. ' in Apple Photos to match Lightroom.'
        if repointed > 0 then
            summary = summary .. '\n\nRe-linked ' .. counted(repointed, 'photo', 'photos')
                .. ' that named an older copy.'
        end
        if deleted > 0 then
            summary = summary .. '\n\nDeleted ' .. counted(deleted, 'copy', 'copies')
                .. ' nothing publishes any more.'
        end

        if #failures == 0 then
            LrDialogs.message('Albums reconciled', summary, 'info')
        else
            LrDialogs.message('Some albums could not be reconciled',
                summary .. '\n\n' .. table.concat(failures, '\n'), 'warning')
        end
    end)
end)

--[[
    Photos Publish Service Provider

    Publish service provider for Apple Photos. Appears in Lightroom's
    Publish Services panel with change tracking and republish support.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrErrors = import 'LrErrors'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local pluginLoad = require 'PluginModuleLoader'
local Albums = pluginLoad 'lib/Albums'
local Assets = pluginLoad 'lib/Assets'
local Formats = pluginLoad 'lib/Formats'
local Importer = pluginLoad 'lib/Importer'
local Renderer = pluginLoad 'lib/Renderer'
local Shell = pluginLoad 'lib/Shell'
local logger = pluginLoad 'lib/Logger'

--- Title of the dialog shown when Photos library access is missing.
local AUTHORIZATION_DIALOG_TITLE = 'Apple Photos Publisher for Lightroom Classic needs Full Access to Photos'

--- Tell the user that Photos library access is missing and how to fix it.
--- The importer's message names the current setting (Limited Access, no
--- access, or restricted) and the System Settings path to change it.
--- @param result table An error result from the importer
local function showAuthorizationError(result)
    LrDialogs.message(AUTHORIZATION_DIALOG_TITLE, result.errorMessage, 'critical')
end

--- Fail a collection lifecycle callback so Lightroom offers to revert the change.
---
--- The SDK responds to an error here by asking whether to undo the local change or keep it
--- while warning that the service was not updated. That is the right question for both a
--- genuine failure and a refused confirmation dialog, so the difference is only in the
--- wording, which the helper already supplies.
---
--- @param result table A result table from the helper
--- @param what string What could not be done, for the fallback message
local function failCollectionOperation(result, what)
    if Importer.isAuthorizationError(result) then
        showAuthorizationError(result)
    end
    local message = result.errorMessage or result.errorCode or ('Could not ' .. what)
    if Importer.isUserCancelled(result) then
        logger:info('User cancelled: ' .. what)
    else
        logger:error('Failed to ' .. what .. ': ' .. message)
    end
    error(message, 0)
end

--- Require a successful helper result, or fail the callback.
local function requireSuccess(result, what)
    if result.status ~= Importer.STATUS_SUCCESS then
        failCollectionOperation(result, what)
    end
end

--- Run catalog bookkeeping that must not take the publish down with it.
---
--- Letting any of this abort costs far more than getting it wrong: the run would stop before
--- deleting the assets it has just replaced, leaving duplicates in Photos with nothing left
--- to remember them by.
---
--- LrTasks.pcall rather than Lua's own, because the write gates inside yield and yielding
--- across a plain pcall is not allowed.
---
--- @param what string What was being written, for the log
--- @param fn function The function to call
--- @return any Whatever fn returned, or nil when it failed
local function tryBookkeeping(what, fn, ...)
    local ok, value = LrTasks.pcall(fn, ...)
    if not ok then
        logger:error('Could not ' .. what .. ': ' .. tostring(value))
        return nil
    end
    return value
end

--- A list of identifiers that keeps its order and refuses duplicates.
---
--- Several of a photo's identifiers can be the same one, and the helper is handed a list
--- rather than a set, so the dedupe has to happen here.
local function newIdentifierList()
    return { order = {}, seen = {} }
end

--- Add an identifier to a list, ignoring blanks and repeats.
local function addIdentifier(list, value)
    if value and value ~= '' and not list.seen[value] then
        list.seen[value] = true
        table.insert(list.order, value)
    end
end

--- Lightroom publish/export service provider table.
--- @class PhotosServiceProvider
local provider = {}

--- Render to a temporary location; Lightroom manages cleanup.
provider.canExportToTemporaryLocation = true
--- Only incremental (change-tracked) publishing is supported.
provider.supportsIncrementalPublish = 'only'
--- Hide every export dialog section. Location, naming and post-processing are
--- irrelevant, and the rest are fixed by the format, so showing them would offer
--- choices that never take effect.
provider.hideSections = {
    'exportLocation',
    'fileNaming',
    'fileSettings',
    'imageSettings',
    'outputSharpening',
    'metadata',
    'watermarking',
    'postProcessing',
}
--- The service itself only ever renders JPEG. A collection in another format has its
--- photos rendered separately; Renderer.lua has the reason.
provider.allowFileFormats = { Formats.DEFAULT }

--- Called at the start of every export and publish, before rendering.
--- Applies the default format's settings over whatever the service has saved.
--- @param exportSettings table Lightroom export settings for this session
function provider.updateExportSettings(exportSettings)
    for key, value in pairs(Formats.exportSettings(Formats.DEFAULT)) do
        exportSettings[key] = value
    end
end

--- Returns UI sections displayed at the top of the publish/export dialog.
--- Shows a single "Apple Photos" section with a description of the service.
--- @param f table Lightroom view factory
--- @param propertyTable table Lightroom export property table
--- @return table Array of dialog section descriptors
function provider.sectionsForTopOfDialog(f, propertyTable)
    return {
        {
            title = 'Apple Photos',
            f:row {
                f:static_text {
                    title = 'Photos will be published to Apple Photos.\n\nCollections you add become albums. The built-in Apple Photos collection files nothing: it just gets photos into your library. Previously published photos will be replaced and their album memberships restored.\n\nEach album publishes as JPEG unless it is given another format. Albums in the same format share one copy of a photo.',
                    fill_horizontal = 1,
                },
            },
        },
    }
end

--- Configures collection behavior for the publish service.
--- Creates a non-deletable default collection named "Apple Photos". Users can add
--- collections, which mirror to albums in Photos.
--- @param publishSettings table Current publish settings
--- @return table Collection behavior configuration
function provider.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = 'Apple Photos',
        defaultCollectionCanBeDeleted = false,
        canAddCollection = true,
        -- Collection sets are not offered. They would mirror to Photos folders, and
        -- deleting a folder in Photos is recursive: it takes every album inside with it,
        -- including one the user had dragged in that belongs to a collection still being
        -- published. Albums all sit at the top level instead.
        maxCollectionSetDepth = 0,
    }
end

--- Photos calls these albums, so the panel's menus should too.
provider.titleForPublishedCollection = 'Album'
provider.titleForPublishedCollection_standalone = 'Album'
provider.titleForPublishedSmartCollection = 'Smart Album'
provider.titleForPublishedSmartCollection_standalone = 'Smart Album'
provider.titleForGoToPublishedCollection = 'Show in Photos'

--- Adds the format choice to the dialog for creating or editing a collection.
--- @param f table Lightroom view factory
--- @param publishSettings table Current publish settings
--- @param info table Dialog info, including the collectionSettings being edited
--- @return table A view description
function provider.viewForCollectionSettings(f, publishSettings, info)
    local settings = info.collectionSettings
    -- A collection made before formats existed has no setting, and the menu needs a value
    -- to show.
    settings[Formats.SETTING] = Formats.resolve(settings[Formats.SETTING])

    return f:group_box {
        title = 'Apple Photos',
        size = 'small',
        fill_horizontal = 1,
        bind_to_object = settings,

        f:column {
            fill_horizontal = 1,
            spacing = f:control_spacing(),

            f:row {
                f:static_text {
                    title = 'Format:',
                },
                f:popup_menu {
                    value = LrView.bind(Formats.SETTING),
                    items = Formats.menuItems(),
                },
            },
            f:static_text {
                title = 'JPEG and JPEG XL are full quality. TIFF is 16-bit with ZIP compression. JPEG XL needs macOS 14 or later.\n\nA photo is rendered once for each format it is published in, however many albums that is. Changing the format marks the photos already here to be published again.',
                width_in_chars = 48,
                height_in_lines = 6,
            },
        },
    }
end

--- Called when the settings from `viewForCollectionSettings` are saved, or a change to them
--- is undone.
---
--- Nothing in Photos changes here. The photos published in the format the collection had are
--- flagged, and the next publish moves them across: it reuses the asset another collection
--- already has in the new format or renders one, then lets go of the old.
---
--- @param publishSettings table Current publish settings
--- @param info table Lifecycle info, including collectionSettings and publishedCollection
function provider.updateCollectionSettings(publishSettings, info)
    local collection = info.publishedCollection
    if not collection then
        return
    end
    local format = Formats.resolve(info.collectionSettings and info.collectionSettings[Formats.SETTING])

    -- A task of its own, so that waiting for the catalog cannot hold Lightroom up while it
    -- finishes saving the settings that brought us here.
    LrTasks.startAsyncTask(function()
        local flagged = tryBookkeeping('mark the photos to republish',
            Albums.flagForFormat, collection, format)
        if flagged and flagged > 0 then
            logger:info('Marked ' .. flagged .. ' photos in ' .. tostring(info.name)
                .. ' to republish as ' .. format)
        end
    end)
end

--- Declares which metadata changes should mark a photo for republish.
--- Triggers on: title, caption, keywords, GPS, date created, rating.
--- All other metadata fields are ignored.
--- @param publishSettings table Current publish settings
--- @return table Map of metadata field names to boolean
function provider.metadataThatTriggersRepublish(publishSettings)
    return {
        default = false,
        title = true,
        caption = true,
        keywords = true,
        gps = true,
        dateCreated = true,
        rating = true,
    }
end

--- Batch-imports rendered photos into Apple Photos.
---
--- The batch carries its album, so the helper creates the album, imports the photos and
--- sets their membership within the single launch publishing already costs.
---
--- Nothing is written to the catalog here. Every photo's outcome is collected instead and
--- applied afterwards in one transaction each, which keeps a large republish to a single
--- undo entry rather than one per photo.
---
--- @param progressScope LrProgressScope Active progress scope for cancellation and status
--- @param renditionPhotos table Array of {rendition, photo, path, previousIdentifier, reuseIdentifier}
--- @param context table {album, localCollectionId, index, format}
--- @return table Outcome with updates, repoints, superseded, evictions, dropped, forget and reused
--- @return table|nil The album the helper resolved, as {identifier, created}
local function importPhotoBatch(progressScope, renditionPhotos, context)
    local batchPhotos = {}
    for _, rp in ipairs(renditionPhotos) do
        table.insert(batchPhotos, {
            path = rp.path,
            previousIdentifier = rp.previousIdentifier,
            reuseIdentifier = rp.reuseIdentifier,
        })
    end

    local outcome = {
        updates = {},
        repoints = {},
        superseded = {},
        evictions = {},
        dropped = {},
        forget = {},
        reused = 0,
        published = 0,
    }

    if progressScope:isCanceled() then
        return outcome, nil
    end

    progressScope:setCaption('Importing to Apple Photos...')
    logger:info('Starting batch import of ' .. #batchPhotos .. ' photos')
    local batchResult = Importer.importPhotos(batchPhotos, context.album)

    if batchResult.status == Importer.STATUS_SUCCESS then
        for _, rp in ipairs(renditionPhotos) do
            local result = batchResult.results[rp.path]

            if result and result.status == 'success' then
                rp.rendition:recordPublishedPhotoId(result.localIdentifier)
                rp.rendition:recordPublishedPhotoUrl(result.url)

                -- The photo now has this asset in this format, whatever any collection thinks.
                table.insert(outcome.updates, {
                    photo = rp.photo,
                    identifier = result.localIdentifier,
                    format = context.format,
                })

                -- Everything else the plugin held for this photo in the format is a leftover:
                -- the version just replaced, and any copy a collection had drifted onto.
                local superseded = Albums.supersededAssets(
                    context.index, rp.photo, context.format, result.localIdentifier)
                for _, remoteId in ipairs(superseded) do
                    table.insert(outcome.superseded, remoteId)
                end

                -- The other collections publishing this photo in the format are told about
                -- the asset before it is deleted out from under them.
                for _, entry in ipairs(Albums.staleEntries(context.index, rp.photo,
                    context.format, result.localIdentifier, context.localCollectionId)) do
                    table.insert(outcome.repoints, Albums.repoint(
                        entry, context.format, result.localIdentifier, result.url))
                end

                -- A collection that changed format was still naming the asset in the old
                -- one. Moving off it is a removal like any other: it leaves this album, and
                -- it is deleted when no other collection publishes it.
                local outgoing, outgoingFormat = Albums.outgoingAsset(
                    context.index, rp.photo, context.format, context.localCollectionId)
                local dropped = {}
                if outgoing and Albums.isPublishedElsewhere(
                    context.index, rp.photo, outgoingFormat, context.localCollectionId) then
                    table.insert(outcome.evictions, outgoing)
                elseif outgoing then
                    dropped = Albums.supersededAssets(context.index, rp.photo, outgoingFormat, nil)
                    for _, remoteId in ipairs(dropped) do
                        table.insert(outcome.superseded, remoteId)
                    end
                    table.insert(outcome.dropped, { photo = rp.photo, format = outgoingFormat })
                end

                -- One line per photo, because the trail from a Lightroom photo to the asset
                -- it ended up with, and to the ones it replaced, is the only way to work out
                -- afterwards what a publish actually did.
                local line
                if result.reused then
                    outcome.reused = outcome.reused + 1
                    line = 'Reused existing ' .. context.format .. ' asset -> ' .. result.localIdentifier
                else
                    outcome.published = outcome.published + 1
                    line = 'Published photo as ' .. context.format .. ' -> ' .. result.localIdentifier
                end
                if #superseded > 0 then
                    line = line .. ', replacing ' .. table.concat(superseded, ' ')
                end
                if #dropped > 0 then
                    line = line .. ', dropping ' .. outgoingFormat .. ' ' .. table.concat(dropped, ' ')
                elseif outgoing then
                    line = line .. ', leaving ' .. outgoingFormat .. ' ' .. outgoing
                        .. ' to the collections still publishing it'
                end
                logger:info(line)
            else
                local errorMsg = 'Unknown error'
                if result then
                    errorMsg = result.errorMessage or result.errorCode or 'Unknown error'
                end
                if result and Importer.isReuseMissing(result) then
                    -- The asset the photo was keeping has been deleted in Photos. Forgetting
                    -- it means the next publish renders and imports instead of skipping the
                    -- render on the strength of an identifier that leads nowhere.
                    table.insert(outcome.forget, { photo = rp.photo, format = context.format })
                end
                rp.rendition:uploadFailed(errorMsg)
                logger:error('Failed to import photo: ' .. errorMsg)
            end
        end
    else
        local errorMsg = batchResult.errorMessage or batchResult.errorCode or 'Batch import failed'
        logger:error('Batch import failed: ' .. errorMsg)
        if Importer.isAuthorizationError(batchResult) then
            showAuthorizationError(batchResult)
        end
        for _, rp in ipairs(renditionPhotos) do
            rp.rendition:uploadFailed(errorMsg)
        end
    end

    return outcome, batchResult.album
end

--- Deletes the assets a batch import left behind.
--- @param progressScope LrProgressScope Active progress scope for status updates
--- @param superseded table Array of Apple Photos local identifiers to delete
--- @return boolean Whether they are gone
local function deleteOldVersions(progressScope, superseded)
    if #superseded == 0 then
        return true
    end

    progressScope:setCaption('Cleaning up old versions...')
    logger:info('Deleting ' .. #superseded .. ' old photo versions')
    local deleteResult = Importer.deletePhotos(superseded)
    if deleteResult.status == Importer.STATUS_SUCCESS then
        logger:info('Deleted ' .. deleteResult.deletedCount .. ' old versions')
        return true
    end

    logger:error('Failed to delete old versions: ' ..
        (deleteResult.errorMessage or deleteResult.errorCode or 'Unknown error'))
    return false
end

--- Renders the photos Lightroom was told to skip, in the collection's own format.
---
--- A failure to render is reported on the photo. A cancelled run reports nothing, since the
--- publish is about to be abandoned and the photos stay waiting.
---
--- @param functionContext LrFunctionContext Lightroom function context for cleanup
--- @param progressScope LrProgressScope Active progress scope for cancellation and status
--- @param pending table Array of the renditions that were skipped
--- @param format string The collection's format
--- @param progress table {done, total} photos, for the progress bar
--- @return table Map of photo localIdentifier to the path it was rendered to
local function renderInFormat(functionContext, progressScope, pending, format, progress)
    local photos = {}
    for _, rendition in ipairs(pending) do
        table.insert(photos, rendition.photo)
    end

    progressScope:setCaption('Rendering as ' .. format .. '...')
    logger:info('Rendering ' .. #photos .. ' photos as ' .. format)
    local done = progress.done
    local ok, rendered = LrTasks.pcall(Renderer.render, functionContext, photos, format, function()
        done = done + 1
        progressScope:setPortionComplete(done, progress.total)
        return not progressScope:isCanceled()
    end)
    if not ok then
        logger:error('Rendering as ' .. format .. ' failed: ' .. tostring(rendered))
    end

    local paths = {}
    for _, rendition in ipairs(pending) do
        local result = ok and rendered[rendition.photo.localIdentifier] or nil
        if result and result.path then
            paths[rendition.photo.localIdentifier] = result.path
        elseif not progressScope:isCanceled() then
            local message = result and result.message
                or (not ok and tostring(rendered))
                or 'Lightroom did not render this photo.'
            rendition:uploadFailed(message)
        end
    end
    return paths
end

--- Main publish entry point called by Lightroom after photos are rendered.
---
--- Runs two passes over the renditions. The first decides which photos can keep the asset
--- they already have, because `skipRender` has to be called before rendering starts. The
--- second collects the rendered files and hands the batch, with its album, to the helper.
---
--- Everything is decided in the collection's format. The asset a photo has in another one
--- belongs to other collections, and is neither reused nor replaced here.
---
--- @param functionContext LrFunctionContext Lightroom function context for cleanup
--- @param exportContext LrExportContext Context providing renditions and progress
function provider.processRenderedPhotos(functionContext, exportContext)
    local nPhotos = exportContext.exportSession:countRenditions()
    local progressScope = exportContext:configureProgress({
        title = string.format('Publishing %d photos to Apple Photos', nPhotos),
    })

    local catalog = LrApplication.activeCatalog()
    local collection = exportContext.publishedCollection
    local info = exportContext.publishedCollectionInfo
    local localCollectionId = collection and collection.localIdentifier

    -- Export has no collection to ask, so it gets what the service renders.
    local format = collection and Formats.forCollection(collection) or Formats.DEFAULT
    -- Lightroom renders the default format. Anything else it would render wrongly, so its
    -- render is skipped and the photos are rendered separately.
    local renderedHere = format ~= Formats.DEFAULT

    -- One walk of the plugin's published photos answers every question this publish asks
    -- about the photos in it.
    local index = Albums.buildIndex(catalog)
    logger:info('Indexed ' .. Albums.describeIndex(index) .. ', publishing as ' .. format)
    if collection and index.collections == 0 then
        -- The collection being published is in there by definition, so an empty index means
        -- the services could not be read. Everything downstream would then quietly decide
        -- that no other collection publishes any of these photos.
        logger:error('Found no published collections to index, so other collections cannot '
            .. 'be kept in step with this publish')
    end

    -- Decide reuse before rendering begins, since skipRender is only honored until then.
    -- A photo whose asset is already current keeps it: re-importing would cost a render, an
    -- import and a delete to arrive back where it started, and it is the act of replacing an
    -- asset per collection that used to leave two collections holding two copies.
    --
    -- Export has no collection to ask and no album to file into, so it always imports.
    --
    -- Only the identifier on the photo is reused, never one a collection is holding. An
    -- asset found missing is forgotten from the photo so that the next publish renders, and
    -- the collections that named it still do: falling back to them would offer the same
    -- missing asset again on every publish after.
    local reuseByPhoto = {}
    if collection then
        for _, rendition in exportContext.exportSession:renditions() do
            local photo = rendition.photo
            local identifier = Assets.identifier(photo, format)
            if identifier and Albums.assetIsCurrent(index, photo, format) then
                reuseByPhoto[photo.localIdentifier] = identifier
                rendition:skipRender()
            elseif renderedHere then
                rendition:skipRender()
            end
        end
    end

    -- Render Exports
    local renditions = {}
    local unrendered = {}
    for i, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        if progressScope:isCanceled() then
            break
        end
        if not renderedHere then
            progressScope:setPortionComplete(i - 1, nPhotos)
        end

        local reuseIdentifier = reuseByPhoto[rendition.photo.localIdentifier]
        if reuseIdentifier then
            -- Nothing was rendered, so there is no file; the helper files the asset instead.
            table.insert(renditions, {
                rendition = rendition,
                photo = rendition.photo,
                path = rendition.destinationPath,
                reuseIdentifier = reuseIdentifier,
            })
        elseif renderedHere then
            table.insert(unrendered, rendition)
        else
            local success, path = rendition:waitForRender()

            if success then
                table.insert(renditions, {
                    rendition = rendition,
                    photo = rendition.photo,
                    path = path,
                    -- The asset on the photo rather than the one on this collection's
                    -- published photo. The helper reads album memberships and favorite
                    -- status off it to restore onto the import, and the photo's own asset is
                    -- the most recent one, so it is the one carrying them.
                    previousIdentifier = Albums.predecessor(
                        index, rendition.photo, format, localCollectionId),
                })
            else
                rendition:uploadFailed(path)
            end
        end
    end

    if #unrendered > 0 and not progressScope:isCanceled() then
        local paths = renderInFormat(functionContext, progressScope, unrendered, format,
            { done = #renditions, total = nPhotos })
        for _, rendition in ipairs(unrendered) do
            local path = paths[rendition.photo.localIdentifier]
            if path then
                table.insert(renditions, {
                    rendition = rendition,
                    photo = rendition.photo,
                    path = path,
                    previousIdentifier = Albums.predecessor(
                        index, rendition.photo, format, localCollectionId),
                })
            end
        end
    end
    if #renditions == 0 or progressScope:isCanceled() then
        return
    end

    -- Import into Apple Photos
    local outcome, album = importPhotoBatch(progressScope, renditions, {
        album = collection and Albums.albumTarget(collection) or nil,
        localCollectionId = localCollectionId,
        index = index,
        format = format,
    })

    -- Record where Photos put things, so the next publish finds the same album rather than
    -- building another one beside it.
    if album and album.identifier then
        exportContext.exportSession:recordRemoteCollectionId(album.identifier)
        local uuid = Albums.albumUuid(album.identifier)
        if uuid then
            exportContext.exportSession:recordRemoteCollectionUrl('photos:albums?albumUuid=' .. uuid)
        end
        if album.created then
            logger:info('Created album for ' .. info.name .. ' -> ' .. album.identifier)
        else
            logger:info('Using existing album for ' .. info.name .. ' -> ' .. album.identifier)
        end
    end
    logger:info('Imported ' .. outcome.published .. ' photos, reused ' .. outcome.reused
        .. ' existing assets')

    -- The catalog writes, each in one transaction, and each unable to take the publish down
    -- with it. Identifiers go out to the other collections before the assets they were
    -- holding are deleted.
    local recorded = tryBookkeeping('record the assets on the photos',
        Assets.record, catalog, outcome.updates)
    if #outcome.forget > 0 then
        tryBookkeeping('forget assets that are no longer in Photos',
            Assets.forget, catalog, outcome.forget)
    end
    if #outcome.repoints > 0 then
        local repointed = tryBookkeeping('update the other collections',
            Albums.syncIdentifiers, catalog, outcome.repoints)
        if repointed then
            logger:info('Re-pointed ' .. repointed .. ' photos in other collections ('
                .. Albums.describeRepoints(outcome.repoints) .. ')')
        end
    end

    -- Assets in the format this collection used to have, which other collections still
    -- publish, only leave its album. That is silent, and a failure costs nothing reconcile
    -- cannot put right, since the album is then set from the photos.
    if #outcome.evictions > 0 and album and album.identifier then
        local removeResult = Importer.removeFromAlbum(album.identifier, outcome.evictions)
        if removeResult.status == Importer.STATUS_SUCCESS then
            logger:info('Took ' .. #outcome.evictions .. ' photos in the old format out of the album')
        else
            logger:error('Failed to take the old format out of the album: '
                .. (removeResult.errorMessage or removeResult.errorCode or 'Unknown error'))
        end
    end

    if recorded then
        -- A format is only forgotten once its assets are gone. Until then the photo is the
        -- one thing still naming them.
        if deleteOldVersions(progressScope, outcome.superseded) and #outcome.dropped > 0 then
            tryBookkeeping('forget the assets in the old format',
                Assets.forget, catalog, outcome.dropped)
        end
    elseif #outcome.superseded > 0 then
        -- Deleting them now would take away the only assets the catalog can still name.
        -- Duplicates in Photos are recoverable; that is not.
        logger:error('Keeping ' .. #outcome.superseded
            .. ' replaced assets, since their photos could not be updated')
    end

    progressScope:done()
end

--- Called when the user removes photos from a published collection.
---
--- Removal is partitioned rather than applied uniformly. A photo still published by another
--- collection only leaves this collection's album, which is silent. A photo nothing else
--- publishes has its assets deleted, which removes them from every album anyway, so there is
--- no membership step and no way for a refused deletion to leave a photo stripped from an
--- album it is still published in.
---
--- Lightroom names assets here rather than photos, so each one is resolved back to its photo
--- first. Whether an asset may be deleted is a question about its photo, and the photo is
--- also what knows which other assets are its own.
---
--- "Published by another collection" means in the same format. A photo also in an album of
--- another format has a different asset there, which this removal neither needs nor touches,
--- so the asset being removed is deleted unless a collection in its own format still wants it.
---
--- @param publishSettings table Current publish settings
--- @param photoIDs table Array of Apple Photos local identifiers
--- @param deletedCallback function Called with each photoID once it is dealt with
--- @param localCollectionID number Lightroom local identifier for the published collection
function provider.deletePhotosFromPublishedCollection(publishSettings, photoIDs, deletedCallback,
                                                      localCollectionID)
    if #photoIDs == 0 then
        return
    end

    local catalog = LrApplication.activeCatalog()
    local collection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionID)
    local index = Albums.buildIndex(catalog)

    -- The default collection has no album, whatever identifier it may still carry from
    -- before it stopped mirroring. Reading that stale identifier here would try to remove
    -- photos from an album nothing manages, and fail outright once it is deleted in Photos.
    local albumIdentifier = nil
    if collection and not Albums.isDefaultCollection(collection) then
        albumIdentifier = collection:getRemoteId()
    end

    local removals = newIdentifierList()
    local deletions = newIdentifierList()
    local forget = {}
    local leaveAlbum = {}
    local deleteAsset = {}

    for _, photoID in ipairs(photoIDs) do
        local photo = Albums.photoFor(index, photoID)
        -- The format of the asset rather than of the collection, which may have changed
        -- format since it published this.
        local format = photo and Albums.formatOf(index, photo, photoID)
        if photo and Albums.isPublishedElsewhere(index, photo, format, localCollectionID) then
            -- Both identifiers are offered: the album may hold the one this collection was
            -- naming as well as the one the photo has.
            addIdentifier(removals, photoID)
            addIdentifier(removals, Assets.identifier(photo, format))
            table.insert(leaveAlbum, photoID)
        else
            if photo then
                for _, remoteId in ipairs(Albums.supersededAssets(index, photo, format, nil)) do
                    addIdentifier(deletions, remoteId)
                end
                table.insert(forget, { photo = photo, format = format })
            else
                -- Nothing in the catalog names this asset any more, so there is no photo to
                -- ask about. Take Lightroom at its word and delete it.
                addIdentifier(deletions, photoID)
            end
            table.insert(deleteAsset, photoID)
        end
    end
    logger:info('Removing ' .. #photoIDs .. ' photos: ' .. #deleteAsset .. ' orphaned, '
        .. #leaveAlbum .. ' published elsewhere')

    -- Photos that live on elsewhere only leave this album.
    if #leaveAlbum > 0 then
        if albumIdentifier and albumIdentifier ~= '' then
            local removeResult = Importer.removeFromAlbum(albumIdentifier, removals.order)
            if removeResult.status ~= Importer.STATUS_SUCCESS then
                local message = removeResult.errorMessage or removeResult.errorCode or 'Remove failed'
                logger:error('Failed to remove photos from the album: ' .. message)
                if Importer.isAuthorizationError(removeResult) then
                    showAuthorizationError(removeResult)
                    return
                end
                LrErrors.throwUserError(message)
            end
        end
        -- Nothing to remove them from when there is no album, so acknowledge and move on.
        for _, photoID in ipairs(leaveAlbum) do
            deletedCallback(photoID)
        end
    end

    if #deleteAsset == 0 then
        return
    end

    if #deletions.order == 0 then
        -- The assets are already gone from Photos, so only Lightroom's side is left.
        for _, photoID in ipairs(deleteAsset) do
            deletedCallback(photoID)
        end
        return
    end

    local deleteResult = Importer.deletePhotos(deletions.order)
    if deleteResult.status == Importer.STATUS_SUCCESS then
        tryBookkeeping('forget the deleted assets', Assets.forget, catalog, forget)
        for _, photoID in ipairs(deleteAsset) do
            deletedCallback(photoID)
        end
        logger:info('Deleted ' .. deleteResult.deletedCount .. ' photos')
    else
        local errorMsg = deleteResult.errorMessage or deleteResult.errorCode or 'Delete failed'
        logger:error('Failed to delete photos: ' .. errorMsg)
        if Importer.isAuthorizationError(deleteResult) or Importer.isUserCancelled(deleteResult) then
            -- Nothing was passed to deletedCallback for these, so Lightroom keeps them in
            -- the collection for a retry once access is granted or the user agrees.
            if Importer.isAuthorizationError(deleteResult) then
                showAuthorizationError(deleteResult)
            end
            return
        end
        LrErrors.throwUserError(errorMsg)
    end
end

--- Called when the user renames a published collection.
--- @param publishSettings table Current publish settings
--- @param info table Lifecycle info, including remoteId and the new name
function provider.renamePublishedCollection(publishSettings, info)
    if not info.remoteId or info.remoteId == '' then
        -- Never published, so Photos has nothing under this name yet.
        return
    end

    requireSuccess(Importer.renameAlbum(info.remoteId, info.name),
        'rename the album in Apple Photos')
    logger:info('Renamed Photos album to ' .. info.name)
end

--- Called when the user deletes a published collection.
---
--- Only the album goes; its photos stay in the library unless nothing else publishes them.
---
--- The album goes first, because deleting a container is the one thing here that raises a
--- confirmation dialog. Doing it the other way round means a refusal arrives after the
--- photos have already been deleted, and the question Lightroom then asks about reverting
--- the collection cannot bring them back.
---
--- @param publishSettings table Current publish settings
--- @param info table Lifecycle info, including remoteId
function provider.deletePublishedCollection(publishSettings, info)
    if not info.remoteId or info.remoteId == '' then
        return
    end

    local catalog = LrApplication.activeCatalog()
    local index = Albums.buildIndex(catalog)

    requireSuccess(Importer.deleteAlbum(info.remoteId),
        'delete the album from Apple Photos')
    logger:info('Deleted Photos album ' .. info.remoteId)

    -- Lightroom hands over the photos it published through this collection. The field is
    -- undocumented but the Flickr sample relies on it, so use it when it is there and settle
    -- for removing only the container when it is not.
    if not info.photoIds or #info.photoIds == 0 then
        return
    end

    local localId = info.publishedCollection and info.publishedCollection.localIdentifier
    local deletions = newIdentifierList()
    local forget = {}
    local kept = 0
    for _, photoID in ipairs(info.photoIds) do
        local photo = Albums.photoFor(index, photoID)
        local format = photo and Albums.formatOf(index, photo, photoID)
        if photo and Albums.isPublishedElsewhere(index, photo, format, localId) then
            -- Still published somewhere in this format, so the asset stays and only loses
            -- this album, which deleting the album has already seen to.
            kept = kept + 1
        elseif photo then
            for _, remoteId in ipairs(Albums.supersededAssets(index, photo, format, nil)) do
                addIdentifier(deletions, remoteId)
            end
            table.insert(forget, { photo = photo, format = format })
        else
            addIdentifier(deletions, photoID)
        end
    end

    if #deletions.order == 0 then
        logger:info('Kept all ' .. kept .. ' photos, other collections publish them')
        return
    end

    logger:info('Deleting ' .. #deletions.order .. ' photos with the collection, keeping '
        .. kept .. ' others publish')
    requireSuccess(Importer.deletePhotos(deletions.order),
        'delete the photos from Apple Photos')
    tryBookkeeping('forget the deleted assets', Assets.forget, catalog, forget)
end

--- Called for the "Show in Photos" context-menu item.
--- @param publishSettings table Current publish settings
--- @param info table Lifecycle info, including remoteId
function provider.goToPublishedCollection(publishSettings, info)
    if info.isDefaultCollection then
        LrDialogs.message('No album for this collection',
            'Publishing here puts photos in your Photos library without filing them in an '
            .. 'album. Add them to a collection to get an album.', 'info')
        return
    end

    local uuid = Albums.albumUuid(info.remoteId)
    if not uuid then
        LrDialogs.message('Not published yet',
            'Publish this album once and Apple Photos will have something to show.', 'info')
        return
    end
    Shell.openUrl('photos:albums?albumUuid=' .. uuid)
end

--- Validates a collection name before Lightroom accepts it.
--- Only cheap checks belong here; anything Photos might reject is reported when we try.
--- @param proposedName string The name as typed
--- @return boolean Whether the name is acceptable
--- @return string|nil Why it is not
function provider.validatePublishedCollectionName(proposedName)
    if not proposedName or proposedName:match('^%s*$') then
        return false, 'An album needs a name.'
    end
    return true
end

return provider

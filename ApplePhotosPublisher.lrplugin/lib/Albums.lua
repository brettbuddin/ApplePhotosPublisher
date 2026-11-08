--[[
    Albums

    Maps Lightroom's published collections onto Apple Photos albums.

    Lightroom only ever reports deltas, and it reports them per collection, so this module
    also answers the questions a delta cannot: which collections publish a given photo, and
    what an album's membership ought to be.
]]

local pluginLoad = require 'PluginModuleLoader'
local Importer = pluginLoad 'lib/Importer'
local logger = pluginLoad 'lib/Logger'

local M = {}

--- Whether this is the built-in default collection.
---
--- The default collection means "in the Photos library, filed in no album". It is the way to
--- publish a photo without organizing it, so it gets no album of its own. Only the
--- collections the user creates mirror to albums.
---
--- @param collection LrPublishedCollection The published collection
--- @return boolean
function M.isDefaultCollection(collection)
    local summary = collection:getCollectionInfoSummary()
    return summary ~= nil and summary.isDefaultCollection == true
end

--- The album target to send with a publish, mirroring this collection.
---
--- Returns nil for the default collection, which has no album: publishing there means
--- getting the photo into the library without filing it anywhere.
---
--- @param collection LrPublishedCollection The collection being published
--- @return table|nil {identifier, name}, or nil when there is no album
function M.albumTarget(collection)
    if M.isDefaultCollection(collection) then
        return nil
    end

    return {
        identifier = collection:getRemoteId(),
        name = collection:getName(),
    }
end

--- Every published collection in a service.
--- Collection sets are not offered, so these are all top level.
--- @param publishService LrPublishService
--- @return table Array of LrPublishedCollection
function M.allCollections(publishService)
    return publishService:getChildCollections()
end

--- Every published collection in the service that publishes a photo with this remote id.
---
--- Walks the service rather than calling `photo:getContainedPublishedCollections()`, which
--- omits smart published collections. Missing one of those would let us delete an asset a
--- smart collection still points at.
---
--- @param publishService LrPublishService
--- @param remoteId string The Apple Photos identifier to look for
--- @return table Array of {collection, publishedPhoto}
function M.publishedBy(publishService, remoteId)
    local found = {}
    if not publishService or not remoteId or remoteId == '' then
        logger:info('publishedBy: no service or id, nothing to look through')
        return found
    end

    local collections = M.allCollections(publishService)
    local scanned = 0
    for _, collection in ipairs(collections) do
        for _, publishedPhoto in ipairs(collection:getPublishedPhotos()) do
            scanned = scanned + 1
            if publishedPhoto:getRemoteId() == remoteId then
                table.insert(found, { collection = collection, publishedPhoto = publishedPhoto })
            end
        end
    end

    M.lastScan = { collections = #collections, photos = scanned, matches = #found }
    return found
end

--- One line describing what the last service walk actually saw.
--- Called once per publish rather than per photo, so the log stays readable.
--- @return string
function M.describeLastScan()
    local scan = M.lastScan
    if not scan then
        return 'no service walk happened'
    end
    return 'walked ' .. scan.collections .. ' collections, '
        .. scan.photos .. ' published photos, ' .. scan.matches .. ' matched'
end

--- Whether any collection other than the given one still publishes this photo.
--- @param publishService LrPublishService
--- @param remoteId string The Apple Photos identifier
--- @param excludeLocalId number Local identifier of the collection to ignore
--- @return boolean
function M.isPublishedElsewhere(publishService, remoteId, excludeLocalId)
    for _, entry in ipairs(M.publishedBy(publishService, remoteId)) do
        if entry.collection.localIdentifier ~= excludeLocalId then
            return true
        end
    end
    return false
end

--- Point every collection that referenced an old asset at its replacement.
---
--- Replacing a photo's asset leaves the other collections publishing it holding an
--- identifier for something that no longer exists. Removing the photo from one of those
--- would then fail, and republishing it would restore no album memberships.
---
--- @param catalog LrCatalog The active catalog
--- @param publishService LrPublishService
--- @param oldId string The replaced Apple Photos identifier
--- @param newId string The new Apple Photos identifier
--- @param newUrl string|nil The new deep link
--- @param excludeLocalId number Local identifier of the collection Lightroom already updated
function M.repointSiblings(catalog, publishService, oldId, newId, newUrl, excludeLocalId)
    local stale = {}
    for _, entry in ipairs(M.publishedBy(publishService, oldId)) do
        if entry.collection.localIdentifier ~= excludeLocalId then
            table.insert(stale, entry)
        end
    end
    if #stale == 0 then
        return
    end

    -- The ordinary gate, despite the SDK reference saying setRemoteId may be called from
    -- withPrivateWriteAccessDo. Lightroom rejects that with "setRemoteIdForRemotePhoto: must
    -- be called from within a withWriteAccessDo block". Clearing the edited flag in the same
    -- transaction undoes any dirtying this causes, which is the point of doing it here.
    catalog:withWriteAccessDo('Update Photos identifiers', function()
        for _, entry in ipairs(stale) do
            entry.publishedPhoto:setRemoteId(newId)
            if newUrl then
                entry.publishedPhoto:setRemoteUrl(newUrl)
            end
            -- These collections now reference the asset that was just published, and their
            -- albums already hold it because membership was restored onto it. They are
            -- current, so clear the flag the replacement set on the photo rather than
            -- leaving them asking to republish work that is already done.
            entry.publishedPhoto:setEditedFlag(false)
            logger:info('Re-pointed ' .. entry.collection:getName() .. ' at ' .. newId)
        end
    end)
end

--- The identifier a photo can keep instead of being imported again, or nil.
---
--- A photo added to a second collection does not need a new asset: the one it already has is
--- current, and replacing it would leave the collections already publishing it pointing at
--- something deleted. Only reuse when a sibling collection agrees the asset is up to date,
--- which `getEditedFlag` reports.
---
--- @param publishService LrPublishService
--- @param remoteId string|nil The photo's recorded Apple Photos identifier
--- @param excludeLocalId number Local identifier of the collection being published
--- @return string|nil The identifier to reuse
function M.reusableIdentifier(publishService, remoteId, excludeLocalId)
    if not remoteId or remoteId == '' then
        return nil
    end

    local current = false
    for _, entry in ipairs(M.publishedBy(publishService, remoteId)) do
        if entry.collection.localIdentifier ~= excludeLocalId then
            if entry.publishedPhoto:getEditedFlag() then
                -- A sibling is waiting to republish this photo, so its asset is stale.
                return nil
            end
            current = true
        end
    end

    if current then
        return remoteId
    end
    return nil
end

--- The album UUID for a deep link, with the trailing PhotoKit suffix removed.
--- @param remoteId string|nil An album's local identifier
--- @return string|nil The UUID portion
function M.albumUuid(remoteId)
    if not remoteId or remoteId == '' then
        return nil
    end
    return remoteId:match('^[^/]+') or remoteId
end

--- Set a collection's album membership to exactly its published photos.
---
--- The repair path for two kinds of drift: an album edited in Photos, and an album created
--- for a collection whose photos were published before album sync existed, which Lightroom
--- will never mention again because nothing about them changed.
---
--- @param collection LrPublishedCollection The collection to reconcile
--- @return table Result table from the helper
function M.reconcile(collection)
    if M.isDefaultCollection(collection) then
        -- No album, so nothing to reconcile against.
        logger:info('Skipping ' .. collection:getName() .. ', the default collection has no album')
        return { status = Importer.STATUS_SUCCESS }
    end

    local name = collection:getName()
    local identifiers = {}
    for _, publishedPhoto in ipairs(collection:getPublishedPhotos()) do
        local remoteId = publishedPhoto:getRemoteId()
        if remoteId and remoteId ~= '' then
            table.insert(identifiers, remoteId)
        end
    end

    local albumIdentifier = collection:getRemoteId()
    if not albumIdentifier or albumIdentifier == '' then
        -- Never published, so there is no album to reconcile against yet.
        local ensured = Importer.ensureAlbum(name, nil, nil)
        if ensured.status ~= Importer.STATUS_SUCCESS then
            return ensured
        end
        albumIdentifier = ensured.identifier
        collection.catalog:withWriteAccessDo('Record Photos album', function()
            collection:setRemoteId(albumIdentifier)
        end)
    end

    logger:info('Reconciling ' .. name .. ' (' .. #identifiers .. ' photos)')
    return Importer.syncAlbum(albumIdentifier, identifiers)
end

return M

--[[
    Albums

    Maps Lightroom's published collections onto Apple Photos albums.

    Lightroom only ever reports deltas, and it reports them per collection, so this module
    also answers the questions a delta cannot: which collections publish a given photo, which
    asset that photo has, and what an album's membership ought to be.

    Those questions are all keyed on the photo rather than on an Apple Photos identifier.
    Keying them on the identifier made every answer conditional on the collections already
    agreeing about the photo, so the moment two of them disagreed nothing could see the
    disagreement, let alone repair it. Assets.lua has the rest of that story.
]]

local pluginLoad = require 'PluginModuleLoader'
local Assets = pluginLoad 'lib/Assets'
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

--- A deep link to an asset, shown in the album it was published through.
--- @param albumIdentifier string|nil The album's local identifier
--- @param assetIdentifier string The asset's local identifier
--- @return string The photos: URL
function M.assetUrl(albumIdentifier, assetIdentifier)
    local assetUuid = M.albumUuid(assetIdentifier)
    local albumUuid = M.albumUuid(albumIdentifier)
    if albumUuid then
        return 'photos:albums?albumUuid=' .. albumUuid .. '&assetUuid=' .. assetUuid
    end
    return 'photos://asset?assetLocalIdentifier=' .. assetUuid
end

--- Index every photo this plugin publishes, keyed by the photo.
---
--- Walks the services rather than calling `photo:getContainedPublishedCollections()`, which
--- omits smart published collections. Missing one of those would let us delete an asset a
--- smart collection still points at.
---
--- Built once per operation. The questions here used to be answered by walking the services
--- per photo, which cost a full pass over every published photo in the plugin for each photo
--- in the batch.
---
--- Spans every service of the plugin, not just the one being published, because the asset is
--- recorded on the photo and a photo published by two services therefore has one asset
--- between them. The helper only ever works on the system photo library, so two services
--- really are two views of the same place.
---
--- @param catalog LrCatalog The active catalog
--- @return table Index with byPhoto, byAsset, collections and photos
function M.buildIndex(catalog)
    local index = { collections = 0, photos = 0, byPhoto = {}, byAsset = {} }

    for _, service in ipairs(catalog:getPublishServices(_PLUGIN.id)) do
        for _, collection in ipairs(M.allCollections(service)) do
            index.collections = index.collections + 1
            for _, publishedPhoto in ipairs(collection:getPublishedPhotos()) do
                local photo = publishedPhoto:getPhoto()
                local key = photo.localIdentifier
                local remoteId = publishedPhoto:getRemoteId()
                index.photos = index.photos + 1

                local entries = index.byPhoto[key]
                if not entries then
                    entries = {}
                    index.byPhoto[key] = entries
                end
                table.insert(entries, {
                    collection = collection,
                    publishedPhoto = publishedPhoto,
                    remoteId = remoteId,
                    photo = photo,
                })

                if remoteId and remoteId ~= '' then
                    local holder = index.byAsset[remoteId]
                    if not holder then
                        holder = { photo = photo, keys = {} }
                        index.byAsset[remoteId] = holder
                    end
                    holder.keys[key] = true
                end
            end
        end
    end

    return index
end

--- One line describing what an index actually covers.
--- @param index table An index from `buildIndex`
--- @return string
function M.describeIndex(index)
    if not index then
        return 'no index was built'
    end
    return index.collections .. ' collections, ' .. index.photos .. ' published photos'
end

--- Every collection in the plugin that publishes this photo.
--- @param index table An index from `buildIndex`
--- @param photo LrPhoto
--- @return table Array of {collection, publishedPhoto, remoteId, photo}
function M.entries(index, photo)
    if not index or not photo then
        return {}
    end
    return index.byPhoto[photo.localIdentifier] or {}
end

--- The photo an asset belongs to, as far as the catalog knows.
--- Used to answer a removal, which names assets rather than photos.
--- @param index table An index from `buildIndex`
--- @param remoteId string An Apple Photos identifier
--- @return LrPhoto|nil
function M.photoFor(index, remoteId)
    if not index or not remoteId or remoteId == '' then
        return nil
    end
    local holder = index.byAsset[remoteId]
    return holder and holder.photo or nil
end

--- Whether any collection other than the given one still publishes this photo.
--- @param index table An index from `buildIndex`
--- @param photo LrPhoto
--- @param excludeLocalId number|nil Local identifier of the collection to ignore
--- @return boolean
function M.isPublishedElsewhere(index, photo, excludeLocalId)
    for _, entry in ipairs(M.entries(index, photo)) do
        if entry.collection.localIdentifier ~= excludeLocalId then
            return true
        end
    end
    return false
end

--- The asset the plugin last knew this photo by.
---
--- The identifier on the photo, falling back to whatever its collections hold. A publish
--- records the collection before the photo, so that is the one direction in which the two can
--- be left out of step, and the fallback is what keeps a photo in that state from being
--- republished as though it had never been in Photos at all: its album memberships and
--- favorite status are read off this.
---
--- @param index table An index from `buildIndex`
--- @param photo LrPhoto
--- @return string|nil
function M.lastKnownAsset(index, photo)
    local identifier = Assets.identifier(photo)
    if identifier then
        return identifier
    end
    for _, entry in ipairs(M.entries(index, photo)) do
        if entry.remoteId and entry.remoteId ~= '' then
            return entry.remoteId
        end
    end
    return nil
end

--- Whether the asset this photo has can be published as it stands.
---
--- A photo joining another collection does not need a new asset: the one it already has is
--- current, and replacing it costs a render, an import and a delete to arrive back where it
--- started. Lightroom's edited flag is what reports that, so a collection has to be publishing
--- the photo already for anything to vouch for the asset. A photo whose only claim is the
--- identifier on itself gets a fresh asset, since nothing says that identifier predates the
--- last edit.
---
--- @param index table An index from `buildIndex`
--- @param photo LrPhoto
--- @return boolean
function M.assetIsCurrent(index, photo)
    local entries = M.entries(index, photo)
    if #entries == 0 then
        return false
    end
    for _, entry in ipairs(entries) do
        if entry.publishedPhoto:getEditedFlag() then
            -- A collection is waiting to republish this photo, so its asset is stale.
            return false
        end
    end
    return true
end

--- The collections holding an identifier other than the one the photo now has.
--- @param index table An index from `buildIndex`
--- @param photo LrPhoto
--- @param identifier string The asset the photo now has
--- @param excludeLocalId number|nil Collection Lightroom has already updated itself
--- @return table Array of index entries
function M.staleEntries(index, photo, identifier, excludeLocalId)
    local stale = {}
    for _, entry in ipairs(M.entries(index, photo)) do
        if entry.collection.localIdentifier ~= excludeLocalId
            and entry.remoteId ~= identifier then
            table.insert(stale, entry)
        end
    end
    return stale
end

--- Every asset the plugin holds for this photo apart from the one it now has.
---
--- Both the identifier on the photo and the identifiers on its collections are read, so a
--- publish clears up assets left by a collection that had drifted onto its own copy as well
--- as the version it has just replaced.
---
--- @param index table An index from `buildIndex`
--- @param photo LrPhoto
--- @param identifier string|nil The asset the photo now has, which is kept
--- @return table Array of Apple Photos identifiers
function M.supersededAssets(index, photo, identifier)
    local superseded = {}
    local seen = {}

    local function consider(remoteId)
        if not remoteId or remoteId == '' or remoteId == identifier or seen[remoteId] then
            return
        end
        seen[remoteId] = true

        local holder = index and index.byAsset[remoteId]
        if holder then
            for key in pairs(holder.keys) do
                if key ~= photo.localIdentifier then
                    -- Another photo publishes this asset, so it is not ours to delete.
                    logger:info('Leaving ' .. remoteId .. ', another photo publishes it')
                    return
                end
            end
        end

        table.insert(superseded, remoteId)
    end

    consider(Assets.identifier(photo))
    for _, entry in ipairs(M.entries(index, photo)) do
        consider(entry.remoteId)
    end

    return superseded
end

--- Point collections at the asset their photo now has.
---
--- Replacing an asset leaves the other collections publishing the photo holding an
--- identifier for something that no longer exists. Removing the photo from one of those
--- would then fail, and republishing it would restore no album memberships.
---
--- @param catalog LrCatalog The active catalog
--- @param repoints table Array of {publishedPhoto, identifier, url, name}
--- @return number How many collections were updated
function M.syncIdentifiers(catalog, repoints)
    if #repoints == 0 then
        return 0
    end

    -- The ordinary gate, despite the SDK reference saying setRemoteId may be called from
    -- withPrivateWriteAccessDo. Lightroom rejects that with "setRemoteIdForRemotePhoto: must
    -- be called from within a withWriteAccessDo block". Clearing the edited flag in the same
    -- transaction undoes any dirtying this causes, which is the point of doing it here.
    --
    -- One transaction for the whole batch: a republish of a large collection would otherwise
    -- open one per photo and bury everything else on the undo stack.
    catalog:withWriteAccessDo('Update Photos identifiers', function()
        for _, repoint in ipairs(repoints) do
            repoint.publishedPhoto:setRemoteId(repoint.identifier)
            if repoint.url then
                repoint.publishedPhoto:setRemoteUrl(repoint.url)
            end
            -- These collections now reference the asset that was just published, and their
            -- albums already hold it because membership was restored onto it. They are
            -- current, so clear the flag the replacement set on the photo rather than
            -- leaving them asking to republish work that is already done.
            repoint.publishedPhoto:setEditedFlag(false)
        end
    end)

    return #repoints
end

--- Name the collections a batch of re-points touched, with a count each.
--- One line however many photos moved, which a line per photo would not be.
--- @param repoints table Array of {name}
--- @return string
function M.describeRepoints(repoints)
    local counts = {}
    local order = {}
    for _, repoint in ipairs(repoints) do
        if not counts[repoint.name] then
            counts[repoint.name] = 0
            table.insert(order, repoint.name)
        end
        counts[repoint.name] = counts[repoint.name] + 1
    end

    local parts = {}
    for _, name in ipairs(order) do
        table.insert(parts, name .. ': ' .. counts[name])
    end
    return table.concat(parts, ', ')
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

--- Bring a collection's album, and the identifiers of everything in it, back in line.
---
--- The repair path for drift Lightroom will never mention: an album edited in Photos, an
--- album created for a collection whose photos were published before album sync existed, and
--- a collection still naming an asset its photo has moved on from. Membership comes from the
--- photos rather than from this collection's own identifiers, so a collection that had
--- drifted onto its own copy is brought back in line rather than having the drift confirmed.
---
--- Re-pointing is not limited to this collection. The copy being dropped is about to be
--- deleted, and leaving a sibling collection holding it would turn one kind of drift into
--- another. Those copies are deleted for the same reason publishing deletes them: nothing
--- publishes them any more, so nothing would ever be able to name them again.
---
--- @param collection LrPublishedCollection The collection to reconcile
--- @return table Result from the helper, plus skipped, adopted, repointed and deleted
function M.reconcile(collection)
    if M.isDefaultCollection(collection) then
        -- No album, so nothing to reconcile against.
        logger:info('Skipping ' .. collection:getName() .. ', the default collection has no album')
        return { status = Importer.STATUS_SUCCESS, skipped = true }
    end

    local name = collection:getName()
    local catalog = collection.catalog
    local index = M.buildIndex(catalog)

    local identifiers = {}
    local adoptions = {}
    local repoints = {}
    local superseded = {}
    local seen = {}

    for _, publishedPhoto in ipairs(collection:getPublishedPhotos()) do
        local photo = publishedPhoto:getPhoto()
        local rowId = publishedPhoto:getRemoteId()
        local identifier = Assets.identifier(photo)

        if not identifier and rowId and rowId ~= '' then
            -- Published before the asset moved onto the photo, so adopt what the row holds.
            identifier = rowId
            table.insert(adoptions, { photo = photo, identifier = identifier })
        end

        if identifier then
            table.insert(identifiers, identifier)
            for _, entry in ipairs(M.staleEntries(index, photo, identifier, nil)) do
                table.insert(repoints, {
                    publishedPhoto = entry.publishedPhoto,
                    identifier = identifier,
                    name = entry.collection:getName(),
                })
            end
            for _, remoteId in ipairs(M.supersededAssets(index, photo, identifier)) do
                if not seen[remoteId] then
                    seen[remoteId] = true
                    table.insert(superseded, remoteId)
                end
            end
        end
    end

    local albumIdentifier = collection:getRemoteId()
    if not albumIdentifier or albumIdentifier == '' then
        -- Never published, so there is no album to reconcile against yet.
        local ensured = Importer.ensureAlbum(name, nil)
        if ensured.status ~= Importer.STATUS_SUCCESS then
            return ensured
        end
        albumIdentifier = ensured.identifier
        catalog:withWriteAccessDo('Record Photos album', function()
            collection:setRemoteId(albumIdentifier)
        end)
    end

    if #adoptions > 0 then
        logger:info('Adopted ' .. Assets.record(catalog, adoptions) .. ' identifiers onto photos')
    end
    if #repoints > 0 then
        for _, repoint in ipairs(repoints) do
            repoint.url = M.assetUrl(albumIdentifier, repoint.identifier)
        end
        logger:info('Re-pointed ' .. M.syncIdentifiers(catalog, repoints) .. ' photos ('
            .. M.describeRepoints(repoints) .. ')')
    end

    logger:info('Reconciling ' .. name .. ' (' .. #identifiers .. ' photos)')
    local result = Importer.syncAlbum(albumIdentifier, identifiers)
    if result.status ~= Importer.STATUS_SUCCESS then
        return result
    end
    result.adopted = #adoptions
    result.repointed = #repoints

    -- Last, and only once the album is right: a failure before this point leaves assets that
    -- something can still be pointed back at.
    if #superseded > 0 then
        logger:info('Deleting ' .. #superseded .. ' superseded assets')
        local deleted = Importer.deletePhotos(superseded)
        if deleted.status ~= Importer.STATUS_SUCCESS then
            return deleted
        end
        result.deleted = deleted.deletedCount
    end

    return result
end

return M

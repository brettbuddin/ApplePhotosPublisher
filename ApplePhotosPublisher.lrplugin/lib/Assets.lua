--[[
    Assets

    The one Apple Photos asset a photo has.

    The asset belongs to the photo, not to the collection that published it. Lightroom keeps
    its own identifier per published photo per collection, and those are mirrors of this one:
    the panel's menus and the removal callbacks read them, so they are kept in step, but this
    is the value that decides which asset a photo is.

    Treating the per-collection identifier as the truth is what let two collections disagree
    about the same photo. Publishing replaced the asset and pointed only the collection being
    published at the replacement, so a photo published by two collections ended up with two
    assets, each collection sure it held the right one, and neither able to see the other.
]]

local pluginLoad = require 'PluginModuleLoader'
local Time = pluginLoad 'lib/Time'

local M = {}

--- Plugin metadata key for the Apple Photos localIdentifier.
M.PROP_IDENTIFIER = 'photosLocalIdentifier'
--- Plugin metadata key for the last sync timestamp.
M.PROP_SYNC_DATE = 'photosSyncDate'

--- The asset this photo has in Apple Photos, or nil when it has none.
--- @param photo LrPhoto
--- @return string|nil
function M.identifier(photo)
    local value = photo:getPropertyForPlugin(_PLUGIN, M.PROP_IDENTIFIER)
    if not value or value == '' then
        return nil
    end
    return value
end

--- Record the asset each of these photos now has, in one transaction.
---
--- Through the private gate, which stays off the undo stack and does not mark the photos as
--- changed. An ordinary write here dirties every photo in the batch for every collection
--- publishing it, which is how published photos used to trickle back into "needs
--- publishing" straight after a successful publish. Photos whose asset did not change are
--- left alone for the same reason: the timestamp alone was enough to keep it happening.
---
--- @param catalog LrCatalog The active catalog
--- @param updates table Array of {photo, identifier}
--- @return number How many photos were written
function M.record(catalog, updates)
    local pending = {}
    for _, update in ipairs(updates) do
        if update.identifier and M.identifier(update.photo) ~= update.identifier then
            table.insert(pending, update)
        end
    end
    if #pending == 0 then
        return 0
    end

    local now = Time.nowISO8601()
    catalog:withPrivateWriteAccessDo(function()
        for _, update in ipairs(pending) do
            update.photo:setPropertyForPlugin(_PLUGIN, M.PROP_IDENTIFIER, update.identifier)
            update.photo:setPropertyForPlugin(_PLUGIN, M.PROP_SYNC_DATE, now)
        end
    end)
    return #pending
end

--- Forget the assets these photos had, because they are no longer in Photos.
---
--- Leaving the identifier behind would offer it for reuse on the next publish, and reusing
--- an asset that has been deleted cannot be recovered from in the same run: the render was
--- skipped on the strength of it, so there is no file to fall back to.
---
--- @param catalog LrCatalog The active catalog
--- @param photos table Array of LrPhoto
--- @return number How many photos were cleared
function M.forget(catalog, photos)
    if #photos == 0 then
        return 0
    end
    catalog:withPrivateWriteAccessDo(function()
        for _, photo in ipairs(photos) do
            photo:setPropertyForPlugin(_PLUGIN, M.PROP_IDENTIFIER, nil)
            photo:setPropertyForPlugin(_PLUGIN, M.PROP_SYNC_DATE, nil)
        end
    end)
    return #photos
end

return M

--[[
    Assets

    The Apple Photos asset a photo has in each format it is published in.

    The asset belongs to the photo, not to the collection that published it. Lightroom keeps
    its own identifier per published photo per collection, and those are mirrors of these:
    the panel's menus and the removal callbacks read them, so they are kept in step, but
    these are the values that decide which asset a photo is.

    Treating the per-collection identifier as the truth is what let two collections disagree
    about the same photo. Publishing replaced the asset and pointed only the collection being
    published at the replacement, so a photo published by two collections ended up with two
    assets, each collection sure it held the right one, and neither able to see the other.

    There is one per format rather than one outright because the file is the asset. A JPEG
    album and a TIFF album cannot show the same one, but any number of albums in the same
    format can, and do. Formats.lua has the list.
]]

local pluginLoad = require 'PluginModuleLoader'
local Formats = pluginLoad 'lib/Formats'
local Time = pluginLoad 'lib/Time'

local M = {}

--- Plugin metadata key for the last sync timestamp.
M.PROP_SYNC_DATE = 'photosSyncDate'

--- The asset this photo has in Apple Photos in a format, or nil when it has none.
--- @param photo LrPhoto
--- @param format string|nil A format name
--- @return string|nil
function M.identifier(photo, format)
    local value = photo:getPropertyForPlugin(_PLUGIN, Formats.property(format))
    if not value or value == '' then
        return nil
    end
    return value
end

--- The format an asset of this photo is in, or nil when it is not an asset the photo has.
---
--- A collection names an asset without saying what it is, so this is how a collection whose
--- format was changed is told apart from one that never changed: it is still naming the
--- asset in the format it had.
---
--- @param photo LrPhoto
--- @param identifier string|nil An Apple Photos identifier
--- @return string|nil A format name
function M.formatOf(photo, identifier)
    if not identifier or identifier == '' then
        return nil
    end
    for _, format in ipairs(Formats.names()) do
        if M.identifier(photo, format) == identifier then
            return format
        end
    end
    return nil
end

--- Whether a photo has an asset in any format other than the given one.
local function hasAssetBesides(photo, format)
    for _, other in ipairs(Formats.names()) do
        if other ~= format and M.identifier(photo, other) then
            return true
        end
    end
    return false
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
--- @param updates table Array of {photo, identifier, format}
--- @return number How many photos were written
function M.record(catalog, updates)
    local pending = {}
    for _, update in ipairs(updates) do
        if update.identifier and M.identifier(update.photo, update.format) ~= update.identifier then
            table.insert(pending, update)
        end
    end
    if #pending == 0 then
        return 0
    end

    local now = Time.nowISO8601()
    catalog:withPrivateWriteAccessDo(function()
        for _, update in ipairs(pending) do
            update.photo:setPropertyForPlugin(_PLUGIN, Formats.property(update.format), update.identifier)
            update.photo:setPropertyForPlugin(_PLUGIN, M.PROP_SYNC_DATE, now)
        end
    end)
    return #pending
end

--- Forget the assets these photos had in a format, because they are no longer in Photos.
---
--- Leaving the identifier behind would offer it for reuse on the next publish, and reusing
--- an asset that has been deleted cannot be recovered from in the same run: the render was
--- skipped on the strength of it, so there is no file to fall back to.
---
--- The photo's assets in other formats are untouched, and the sync date stays for as long as
--- it has one.
---
--- @param catalog LrCatalog The active catalog
--- @param entries table Array of {photo, format}
--- @return number How many assets were cleared
function M.forget(catalog, entries)
    if #entries == 0 then
        return 0
    end

    -- Read before the gate opens: writes made inside it are not visible until it closes.
    local lastAsset = {}
    for i, entry in ipairs(entries) do
        lastAsset[i] = not hasAssetBesides(entry.photo, Formats.resolve(entry.format))
    end

    catalog:withPrivateWriteAccessDo(function()
        for i, entry in ipairs(entries) do
            entry.photo:setPropertyForPlugin(_PLUGIN, Formats.property(entry.format), nil)
            if lastAsset[i] then
                entry.photo:setPropertyForPlugin(_PLUGIN, M.PROP_SYNC_DATE, nil)
            end
        end
    end)
    return #entries
end

return M

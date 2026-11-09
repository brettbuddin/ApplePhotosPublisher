--[[
    XML Parser

    Parses XML responses from the lrphotosimporter binary using the LrXml SDK.
    Handles the specific XML schemas used by import and delete commands.

    Usage:
        local XML = pluginLoad 'lib/XML'
        local result = XML.parseBatchImportResult(xmlString)
        if result.status == 'success' then
            -- result.results[path].localIdentifier, result.results[path].albumsRestored
        else
            -- result.errorCode, result.errorMessage
        end
]]

local LrXml = import 'LrXml'

local M = {}

--- Find a child element by name
--- @param node xmlDomInstance The parent node
--- @param name string The element name to find
--- @return xmlDomInstance|nil The child element or nil if not found
local function findChild(node, name)
    local count = node:childCount()
    if not count then return nil end

    for i = 1, count do
        local child = node:childAtIndex(i)
        if child and child:type() == 'element' and child:name() == name then
            return child
        end
    end
    return nil
end

--- Get the text content of a named child element
--- @param node xmlDomInstance The parent node
--- @param name string The element name to find
--- @return string|nil The text content or nil if not found
local function getChildText(node, name)
    local child = findChild(node, name)
    if child then
        return child:text()
    end
    return nil
end

--- Parse an XML string and return the element with the expected root name.
--- The helper's root element is sometimes wrapped, so check for it as a child too.
--- @param xml string The XML response
--- @param name string The expected root element name
--- @return xmlDomInstance|nil The root element, or nil if absent or unparseable
local function parseRoot(xml, name)
    if not xml or xml == '' then return nil end

    local ok, dom = pcall(LrXml.parseXml, xml)
    if not ok or not dom then return nil end

    if dom:name() == name then return dom end
    return findChild(dom, name)
end

--- Parse the album the helper filed a batch into.
--- @param root xmlDomInstance The batchImportResult element
--- @return table|nil {identifier, created} or nil when publishing without an album
local function parseAlbum(root)
    local node = findChild(root, 'album')
    if not node then return nil end

    return {
        identifier = getChildText(node, 'identifier'),
        created = getChildText(node, 'created') == 'true',
    }
end

--- Parse album restoration data from a parent node
--- @param parentNode xmlDomInstance The node containing an optional 'albumsRestored' child
--- @return table Array of {identifier, title} tables
local function parseAlbumsRestored(parentNode)
    local albums = {}
    local albumsNode = findChild(parentNode, 'albumsRestored')
    if albumsNode then
        local count = albumsNode:childCount() or 0
        for i = 1, count do
            local node = albumsNode:childAtIndex(i)
            if node and node:type() == 'element' and node:name() == 'album' then
                table.insert(albums, {
                    identifier = getChildText(node, 'identifier'),
                    title = getChildText(node, 'title'),
                })
            end
        end
    end
    return albums
end

--- Parse a batch import result XML response
--- @param xml string The XML response from the batch import command
--- @return table Parsed result with status, results table keyed by path, or errorCode/errorMessage
function M.parseBatchImportResult(xml)
    local result = {}

    local root = parseRoot(xml, 'batchImportResult')
    if not root then
        result.status = nil
        return result
    end

    result.status = getChildText(root, 'status')

    if result.status == 'success' then
        result.album = parseAlbum(root)
        result.results = {}

        local resultsNode = findChild(root, 'results')
        if resultsNode then
            local resultCount = resultsNode:childCount() or 0
            for i = 1, resultCount do
                local resultNode = resultsNode:childAtIndex(i)
                if resultNode and resultNode:type() == 'element' and resultNode:name() == 'result' then
                    -- Get path from attribute (attributes returns table with {value, namespace, name})
                    local attrs = resultNode:attributes()
                    local path = attrs.path and attrs.path.value

                    local singleResult = {
                        status = getChildText(resultNode, 'status'),
                    }

                    if singleResult.status == 'success' then
                        singleResult.localIdentifier = getChildText(resultNode, 'localIdentifier')
                        singleResult.url = getChildText(resultNode, 'url')
                        singleResult.albumsRestored = parseAlbumsRestored(resultNode)
                        singleResult.reused = getChildText(resultNode, 'reused') == 'true'
                    else
                        singleResult.errorCode = getChildText(resultNode, 'errorCode')
                        singleResult.errorMessage = getChildText(resultNode, 'errorMessage')
                    end

                    if path then
                        result.results[path] = singleResult
                    end
                end
            end
        end
    else
        result.errorCode = getChildText(root, 'errorCode')
        result.errorMessage = getChildText(root, 'errorMessage')
    end

    return result
end

--- Parse a delete result XML response
--- @param xml string The XML response from the delete command
--- @return table Parsed result with status, deletedCount/errorCode/errorMessage
function M.parseDeleteResult(xml)
    local result = {}

    local root = parseRoot(xml, 'deleteResult')
    if not root then
        result.status = nil
        return result
    end

    result.status = getChildText(root, 'status')

    if result.status == 'success' then
        local countStr = getChildText(root, 'deletedCount')
        result.deletedCount = tonumber(countStr) or 0
    else
        result.errorCode = getChildText(root, 'errorCode')
        result.errorMessage = getChildText(root, 'errorMessage')
    end

    return result
end

--- Parse an album operation result.
--- @param xml string The XML response from an album command
--- @return table Parsed result with status, identifier/created or errorCode/errorMessage
function M.parseCollectionResult(xml)
    local result = {}

    local root = parseRoot(xml, 'collectionResult')
    if not root then
        result.status = nil
        return result
    end

    result.status = getChildText(root, 'status')

    if result.status == 'success' then
        result.identifier = getChildText(root, 'identifier')
        result.created = getChildText(root, 'created') == 'true'
    else
        result.errorCode = getChildText(root, 'errorCode')
        result.errorMessage = getChildText(root, 'errorMessage')
    end

    return result
end

return M

import Foundation
import Testing
@testable import lrphotosimporter

@Suite("XMLOutput")
struct XMLOutputTests {

    @Test func deleteSuccess() throws {
        let xml = XMLOutput.deleteSuccess(deletedCount: 3)
        let doc = try XMLDocument(xmlString: xml)
        let root = try #require(doc.rootElement())
        #expect(root.name == "deleteResult")
        #expect(root.elements(forName: "status").first?.stringValue == "success")
        #expect(root.elements(forName: "deletedCount").first?.stringValue == "3")
    }

    @Test func deleteError() throws {
        let xml = XMLOutput.deleteError(code: "DELETE_FAILED", message: "Oops")
        let doc = try XMLDocument(xmlString: xml)
        let root = try #require(doc.rootElement())
        #expect(root.name == "deleteResult")
        #expect(root.elements(forName: "status").first?.stringValue == "error")
        #expect(root.elements(forName: "errorCode").first?.stringValue == "DELETE_FAILED")
    }

    @Test func batchImportResultMixed() throws {
        let results = [
            SingleImportResult.success(
                path: "/a.jpg",
                localIdentifier: "id-1",
                albumsRestored: [AlbumMembership(uuid: "alb", title: "T")],
                favoriteRestored: true
            ),
            SingleImportResult.error(path: "/b.jpg", code: "ERR", message: "bad")
        ]
        let xml = XMLOutput.batchImportResult(results: results, albumUuid: "lib-uuid")
        let doc = try XMLDocument(xmlString: xml)
        let root = try #require(doc.rootElement())
        #expect(root.name == "batchImportResult")
        let resultsEl = try #require(root.elements(forName: "results").first)
        let resultEls = resultsEl.elements(forName: "result")
        #expect(resultEls.count == 2)
        // First result is success
        #expect(resultEls[0].elements(forName: "status").first?.stringValue == "success")
        #expect(resultEls[0].elements(forName: "localIdentifier").first?.stringValue == "id-1")
        #expect(resultEls[0].elements(forName: "url").first?.stringValue == "photos:albums?albumUuid=lib-uuid&assetUuid=id-1")
        // Second result is error
        #expect(resultEls[1].elements(forName: "status").first?.stringValue == "error")
        #expect(resultEls[1].elements(forName: "errorCode").first?.stringValue == "ERR")
    }

    @Test func batchImportResultUrlStripsIdentifierSuffix() throws {
        let results = [
            SingleImportResult.success(
                path: "/a.jpg",
                localIdentifier: "B84E8479-474C-4727-8B95-B2CE1FFE2E0D/L0/001",
                albumsRestored: [],
                favoriteRestored: false
            ),
        ]
        let xml = XMLOutput.batchImportResult(results: results, albumUuid: "lib-uuid")
        let doc = try XMLDocument(xmlString: xml)
        let root = try #require(doc.rootElement())
        let resultsEl = try #require(root.elements(forName: "results").first)
        let resultEls = resultsEl.elements(forName: "result")
        #expect(resultEls[0].elements(forName: "url").first?.stringValue ==
            "photos:albums?albumUuid=lib-uuid&assetUuid=B84E8479-474C-4727-8B95-B2CE1FFE2E0D")
    }

    @Test func batchImportResultUrlFallsBackWithoutAlbum() throws {
        let results = [
            SingleImportResult.success(
                path: "/a.jpg",
                localIdentifier: "id-1",
                albumsRestored: [],
                favoriteRestored: false
            ),
        ]
        let xml = XMLOutput.batchImportResult(results: results, albumUuid: nil)
        let doc = try XMLDocument(xmlString: xml)
        let root = try #require(doc.rootElement())
        let resultsEl = try #require(root.elements(forName: "results").first)
        let resultEls = resultsEl.elements(forName: "result")
        #expect(resultEls[0].elements(forName: "url").first?.stringValue ==
            "photos://asset?assetLocalIdentifier=id-1")
    }

    @Test func batchImportEmpty() throws {
        let xml = XMLOutput.batchImportResult(results: [], albumUuid: nil)
        let doc = try XMLDocument(xmlString: xml)
        let root = try #require(doc.rootElement())
        #expect(root.elements(forName: "status").first?.stringValue == "success")
        let resultsEl = try #require(root.elements(forName: "results").first)
        #expect(resultsEl.elements(forName: "result").isEmpty)
    }

    @Test func batchImportError() throws {
        let xml = XMLOutput.batchImportError(code: "AUTH", message: "denied")
        let doc = try XMLDocument(xmlString: xml)
        let root = try #require(doc.rootElement())
        #expect(root.elements(forName: "status").first?.stringValue == "error")
        #expect(root.elements(forName: "errorCode").first?.stringValue == "AUTH")
    }
}

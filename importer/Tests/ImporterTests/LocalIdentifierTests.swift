import Testing
@testable import lrphotosimporter

@Suite("String.uuidPrefix")
struct LocalIdentifierTests {

    @Test func stripsSlashSuffix() {
        #expect("B84E8479-474C-4727-8B95-B2CE1FFE2E0D/L0/001".uuidPrefix == "B84E8479-474C-4727-8B95-B2CE1FFE2E0D")
    }

    @Test func noSuffixUnchanged() {
        #expect("B84E8479-474C-4727-8B95-B2CE1FFE2E0D".uuidPrefix == "B84E8479-474C-4727-8B95-B2CE1FFE2E0D")
    }

    @Test func emptyString() {
        #expect("".uuidPrefix.isEmpty)
    }
}

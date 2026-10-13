// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class VoiceCatalogTests: XCTestCase {
    func testOffersFourDistinctFeaturedVoices() {
        let ids = VoiceCatalog.featured.map(\.id)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(ids).count, 4)
        XCTAssertEqual(Set(VoiceCatalog.featured.map(\.summary)).count, 4, "each voice has a distinct accent and gender")
    }

    func testDefaultVoiceIsFeaturedAndMatchesSettingsDefault() {
        XCTAssertNotNil(VoiceCatalog.info(for: VoiceCatalog.defaultVoiceID))
        XCTAssertEqual(AppSettings().kokoroVoice, VoiceCatalog.defaultVoiceID)
    }

    func testFeaturedVoicesAreAllInTheFullList() {
        for v in VoiceCatalog.featured { XCTAssertTrue(VoiceCatalog.allIDs.contains(v.id)) }
    }

    func testOthersExcludeFeatured() {
        let featured = Set(VoiceCatalog.featured.map(\.id))
        XCTAssertTrue(VoiceCatalog.others.allSatisfy { !featured.contains($0) })
        XCTAssertEqual(VoiceCatalog.others.count + featured.count, VoiceCatalog.allIDs.count)
    }

    func testBritishPrefixDrivesAccent() {
        XCTAssertTrue(VoiceCatalog.info(for: "bf_emma")!.isBritish)
        XCTAssertFalse(VoiceCatalog.info(for: "am_michael")!.isBritish)
    }

    func testLabels() {
        XCTAssertEqual(VoiceCatalog.label(for: "af_heart"), "Heart — American female")
        XCTAssertEqual(VoiceCatalog.label(for: "bm_lewis"), "Lewis — British male")
    }
}

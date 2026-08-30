// SwapApiConfigTests.swift
// Behavioural pins for the per-release Swap Read API configuration
// (mirror of the Android SwapApiBridgeContractTest.swapApiConfigValidates
// vectors and the persisted-field rule).

import XCTest
@testable import QuantumSwapWallet

final class SwapApiConfigTests: XCTestCase {

    func testSanitizeUrlAcceptsHttpOriginsAndStripsTrailingSlash() {
        XCTAssertEqual(SwapApiConfig.sanitizeUrl("https://api.quantumswap.com/"), "https://api.quantumswap.com")
        XCTAssertEqual(SwapApiConfig.sanitizeUrl("http://127.0.0.1:8182"), "http://127.0.0.1:8182")
        XCTAssertEqual(SwapApiConfig.sanitizeUrl("  https://api.quantumswap.com/v1/  "), "https://api.quantumswap.com/v1")
    }

    func testSanitizeUrlRejectsEverythingElse() {
        for bad in ["ftp://x", "https://u:p@x", "https://x/?a=1", "https://x/#f", "javascript:alert(1)", "",
                    "https://" + String(repeating: "a", count: 200)] {
            XCTAssertEqual(SwapApiConfig.sanitizeUrl(bad), "", "must reject \(bad)")
        }
        XCTAssertEqual(SwapApiConfig.sanitizeUrl(nil), "")
    }

    func testDexIdRule() {
        XCTAssertTrue(SwapApiConfig.isValidDexId("quantumswap-beta2"))
        XCTAssertFalse(SwapApiConfig.isValidDexId("bad id!"))
        XCTAssertFalse(SwapApiConfig.isValidDexId(String(repeating: "a", count: 65)))
        XCTAssertFalse(SwapApiConfig.isValidDexId(""))
        XCTAssertFalse(SwapApiConfig.isValidDexId(nil))
    }

    func testBuiltinCarriesDefaultsAndKeysAreVersioned() {
        XCTAssertEqual(ReleaseStore.builtin.apiUrl, SwapApiConfig.defaultApiUrl)
        XCTAssertEqual(ReleaseStore.builtin.dexId, SwapApiConfig.defaultDexId)
        XCTAssertTrue(ReleaseStore.builtin.swapApiEnabled)
        XCTAssertEqual(ReleaseStore.itemReleases, "dexCustomReleases2")
        XCTAssertEqual(ReleaseStore.itemActive, "dexActiveRelease2")
    }

    func testPersistedFieldRule() {
        // absent -> default; "" -> off; invalid -> default; valid -> kept
        XCTAssertEqual(ReleaseStore.persistedApiUrl([:]), SwapApiConfig.defaultApiUrl)
        XCTAssertEqual(ReleaseStore.persistedApiUrl(["apiUrl": ""]), "")
        XCTAssertEqual(ReleaseStore.persistedApiUrl(["apiUrl": "ftp://x"]), SwapApiConfig.defaultApiUrl)
        XCTAssertEqual(ReleaseStore.persistedApiUrl(["apiUrl": "http://localhost:8182/"]), "http://localhost:8182")
        XCTAssertEqual(ReleaseStore.persistedDexId([:]), SwapApiConfig.defaultDexId)
        XCTAssertEqual(ReleaseStore.persistedDexId(["dexId": ""]), "")
        XCTAssertEqual(ReleaseStore.persistedDexId(["dexId": "bad id!"]), SwapApiConfig.defaultDexId)
        XCTAssertEqual(ReleaseStore.persistedDexId(["dexId": "quantumswap-preflight"]), "quantumswap-preflight")
    }

    func testApplyActiveReleaseAlwaysSendsApiFields() {
        var payload: [String: Any] = [:]
        ReleaseStore.applyActiveRelease(to: &payload)
        XCTAssertNotNil(payload["releaseApiUrl"] as? String)
        XCTAssertNotNil(payload["releaseDexId"] as? String)
    }
}

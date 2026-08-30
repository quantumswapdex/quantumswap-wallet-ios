// SwapApiBridgeContractTests.swift
// Source-shape contract for the Swap Read API integration (mirror of the
// Android SwapApiBridgeContractTest): the shared bridge goes API-first
// with an on-chain fallback for every DEX read, signing and the builders
// never consume API data, the per-release apiUrl / dexId travel in the
// payload, and the native screens pass the quoted path and show the
// API status.

import XCTest
@testable import QuantumSwapWallet

final class SwapApiBridgeContractTests: XCTestCase {

    // MARK: - Bridge

    func testBridgeDefinesSwapApiClientAndContractUrls() throws {
        let html = try stripJs(read("Resources/bridge.html"))
        for fn in ["swapApiFetch", "swapApiProbe", "swapApiFirst", "swapApiRecordFailure",
                   "swapApiSanitizeUrl", "swapApiIsValidDexId", "dexResolveSwapQuote", "dexPickRoute",
                   "dexSimulateExactIn", "dexSimulateExactOut", "dexHopReserves", "dexPathFromPayload"] {
            XCTAssertTrue(html.contains("function \(fn)("), "bridge.html must define \(fn)(")
        }
        XCTAssertTrue(html.contains("var SWAP_API_ROUTE_K = 3;"))
        XCTAssertTrue(html.contains("apiUrl: 'https://api.quantumswap.com'"))
        XCTAssertTrue(html.contains("dexId: 'quantumswap-beta2'"))
        let path = try XCTUnwrap(functionBody(named: "swapApiPath", in: html))
        for needle in ["'/swap/v1/dexes'", "'/status'", "'/token/'", "'/pools?page='", "'/route/'",
                       "'?k='", "'/pair/'", "'?account='", "'/positions'", "'/pairs-created?page='"] {
            XCTAssertTrue(path.contains(needle), "swapApiPath must build \(needle)")
        }
        XCTAssertTrue(path.contains("Math.min(5"), "k clamped to 5")
    }

    func testBridgeReadsAreApiFirstAndBuildersNeverTouchApi() throws {
        let html = try stripJs(read("Resources/bridge.html"))
        for (handler, rpc) in [("swapCheckPairExists", "dexFindSwapPath("),
                               ("swapGetAmountsOut", "dexResolveSwapQuote("),
                               ("swapGetAmountsIn", "dexResolveSwapQuote("),
                               ("swapGetTokenMetadata", "token.symbol()"),
                               ("liquidityListPools", "dexListFactoryPairAddresses("),
                               ("liquidityListPositions", "dexListFactoryPairAddresses("),
                               ("liquidityGetPairInfo", "factory.getPair(")] {
            let body = try XCTUnwrap(handlerBody(named: handler, in: html), "handler \(handler)")
            XCTAssertTrue(body.contains("swapApiFirst(") || body.contains("dexResolveSwapQuote("),
                          "\(handler) must be API-first")
            XCTAssertTrue(body.contains(rpc), "\(handler) must keep its on-chain fallback \(rpc)")
        }
        XCTAssertTrue(html.contains("swapApiStatus: async function(requestId)"))
        XCTAssertTrue(html.contains("liquidityListPairsCreated: async function(requestId)"))
        for name in ["dexBuildSwapCall", "dexBuildAddLiquidityCall", "dexBuildRemoveLiquidityCall",
                     "dexResolveSwapAmounts"] {
            let body = try XCTUnwrap(functionBody(named: name, in: html))
            XCTAssertFalse(body.contains("swapApiFetch(") || body.contains("swapApiFirst("),
                           "\(name) must never consume API data")
        }
        for name in ["swapSubmitSwap", "liquiditySubmitAdd", "liquiditySubmitRemove", "dexEstimateGas"] {
            let body = try XCTUnwrap(handlerBody(named: name, in: html))
            XCTAssertFalse(body.contains("swapApiFetch(") || body.contains("swapApiFirst("),
                           "\(name) must never consume API data")
        }
        let build = try XCTUnwrap(functionBody(named: "dexBuildSwapCall", in: html))
        XCTAssertTrue(build.contains("dexPathFromPayload("))
        let quote = try XCTUnwrap(functionBody(named: "dexResolveSwapQuote", in: html))
        XCTAssertTrue(quote.contains("router.getAmountsOut(") && quote.contains("'api-estimate'"))
    }

    // MARK: - Native

    func testAllowlistAndReleaseStoreCarryApiFields() throws {
        XCTAssertTrue(JsBridge.isAllowlistedDexMethod("swapApiStatus"))
        XCTAssertTrue(JsBridge.isAllowlistedDexMethod("liquidityListPairsCreated"))
        XCTAssertEqual(ReleaseStore.itemReleases, "dexCustomReleases2")
        XCTAssertEqual(ReleaseStore.itemActive, "dexActiveRelease2")
        let store = try strippedSwift("Utils/ReleaseStore.swift")
        XCTAssertTrue(store.contains("apiUrl") && store.contains("dexId"),
                      "Release must carry apiUrl / dexId")
        XCTAssertTrue(store.contains("\"releaseApiUrl\"") && store.contains("\"releaseDexId\""),
                      "applyActiveRelease must send the API fields for every release")
        XCTAssertFalse(store.contains("\"dexCustomReleases\"") || store.contains("\"dexActiveRelease\""),
                       "no unsuffixed v1 key literal may remain")
        let config = try read("Utils/SwapApiConfig.swift")   // raw: the URL contains "//"
        XCTAssertTrue(config.contains("https://api.quantumswap.com") && config.contains("quantumswap-beta2"),
                      "SwapApiConfig must carry the public defaults")
        let swap = try strippedSwift("Screens/SwapViewController.swift")
        XCTAssertTrue(swap.contains("\"path\"") && swap.contains("lastQuotedPath")
                      && swap.contains("swap-quote-source-indexed"))
        let releases = try strippedSwift("Screens/ReleasesViewController.swift")
        for needle in ["apiUrlField", "dexIdField", "swapApiStatus", "swap-api-status-indexed",
                       "swap-api-status-off", "swap-api-status-not-served", "swap-api-status-unavailable",
                       "release-invalid-api-url", "release-invalid-dex-id"] {
            XCTAssertTrue(releases.contains(needle), "ReleasesViewController missing \(needle)")
        }
    }

    func testFallbackIsReportedAndToasted() throws {
        let html = try stripJs(read("Resources/bridge.html"))
        XCTAssertTrue(try XCTUnwrap(functionBody(named: "swapApiFirst", in: html)).contains("swapApiNoteFallback("))
        XCTAssertTrue(html.contains("function swapApiWithFallback(") && html.contains("function swapApiSendResult("))
        for h in ["swapCheckPairExists", "swapGetAmountsOut", "swapGetAmountsIn", "swapGetTokenMetadata",
                  "liquidityListPools", "liquidityListPositions", "liquidityGetPairInfo"] {
            let body = try XCTUnwrap(handlerBody(named: h, in: html))
            XCTAssertTrue(body.contains("swapApiSendResult("), "\(h) must attach apiFallback")
            XCTAssertFalse(body.contains(" sendResult("), "\(h) must not bypass the fallback report")
        }
        let toast = try strippedSwift("Utils/SwapApiToast.swift")
        XCTAssertTrue(toast.contains("Toast.show(") && toast.contains("apiFallback"))
        XCTAssertGreaterThanOrEqual(SwapApiToast.toastSeconds, 3, "toast must stay up at least 3 s")
        let unwrap = try strippedSwift("Utils/DexPayloads.swift")
        XCTAssertTrue(unwrap.contains("SwapApiToast.showIfFallback("),
                      "every unwrapped bridge read must surface the API fallback toast")
        XCTAssertEqual(Localization.shared.lang("swap-api-fallback-toast", fallback: ""),
                       "Swap Read API unavailable ([DETAIL]); using RPC.")
    }

    func testStrongboxUntouched() throws {
        for rel in ["Strongbox/StrongboxPayload.swift", "Strongbox/UnlockCoordinatorV2.swift"] {
            guard let s = try? read(rel) else { continue }
            XCTAssertFalse(s.contains("dexCustomReleases") || s.contains("apiUrl") || s.contains("dexId"),
                           "\(rel) must not know about releases or the Swap Read API")
        }
    }

    func testSwapApiLangKeysResolve() {
        let L = Localization.shared
        XCTAssertEqual(L.lang("swap-insufficient-liquidity", fallback: ""),
                       "Not enough liquidity on this route for the requested amount.")
        XCTAssertEqual(L.lang("swap-quote-source-indexed", fallback: ""),
                       "Estimated from indexed reserves · block [BLOCK]")
        XCTAssertEqual(L.lang("pools-indexed-at", fallback: ""), "Indexed at block [BLOCK]")
        XCTAssertEqual(L.lang("positions-pools-created", fallback: ""), "Pools you created")
        XCTAssertEqual(L.lang("release-api-url", fallback: ""), "Swap Read API URL")
        XCTAssertEqual(L.lang("release-dex-id", fallback: ""), "Swap Read API dexId")
        XCTAssertEqual(L.lang("swap-api-status-off", fallback: ""),
                       "Swap Read API: off for this release (using RPC).")
        XCTAssertEqual(L.lang("token-fee-on-transfer", fallback: ""), "fee on transfer")
    }

    // MARK: - Helpers

    private func sourceRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QuantumSwapWallet")
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(rel), encoding: .utf8)
    }

    private func stripJs(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)^\s*//[^\n]*"#, with: "", options: .regularExpression)
        return out
    }

    private func strippedSwift(_ rel: String) throws -> String {
        var out = try read(rel)
        out = out.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)//[^\n]*"#, with: "", options: .regularExpression)
        return out
    }

    private func functionBody(named name: String, in src: String) -> String? {
        guard let r = src.range(of: #"(async\s+)?function\s+"# + NSRegularExpression.escapedPattern(for: name)
                                    + #"\s*\("#, options: .regularExpression) else { return nil }
        return braceBlock(src, from: r.lowerBound)
    }

    private func handlerBody(named name: String, in src: String) -> String? {
        guard let r = src.range(of: NSRegularExpression.escapedPattern(for: name)
                                    + #"\s*:\s*(async\s+)?function\s*\("#, options: .regularExpression) else { return nil }
        return braceBlock(src, from: r.lowerBound)
    }

    private func braceBlock(_ src: String, from: String.Index) -> String? {
        guard let open = src[from...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < src.endIndex {
            let c = src[i]
            if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(src[open...i]) }
            }
            i = src.index(after: i)
        }
        return nil
    }
}

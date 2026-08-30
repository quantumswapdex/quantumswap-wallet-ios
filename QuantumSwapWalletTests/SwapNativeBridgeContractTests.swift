//
//  SwapNativeBridgeContractTests.swift
//
//  Native-coin swap contract: swapping FROM native Q, TO native Q, and
//  Q <-> WQ (wrap / unwrap). Mirror of the Android
//  SwapNativeBridgeContractTest; the shared bridge.html is asserted to be
//  identical on both platforms by the Android side.
//
//  Regression pinned: the bridge's only swap submit path called
//  swapExactTokensForTokens unconditionally with no value, so a Q -> token
//  swap planned [Approve WQ] -> [Swap] and the router's transferFrom of WQ
//  reverted (the user holds native Q, not WQ). token -> Q silently paid out
//  WQ. Q <-> WQ mapped both sides to the same address and found no route or
//  bounced through an unrelated pair.
//
//  Contract: one dexBuildSwapCall picks the router method (payable
//  swapExactETHForTokens for a native from-side, swapExactTokensForETH for a
//  native to-side, else swapExactTokensForTokens) and both submit and
//  estimate use it; Q <-> WQ is a single WQ.deposit / WQ.withdraw step with
//  no router and no approval; the client relabels the action button and
//  skips the approve step for a native from-side; wrap / unwrap gas kinds
//  exist with matching dexEstimateGas branches; lang keys resolve.
//
//  Grep-style source lint (same seam as StrongboxLayerTests): the sources
//  are read via #filePath and asserted on with comments stripped.
//

import XCTest
@testable import QuantumSwapWallet

final class SwapNativeBridgeContractTests: XCTestCase {

    // MARK: - bridge.html

    func testBridgeDefinesSwapCallBuilderAndUsesIt() throws {
        let html = try strippedJs("Resources/bridge.html")
        XCTAssertTrue(html.contains("async function dexBuildSwapCall("),
            "bridge.html must define dexBuildSwapCall, the single place that picks the "
            + "router method (and value) for a swap.")
        let submit = try XCTUnwrap(handlerBody(named: "swapSubmitSwap", in: html),
                                   "swapSubmitSwap handler not found")
        XCTAssertTrue(submit.contains("dexBuildSwapCall("),
            "swapSubmitSwap must obtain its router call from dexBuildSwapCall.")
        XCTAssertFalse(submit.contains("swapExactTokensForTokens"),
            "swapSubmitSwap must not hard-code swapExactTokensForTokens: for a native "
            + "from-side that call carries no value and the router's transferFrom of WQ reverts.")
        let estimate = try XCTUnwrap(handlerBody(named: "dexEstimateGas", in: html),
                                     "dexEstimateGas handler not found")
        XCTAssertTrue(estimate.contains("dexBuildSwapCall("),
            "dexEstimateGas kind 'swap' must build the call via dexBuildSwapCall.")
        XCTAssertFalse(html.contains(".swapExactTokensForTokens("),
            "No code path in bridge.html may invoke .swapExactTokensForTokens( directly.")
    }

    func testBridgeHasNativeRouterVariantsAndWrapHandlers() throws {
        let html = try strippedJs("Resources/bridge.html")
        for needle in ["swapSubmitWrap:", "swapSubmitUnwrap:",
                       "function dexBuildWrapCall(", "QuantumSwapSDK.WQ.connect(",
                       "'deposit'", "'withdraw'"] {
            XCTAssertTrue(html.contains(needle),
                "bridge.html must implement Q <-> WQ via WQ.deposit / WQ.withdraw; missing: \(needle)")
        }
        // The ...SupportingFeeOnTransferTokens variants derive each hop's input
        // from the pair's actual balance delta, so tokens that burn or tax on
        // transfer (which the standard variants reject with the pair's K check)
        // swap correctly; they are equally correct for normal tokens.
        let builder = try XCTUnwrap(functionBody(named: "dexBuildSwapCall", in: html),
                                    "dexBuildSwapCall not found")
        for needle in ["'swapExactETHForTokensSupportingFeeOnTransferTokens'",
                       "'swapExactTokensForETHSupportingFeeOnTransferTokens'",
                       "'swapExactTokensForTokensSupportingFeeOnTransferTokens'"] {
            XCTAssertTrue(builder.contains(needle),
                "dexBuildSwapCall must emit the fee-on-transfer-safe router variant; missing: \(needle)")
        }
        for bare in ["'swapExactETHForTokens'", "'swapExactTokensForETH'", "'swapExactTokensForTokens'"] {
            XCTAssertFalse(builder.contains(bare),
                "dexBuildSwapCall must not emit the standard router method \(bare): a burn/tax-on-transfer "
                + "input token reverts it with the pair's K check.")
        }
        let allowance = try XCTUnwrap(handlerBody(named: "swapCheckAllowance", in: html))
        XCTAssertTrue(allowance.contains("payload.fromTokenValue === 'Q'"),
            "swapCheckAllowance must report a native from-side as needing no allowance.")
    }

    func testRemoveLiquidityWithNativeSideUsesFeeOnTransferVariant() throws {
        let html = try strippedJs("Resources/bridge.html")
        let body = try XCTUnwrap(functionBody(named: "dexBuildRemoveLiquidityCall", in: html),
                                 "dexBuildRemoveLiquidityCall not found")
        // removeLiquidityETH burns to the ROUTER, which receives the token minus any
        // transfer fee and then forwards the pre-fee amount -- and reverts. The
        // ...SupportingFeeOnTransferTokens form forwards its actual balance.
        XCTAssertTrue(body.contains("'removeLiquidityETHSupportingFeeOnTransferTokens'"),
            "dexBuildRemoveLiquidityCall must use removeLiquidityETHSupportingFeeOnTransferTokens "
            + "for a WQ side so a burn/tax-on-transfer token can be withdrawn from its WQ pool.")
        XCTAssertFalse(body.contains("'removeLiquidityETH'"),
            "dexBuildRemoveLiquidityCall must not emit the standard removeLiquidityETH: "
            + "it reverts for burn/tax-on-transfer tokens.")
    }

    func testRouteFinderRejectsEqualAddresses() throws {
        let html = try strippedJs("Resources/bridge.html")
        let body = try XCTUnwrap(functionBody(named: "dexFindSwapPath", in: html),
                                 "dexFindSwapPath not found")
        let guardPattern = #"if\s*\(\s*fromAddr\.toLowerCase\(\)\s*===\s*toAddr\.toLowerCase\(\)\s*\)\s*return null;"#
        XCTAssertNotNil(body.range(of: guardPattern, options: .regularExpression),
            "dexFindSwapPath must return null when both sides map to the same address "
            + "(Q vs WQ); otherwise it searches getPair(WQ, WQ) or bounces through an "
            + "unrelated pair.")
    }

    // MARK: - Swift side

    func testAllowlistContainsWrapUnwrap() {
        XCTAssertTrue(JsBridge.isAllowlistedDexMethod("swapSubmitWrap"),
            "JsBridge.dexMethods must allowlist swapSubmitWrap.")
        XCTAssertTrue(JsBridge.isAllowlistedDexMethod("swapSubmitUnwrap"),
            "JsBridge.dexMethods must allowlist swapSubmitUnwrap.")
    }

    func testGasKindWrapUnwrapExist() {
        XCTAssertNotNil(GasKind(rawValue: "wrap"),
            "GasKind must define .wrap so the Wrap step can be gas-estimated.")
        XCTAssertNotNil(GasKind(rawValue: "unwrap"),
            "GasKind must define .unwrap so the Unwrap step can be gas-estimated.")
    }

    func testEveryGasKindHasEstimateBranch() throws {
        let html = try strippedJs("Resources/bridge.html")
        let estimate = try XCTUnwrap(handlerBody(named: "dexEstimateGas", in: html))
        for k in GasKind.allCases {
            XCTAssertTrue(estimate.contains("kind === '\(k.txKind)'"),
                "dexEstimateGas has no branch for txKind '\(k.txKind)'; the bridge would "
                + "answer 'Unknown txKind' and the estimate silently falls back.")
        }
    }

    func testSwapViewControllerWrapMode() throws {
        let src = try strippedSwift("Screens/SwapViewController.swift")
        for needle in ["func wrapMode()", ".wrap", ".unwrap", "\"swapSubmitWrap\"",
                       "\"swapSubmitUnwrap\"", "nextButton.setTitle(modeLabel("] {
            XCTAssertTrue(src.contains(needle),
                "SwapViewController must implement wrap / unwrap mode (button relabel, "
                + "wrap/unwrap gas kinds and submit methods); missing: \(needle)")
        }
        let tapNext = try XCTUnwrap(functionBody(named: "tapNext", in: src), "tapNext not found")
        XCTAssertTrue(tapNext.contains("showStepsDialog(needsApproval: false)"),
            "tapNext must skip the allowance check / approve step for wrap, unwrap and a "
            + "native from-side.")
    }

    func testLangKeysResolve() {
        let L = Localization.shared
        XCTAssertEqual(L.lang("wrap", fallback: ""), "Wrap")
        XCTAssertEqual(L.lang("unwrap", fallback: ""), "Unwrap")
        XCTAssertEqual(L.lang("step-wrap", fallback: ""), "Wrap")
        XCTAssertEqual(L.lang("step-unwrap", fallback: ""), "Unwrap")
    }

    // MARK: - Exact-output swaps + fee/burn-on-transfer guard

    func testBuilderEmitsExactOutputVariants() throws {
        let html = try strippedJs("Resources/bridge.html")
        let body = try XCTUnwrap(functionBody(named: "dexBuildSwapCall", in: html))
        for needle in ["'swapETHForExactTokens'", "'swapTokensForExactETH'", "'swapTokensForExactTokens'",
                       "'exactOut'", "value: amounts.amountInMaxWei", "dexIsFeeOnTransferAddress",
                       "provider.estimateGas(", "'reverted'", "'feeToken'"] {
            XCTAssertTrue(body.contains(needle),
                "dexBuildSwapCall must build true exact-output calls with a fee-token guard and a "
                + "pre-flight fallback; missing: \(needle)")
        }
        XCTAssertTrue(html.contains("function dexMaxWeiWithSlippage("))
        let list = html.range(of: "var FEE_ON_TRANSFER_TOKEN_CONTRACT_ADDRESSES = [")
        XCTAssertNotNil(list, "bridge.html must define FEE_ON_TRANSFER_TOKEN_CONTRACT_ADDRESSES")
        if let list, let end = html.range(of: "];", range: list.upperBound..<html.endIndex) {
            let block = html[list.lowerBound..<end.lowerBound].lowercased()
            XCTAssertTrue(block.contains(RecognizedTokens.heisen.lowercased()))
            XCTAssertTrue(block.contains(RecognizedTokens.y2q.lowercased()))
        }
        let est = try XCTUnwrap(handlerBody(named: "dexEstimateGas", in: html))
        XCTAssertTrue(est.contains("swapMode") && est.contains("fallbackReason"))
        let quote = try XCTUnwrap(handlerBody(named: "swapGetAmountsIn", in: html))
        XCTAssertTrue(quote.contains("amountInMax"))
    }

    func testSwapViewControllerSendsRealLastChanged() throws {
        let src = try strippedSwift("Screens/SwapViewController.swift")
        let steps = try XCTUnwrap(functionBody(named: "showStepsDialog", in: src))
        XCTAssertFalse(steps.contains("\"lastChanged\": \"from\""),
            "swapArgs must not hard-code lastChanged \"from\": the side the user last edited decides the form.")
        for needle in ["lastEditedFromSide", "isFeeOnTransfer(", "isUserInteractionEnabled", "onEstimated"] {
            XCTAssertTrue(src.contains(needle),
                "SwapViewController must track the last-edited side, lock the To field for fee-on-transfer "
                + "pairs and react to an estimate fallback; missing: \(needle)")
        }
        let dialog = try strippedSwift("Dialogs/TxStepsDialogViewController.swift")
        XCTAssertTrue(dialog.contains("onEstimated"),
            "TxStep must offer an onEstimated hook so the swap screen can react to an exact-in fallback.")
        let registry = try strippedSwift("Models/RecognizedTokens.swift")
        XCTAssertTrue(registry.contains("func isFeeOnTransfer("),
            "RecognizedTokens must expose isFeeOnTransfer(_:) for the exact-output lock.")
    }

    func testExactOutputLangKeysResolve() {
        let L = Localization.shared
        XCTAssertEqual(L.lang("swap-up-to", fallback: ""), "up to")
        XCTAssertEqual(L.lang("swap-exact-output-unavailable-fee-token", fallback: ""),
            "Exact output is not available for tokens that burn or tax on transfer. Enter the quantity to swap in the From field.")
        XCTAssertEqual(L.lang("swap-exact-output-fallback", fallback: ""),
            "Exact output is not available for this token; swapping the exact input instead. Review the quote and tap Next again.")
        XCTAssertEqual(L.err("swapMaxSoldExceedsBalance", fallback: ""),
            "Up to [QUANTITY] could be sold, which exceeds your balance.")
    }

    func testNoVendorNameInComments() throws {
        let needle = "uni" + "swap"
        var hits: [String] = []
        let roots = [sourceRoot(), sourceRoot().deletingLastPathComponent().appendingPathComponent("QuantumSwapWalletTests")]
        for root in roots {
            guard let e = FileManager.default.enumerator(atPath: root.path) else { continue }
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix(".swift") || rel.hasSuffix(".html") else { continue }
                var s = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
                s = s.replacingOccurrences(of: #""(?:\\.|[^"\\\n])*""#, with: "\"\"", options: .regularExpression)
                if rel.hasSuffix(".html") {
                    s = s.replacingOccurrences(of: #"'(?:\\.|[^'\\\n])*'"#, with: "''", options: .regularExpression)
                }
                var comments = ""
                for pattern in [#"/\*[\s\S]*?\*/"#, rel.hasSuffix(".html") ? #"(?m)^\s*//[^\n]*"# : #"//[^\n]*"#, #"<!--[\s\S]*?-->"#] {
                    let re = try NSRegularExpression(pattern: pattern)
                    let ns = s as NSString
                    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                        comments += ns.substring(with: m.range) + "\n"
                    }
                }
                if comments.lowercased().contains(needle) { hits.append(rel) }
            }
        }
        XCTAssertTrue(hits.isEmpty, "No comment may mention the vendor DEX; found: \(hits)")
    }

    // MARK: - Helpers

    private func sourceRoot(file: StaticString = #filePath) -> URL {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let testsDir = testFileURL.deletingLastPathComponent()
        let projectRoot = testsDir.deletingLastPathComponent()
        return projectRoot.appendingPathComponent("QuantumSwapWallet")
    }

    private func strippedJs(_ rel: String) throws -> String {
        var s = try String(contentsOf: sourceRoot().appendingPathComponent(rel), encoding: .utf8)
        s = s.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        // statement-leading line comments only, so URLs / string literals with "//" survive
        s = s.replacingOccurrences(of: "(?m)^\\s*//[^\n]*", with: "", options: .regularExpression)
        return s
    }

    private func strippedSwift(_ rel: String) throws -> String {
        var s = try String(contentsOf: sourceRoot().appendingPathComponent(rel), encoding: .utf8)
        s = s.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "//[^\n]*", with: "", options: .regularExpression)
        return s
    }

    /// Body of `name: [async] function(` ... `}` in the bridge object.
    private func handlerBody(named name: String, in src: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: name) + #"\s*:\s*(async\s+)?function\s*\("#
        guard let r = src.range(of: pattern, options: .regularExpression) else { return nil }
        return braceBlock(from: r.lowerBound, in: src)
    }

    /// Body of `[async] [private] func|function name(` ... `}`.
    private func functionBody(named name: String, in src: String) -> String? {
        let pattern = #"(async\s+)?(private\s+)?func(tion)?\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#
        guard let r = src.range(of: pattern, options: .regularExpression) else { return nil }
        return braceBlock(from: r.lowerBound, in: src)
    }

    private func braceBlock(from start: String.Index, in src: String) -> String? {
        guard let open = src[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < src.endIndex {
            let c = src[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return String(src[open...i]) }
            }
            i = src.index(after: i)
        }
        return nil
    }
}

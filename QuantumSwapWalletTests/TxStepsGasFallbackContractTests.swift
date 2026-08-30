//
//  TxStepsGasFallbackContractTests.swift
//
//  Gas-estimate failures in the transaction-steps dialog must be shown to
//  the user, with the error the node returned, and the user must be able
//  to set the gas limit manually. Mirror of the Android
//  TxStepsGasFallbackContractTest.
//
//  Regression pinned: GasEstimator.Result already carries usedFallback and
//  the bridge's error text (dexEstimateGas forwards the revert reason
//  verbatim), but TxStepsDialogViewController.prepareCurrent ignored both.
//  A step whose estimate had reverted showed a plausible default fee and
//  went READY; the user submitted with the kind default gas limit and the
//  transaction ran out of gas on-chain with no hint of the revert. The
//  manual gas editor was wired to the gas icon, but onGasIconTap bailed
//  out when there was no estimate -- exactly when the user needs it.
//

import XCTest
@testable import QuantumSwapWallet

final class TxStepsGasFallbackContractTests: XCTestCase {

    func testEstimateFallbackIsSurfacedWithTheReturnedError() throws {
        let src = try strippedSwift("Dialogs/TxStepsDialogViewController.swift")
        let body = try XCTUnwrap(functionBody(named: "prepareCurrent", in: src), "prepareCurrent not found")
        XCTAssertNotNil(body.range(of: #"if\s+result\.usedFallback"#, options: .regularExpression),
            "prepareCurrent must act on result.usedFallback: a reverted estimate silently produced a "
            + "default fee and let the user submit a transaction that then ran out of gas.")
        XCTAssertTrue(body.contains("\"gasEstimateError\""),
            "The fallback notice must use the existing gasEstimateError string.")
        XCTAssertTrue(body.contains("result.error"),
            "The fallback notice must include the error text the estimator returned.")
        XCTAssertTrue(body.contains("\"gas-set-manually-hint\""),
            "The fallback notice must tell the user the gas limit can be set manually.")
    }

    func testGasIconOpensEditorEvenWithoutAnEstimate() throws {
        let src = try strippedSwift("Dialogs/TxStepsDialogViewController.swift")
        let body = try XCTUnwrap(functionBody(named: "onGasIconTap", in: src), "onGasIconTap not found")
        XCTAssertNil(body.range(of: #"guard\s+stepGasLimit\s*>\s*0"#, options: .regularExpression),
            "onGasIconTap must not bail out when there is no estimate; that is exactly when the "
            + "user needs the manual gas editor.")
        XCTAssertTrue(body.contains("defaultFor("),
            "onGasIconTap must pre-fill the editor with the kind default when no estimate is available.")
    }

    func testHintKeyResolves() {
        XCTAssertEqual(Localization.shared.lang("gas-set-manually-hint", fallback: ""),
                       "Tap the gas icon to set the gas limit manually.")
    }

    // MARK: - Helpers

    private func sourceRoot(file: StaticString = #filePath) -> URL {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let testsDir = testFileURL.deletingLastPathComponent()
        let projectRoot = testsDir.deletingLastPathComponent()
        return projectRoot.appendingPathComponent("QuantumSwapWallet")
    }

    private func strippedSwift(_ rel: String) throws -> String {
        var s = try String(contentsOf: sourceRoot().appendingPathComponent(rel), encoding: .utf8)
        s = s.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "//[^\n]*", with: "", options: .regularExpression)
        return s
    }

    private func functionBody(named name: String, in src: String) -> String? {
        let pattern = #"(private\s+)?func\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#
        guard let r = src.range(of: pattern, options: .regularExpression) else { return nil }
        guard let open = src[r.lowerBound...].firstIndex(of: "{") else { return nil }
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
